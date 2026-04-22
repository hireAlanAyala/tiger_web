//! Testing metrics for the Tiger Web testing page.
//!
//! Counts assertions, test scenarios, fuzzers, coverage marks, and line counts
//! from the source tree. Fetches lifetime seed count from devhubdb.
//!
//! Usage:
//!   zig build scripts -- metrics
//!   zig build scripts -- metrics --no-fetch  # skip devhubdb fetch

const std = @import("std");
const log = std.log.scoped(.metrics);
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

pub const CLIArgs = struct {
    @"no-fetch": bool = false,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;
    const arena = shell.arena.allocator();

    // Collect all .zig files, excluding build artifacts and vendored code.
    const source_files = try shell.find(.{
        .where = &.{"."},
        .extension = ".zig",
    });

    var counts = Counts{};
    var file_count: u32 = 0;

    for (source_files) |path| {
        if (is_excluded(path)) continue;
        file_count += 1;

        const content = shell.cwd.readFileAlloc(arena, path, 4 * stdx.MiB) catch |err| {
            log.warn("skip {s}: {}", .{ path, err });
            continue;
        };

        const category = categorize(path);
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trimLeft(u8, line, " ");

            // Skip empty lines, comments, and doc comments for all counting.
            if (trimmed.len == 0) continue;
            const is_comment = std.mem.startsWith(u8, trimmed, "//");

            // Line counts — skip blanks and comments.
            if (!is_comment) {
                switch (category) {
                    .framework => counts.lines_framework += 1,
                    .application => counts.lines_application += 1,
                    .testing => counts.lines_test += 1,
                    .tooling => counts.lines_tooling += 1,
                }
            }

            // Everything below skips comment lines — no false positives from
            // commented-out code or prose containing keywords.
            if (is_comment) continue;

            // Skip string literals containing keywords. A line whose first
            // non-space content is \\ is a multiline string literal line.
            // Lines starting with " or containing string interpolation are
            // harder to detect, but the dominant false-positive source is
            // multiline strings (error messages, format strings).
            if (std.mem.startsWith(u8, trimmed, "\\\\")) continue;

            // Assertions — match the call site, not substrings.
            // `assert(` matches std.debug.assert, comptime assert, self.assert.
            // We require `assert(` to not be preceded by an alphanumeric char
            // to avoid matching `debug_assert(` or similar (not present but defensive).
            if (contains_word(trimmed, "assert(")) counts.assert_count += 1;
            if (is_unreachable(trimmed)) counts.unreachable_count += 1;
            if (contains(trimmed, "@panic(")) counts.panic_count += 1;
            if (contains_word(trimmed, "maybe(")) counts.maybe_count += 1;
            if (contains(trimmed, "comptime assert(") or
                (contains(trimmed, "comptime {") and contains(trimmed, "assert(")))
            {
                counts.comptime_assert += 1;
            }

            // Sim test scenarios (test blocks in sim.zig).
            if (is_sim_file(path) and std.mem.startsWith(u8, trimmed, "test ")) {
                counts.sim_scenarios += 1;
            }

            // Coverage marks.
            if (contains(trimmed, "marks.check(")) counts.marks_test += 1;
            if (contains(trimmed, "log.mark.")) counts.marks_production += 1;
        }
    }

    // Count fuzzers from fuzz_tests.zig — real fuzzers are non-smoke, non-canary entries.
    counts.fuzzers = count_fuzzers(shell, arena);

    // Print dashboard.
    const stdout = std.io.getStdOut().writer();

    const shipped = counts.lines_shipped();

    try stdout.print(
        \\
        \\Tiger Web Testing Metrics
        \\─────────────────────────
        \\Source files:        {d}
        \\
        \\Shipped code:        {d} lines
        \\  Framework:         {d}
        \\  Application:       {d}
        \\Test code:           {d} lines
        \\Tooling:             {d} lines (not counted below)
        \\Test:Shipped:        {d:.1}:1
        \\
        \\Assertions:          {d} runtime + {d} comptime
        \\  assert():          {d}
        \\  unreachable:       {d}
        \\  @panic():          {d}
        \\  maybe():           {d}
        \\Assert density:      1 per {d} lines of shipped code
        \\
        \\Sim scenarios:       {d}
        \\Fuzzers:             {d}
        \\Coverage marks:      {d} production sites, {d} test checks
        \\
    , .{
        file_count,
        shipped,
        counts.lines_framework,
        counts.lines_application,
        counts.lines_test,
        counts.lines_tooling,
        if (shipped > 0) @as(f64, @floatFromInt(counts.lines_test)) / @as(f64, @floatFromInt(shipped)) else 0.0,
        counts.runtime_total(),
        counts.comptime_assert,
        counts.assert_count,
        counts.unreachable_count,
        counts.panic_count,
        counts.maybe_count,
        if (counts.runtime_total() > 0) shipped / counts.runtime_total() else 0,
        counts.sim_scenarios,
        counts.fuzzers,
        counts.marks_production,
        counts.marks_test,
    });

    // CFO lifetime counter from devhubdb.
    if (!cli_args.@"no-fetch") {
        try print_cfo_totals(shell, stdout);
    } else {
        try stdout.print("CFO totals:         (skipped, --no-fetch)\n\n", .{});
    }
}

fn print_cfo_totals(shell: *Shell, stdout: anytype) !void {
    const data = shell.exec_stdout(
        "curl -sf https://raw.githubusercontent.com/hireAlanAyala/tiger-web-devhubdb/main/fuzzing/totals.json",
        .{},
    ) catch {
        try stdout.print("CFO totals:         (fetch failed)\n\n", .{});
        return;
    };

    const totals = std.json.parseFromSliceLeaky(
        struct { seeds_run: u64 = 0 },
        shell.arena.allocator(),
        data,
        .{},
    ) catch {
        try stdout.print("CFO totals:         (parse failed)\n\n", .{});
        return;
    };

    try stdout.print("CFO seeds run:      {d}\n\n", .{totals.seeds_run});
}

fn count_fuzzers(shell: *Shell, arena: std.mem.Allocator) u32 {
    const content = shell.cwd.readFileAlloc(arena, "fuzz_tests.zig", 64 * 1024) catch return 0;
    var count: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " ");
        // Real fuzzers have .name = @import("file.zig"), skip smoke and canary.
        if (std.mem.startsWith(u8, trimmed, ".") and
            contains(trimmed, "@import("))
        {
            count += 1;
        }
    }
    return count;
}

fn is_excluded(path: []const u8) bool {
    // Build artifacts, vendored code, zig toolchain.
    return std.mem.startsWith(u8, path, "./zig/") or
        std.mem.startsWith(u8, path, "./zig-out/") or
        std.mem.startsWith(u8, path, "./.zig-cache/") or
        std.mem.startsWith(u8, path, "./node_modules/") or
        contains(path, "/vendored/");
}

const Category = enum { framework, application, testing, tooling };

fn categorize(path: []const u8) Category {
    // Test files first — naming convention takes priority.
    if (std.mem.endsWith(u8, path, "_test.zig") or
        std.mem.endsWith(u8, path, "_fuzz.zig") or
        std.mem.endsWith(u8, path, "_benchmark.zig"))
        return .testing;

    const basename = std.fs.path.basename(path);
    for (test_basenames) |name| {
        if (std.mem.eql(u8, basename, name)) return .testing;
    }

    // Framework: anything under framework/.
    if (std.mem.startsWith(u8, path, "./framework/")) return .framework;

    // Tooling: scripts, build infrastructure, load testing, adapters.
    if (std.mem.startsWith(u8, path, "./scripts/")) return .tooling;
    if (std.mem.startsWith(u8, path, "./adapters/")) return .tooling;
    for (tooling_basenames) |name| {
        if (std.mem.eql(u8, basename, name)) return .tooling;
    }

    // Everything else is application code.
    return .application;
}

/// Files that are entirely test code but don't follow *_test.zig /
/// *_fuzz.zig / *_benchmark.zig suffix conventions.
const test_basenames = [_][]const u8{
    "fuzz.zig",
    "fuzz_tests.zig",
    "fuzz_lib.zig",
    "sim.zig",
    "auditor.zig",
    "sort_test.zig",
    "snaptest.zig",
    "low_level_hash_vectors.zig",
};

/// Files that are build/scripting infrastructure, not shipped code.
const tooling_basenames = [_][]const u8{
    "shell.zig",
    "build.zig",
    "scripts.zig",
    "annotation_scanner.zig",
};

fn is_sim_file(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), "sim.zig");
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// Match a keyword that appears as a word boundary — not preceded by an
/// alphanumeric or underscore. Prevents `debug_assert(` or `maybe_expire(`
/// from matching `assert(` or `maybe(`.
fn contains_word(haystack: []const u8, needle: []const u8) bool {
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |pos| {
        if (pos == 0 or !is_ident_char(haystack[pos - 1])) return true;
        offset = pos + 1;
    }
    return false;
}

fn is_ident_char(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Match `unreachable` as a keyword, not as a substring of a string literal
/// or identifier. The keyword appears as a statement (`unreachable,` or
/// `unreachable;`) or after `=> ` or `else `. We check that it's not
/// preceded or followed by an identifier character.
fn is_unreachable(line: []const u8) bool {
    const keyword = "unreachable";
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, line, offset, keyword)) |pos| {
        const before_ok = pos == 0 or !is_ident_char(line[pos - 1]);
        const after_pos = pos + keyword.len;
        const after_ok = after_pos >= line.len or !is_ident_char(line[after_pos]);
        if (before_ok and after_ok) return true;
        offset = pos + 1;
    }
    return false;
}

const Counts = struct {
    lines_framework: u32 = 0,
    lines_application: u32 = 0,
    lines_test: u32 = 0,
    lines_tooling: u32 = 0,
    assert_count: u32 = 0,
    unreachable_count: u32 = 0,
    panic_count: u32 = 0,
    maybe_count: u32 = 0,
    comptime_assert: u32 = 0,
    sim_scenarios: u32 = 0,
    fuzzers: u32 = 0,
    marks_test: u32 = 0,
    marks_production: u32 = 0,

    fn runtime_total(self: Counts) u32 {
        return self.assert_count + self.unreachable_count + self.panic_count + self.maybe_count;
    }

    fn lines_shipped(self: Counts) u32 {
        return self.lines_framework + self.lines_application;
    }
};
