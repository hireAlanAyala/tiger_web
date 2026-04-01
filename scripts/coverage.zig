//! Line coverage via kcov.
//!
//! Builds unit tests, runs each binary under kcov, reports merged coverage.
//! Sim tests are skipped — epoll conflicts with kcov's ptrace.
//!
//! Usage:
//!   zig build scripts -- coverage

const std = @import("std");
const log = std.log.scoped(.coverage);
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

const output_dir = "./kcov-out";

pub const CLIArgs = struct {};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;
    _ = cli_args;

    const kcov_version = shell.exec_stdout("kcov --version", .{}) catch {
        log.err("kcov not found — install with: sudo pacman -S kcov", .{});
        return error.NoKcov;
    };
    log.info("kcov {s}", .{kcov_version});

    // Build unit tests.
    log.info("building unit tests...", .{});
    try shell.exec("./zig/zig build unit-test", .{});

    // Clean output.
    shell.cwd.deleteTree(output_dir) catch {};
    try shell.cwd.makePath(output_dir);

    // Find test binaries built in the last 60 seconds.
    const include_path = try shell.exec_stdout("pwd", .{});
    const test_binaries = try shell.exec_stdout(
        "find .zig-cache -name test -type f -executable -newer build.zig",
        .{},
    );

    var run_count: u32 = 0;
    var skip_count: u32 = 0;
    var lines = std.mem.splitScalar(u8, test_binaries, '\n');

    while (lines.next()) |path| {
        if (path.len == 0) continue;

        log.info("run: {s}", .{std.fs.path.basename(std.fs.path.dirname(path) orelse path)});
        shell.exec(
            "kcov --skip-solibs --include-path={include} --exclude-pattern=zig/lib {out} {bin}",
            .{ .include = include_path, .out = output_dir, .bin = path },
        ) catch {
            log.warn("  failed, skipping", .{});
            skip_count += 1;
            continue;
        };
        run_count += 1;
    }

    log.info("{d} instrumented, {d} skipped", .{ run_count, skip_count });

    // Report.
    try report(shell);
}


fn report(shell: *Shell) !void {
    const stdout = std.io.getStdOut().writer();
    const arena = shell.arena.allocator();

    // List kcov run directories and find their coverage.json files.
    const cov_dirs = shell.exec_stdout(
        "find {dir} -name coverage.json -not -path */kcov-merged/*",
        .{ .dir = output_dir },
    ) catch {
        try stdout.print("\nNo coverage data found.\n", .{});
        return;
    };
    const cov_files = blk: {
        var list = std.ArrayList([]const u8).init(arena);
        var lines = std.mem.splitScalar(u8, cov_dirs, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) try list.append(line);
        }
        break :blk list.items;
    };

    const FileCov = struct {
        name: []const u8,
        covered: u32,
        total: u32,
    };
    // Use a simple list and deduplicate by name (take max covered).
    var file_list = std.ArrayList(FileCov).init(arena);

    for (cov_files) |cov_path| {
        const data = shell.cwd.readFileAlloc(arena, cov_path, 10 * stdx.MiB) catch continue;
        const parsed = std.json.parseFromSliceLeaky(CoverageReport, arena, data, .{}) catch continue;

        for (parsed.files) |f| {
            const name = shipped_name(f.file) orelse continue;
            const covered = std.fmt.parseInt(u32, f.covered_lines, 10) catch continue;
            const total = std.fmt.parseInt(u32, f.total_lines, 10) catch continue;

            // Update existing or append.
            var found = false;
            for (file_list.items) |*existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    existing.covered = @max(existing.covered, covered);
                    existing.total = @max(existing.total, total);
                    found = true;
                    break;
                }
            }
            if (!found) {
                try file_list.append(.{ .name = name, .covered = covered, .total = total });
            }
        }
    }

    if (file_list.items.len == 0) {
        try stdout.print("\nNo coverage data found.\n", .{});
        return;
    }

    var reachable_covered: u32 = 0;
    var reachable_total: u32 = 0;
    var all_covered: u32 = 0;
    var all_total: u32 = 0;

    var gaps = std.ArrayList(FileCov).init(arena);

    for (file_list.items) |f| {
        all_covered += f.covered;
        all_total += f.total;

        if (f.covered > 0) {
            reachable_covered += f.covered;
            reachable_total += f.total;

            const file_pct = pct(f.covered, f.total);
            if (file_pct < 95.0) {
                try gaps.append(f);
            }
        }
    }

    try stdout.print(
        \\
        \\Line Coverage (kcov, unit tests)
        \\────────────────────────────────
        \\All shipped code:    {d:.1}%  ({d}/{d} lines)
        \\Reachable code:      {d:.1}%  ({d}/{d} lines)
        \\
    , .{
        if (all_total > 0) pct(all_covered, all_total) else 0,
        all_covered,
        all_total,
        if (reachable_total > 0) pct(reachable_covered, reachable_total) else 0,
        reachable_covered,
        reachable_total,
    });

    if (gaps.items.len > 0) {
        std.mem.sort(FileCov, gaps.items, {}, struct {
            fn lessThan(_: void, a: FileCov, b: FileCov) bool {
                return pct(a.covered, a.total) < pct(b.covered, b.total);
            }
        }.lessThan);

        try stdout.print("Gaps (< 95%):\n", .{});
        for (gaps.items) |f| {
            try stdout.print("  {d:>6.1}%  ({d:>4} lines)  {s}\n", .{ pct(f.covered, f.total), f.total, f.name });
        }
        try stdout.print("\n", .{});
    }
}

fn pct(covered: u32, total: u32) f64 {
    return @as(f64, @floatFromInt(covered)) * 100.0 / @as(f64, @floatFromInt(total));
}

/// Returns the project-relative name if this is a shipped code file, null otherwise.
fn shipped_name(path: []const u8) ?[]const u8 {
    const marker = "/tiger_web/";
    const idx = std.mem.indexOf(u8, path, marker) orelse return null;
    const name = path[idx + marker.len ..];

    // Exclude stdlib, test files, tooling.
    if (std.mem.startsWith(u8, name, "zig/lib/")) return null;
    if (std.mem.startsWith(u8, name, "scripts/")) return null;
    if (std.mem.startsWith(u8, name, "adapters/")) return null;

    const skip_suffixes = [_][]const u8{
        "_test.zig",  "_fuzz.zig",       "fuzz_tests.zig", "fuzz_lib.zig",
        "sim.zig",    "auditor.zig",     "fuzz.zig",       "state_machine_benchmark.zig",
        "sort_test.zig", "snaptest.zig", "low_level_hash_vectors.zig",
    };
    for (skip_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return null;
    }

    const skip_names = [_][]const u8{
        "shell.zig",            "build.zig",    "scripts.zig",
        "load_gen.zig",         "load_driver.zig",
        "annotation_scanner.zig",
    };
    for (skip_names) |s| {
        if (std.mem.eql(u8, name, s)) return null;
    }

    return name;
}

const CoverageReport = struct {
    files: []const CoverageFile = &.{},
    percent_covered: []const u8 = "0",
    covered_lines: []const u8 = "0",
    total_lines: []const u8 = "0",
};

const CoverageFile = struct {
    file: []const u8 = "",
    percent_covered: []const u8 = "0",
    covered_lines: []const u8 = "0",
    total_lines: []const u8 = "0",
};
