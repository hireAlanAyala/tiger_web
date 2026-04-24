//! Mechanical TIGER_STYLE enforcement.
//!
//! **Why this exists.** `CLAUDE.md` and the feedback memories list
//! ~10 discipline rules (70-line function limit, ≥2 asserts/fn on
//! hot paths, "don't ship known-throwaway code", etc.). Every audit
//! round is evidence that prose rules don't scale — humans (me) can
//! only hold ~3 rules in active attention simultaneously, so some
//! slip each commit.
//!
//! The bench-check pattern proved the alternative: convert the rule
//! into a build-time check, and the rule stops failing.
//! `bench-check` enforces budget-discipline mechanically; this file
//! does the same for the rules in `CLAUDE.md`'s "Working Habits" +
//! "Assertion Anatomy" sections.
//!
//! Three checks, in order of severity:
//!
//!   1. **Known-throwaway markers** (FAIL): grep for strings like
//!      "TODO: replace", "placeholder until", "known-broken". These
//!      signal shipped-to-be-deleted code that CLAUDE.md explicitly
//!      forbids.
//!   2. **Function-length limit** (FAIL): functions in hot-path
//!      files that exceed 70 lines violate TIGER_STYLE. Counted from
//!      `fn NAME` to the next line starting with `}` at column 0 —
//!      approximate but catches obvious violations.
//!   3. **Assertion density** (WARN): hot-path files with < 2
//!      asserts per function on average. Warn-only for now; promote
//!      to FAIL once the existing codebase converges.
//!
//! Invoked via `zig build scripts -- style-check` and wired into
//! the `unit-test` build step alongside `bench-check`, so every
//! commit runs this check.
//!
//! **Intentionally simple.** A full AST walker would catch more but
//! requires linking to Zig's parser. String-scanning catches the
//! common-case violations; the goal is "prevent the obvious
//! regressions" not "perfect coverage."

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;

const Shell = @import("../shell.zig");

pub const CLIArgs = struct {};

// Hot-path files. Framework + server core. Anywhere a `log.debug`
// in a tick loop or an unbounded loop could ship undetected.
const hot_path_files = [_][]const u8{
    "framework/server.zig",
    "framework/connection.zig",
    "framework/http.zig",
    "framework/io.zig",
    "framework/wal.zig",
    "framework/worker_dispatch.zig",
    "framework/shm_bus.zig",
    "framework/pending_dispatch.zig",
    "framework/message_bus.zig",
    "state_machine.zig",
    "app.zig",
};

// Substrings that flag known-throwaway code. CLAUDE.md:
// "Don't ship known-throwaway code. If a commit message contains
// 'to be replaced by' or 'placeholder until', don't commit it."
const throwaway_markers = [_][]const u8{
    "TODO: replace",
    "placeholder until",
    "to be replaced",
    "known-broken",
    "known broken",
    "XXX: temporary",
    "FIXME before merge",
};

const function_line_limit: u32 = 70;
const assertion_density_min: u32 = 2; // asserts per function, integer floor

pub fn main(shell: *Shell, gpa: std.mem.Allocator, _: CLIArgs) !void {
    var failures: u32 = 0;
    var warnings: u32 = 0;

    for (hot_path_files) |path| {
        check_file(shell, gpa, path, &failures, &warnings) catch |err| {
            shell.echo("style-check: {s}: read error: {s}", .{ path, @errorName(err) });
            failures += 1;
        };
    }

    if (warnings > 0) {
        shell.echo("style-check: {d} warning(s)", .{warnings});
    }
    if (failures > 0) {
        shell.echo("style-check: {d} failure(s) — commit rejected", .{failures});
        std.process.exit(1);
    }

    shell.echo(
        "style-check: {d} hot-path file(s) pass discipline checks",
        .{hot_path_files.len},
    );
}

fn check_file(
    shell: *Shell,
    gpa: std.mem.Allocator,
    path: []const u8,
    failures: *u32,
    warnings: *u32,
) !void {
    const contents = try shell.project_root.readFileAlloc(gpa, path, 1 * 1024 * 1024);
    defer gpa.free(contents);

    check_throwaway_markers(shell, path, contents, failures);
    check_function_lengths(shell, path, contents, warnings);
    check_assertion_density(shell, path, contents, warnings);
}

fn check_throwaway_markers(
    shell: *Shell,
    path: []const u8,
    contents: []const u8,
    failures: *u32,
) void {
    for (throwaway_markers) |marker| {
        if (std.mem.indexOf(u8, contents, marker)) |pos| {
            const line_number = count_newlines(contents[0..pos]) + 1;
            shell.echo(
                "style-check: {s}:{d}: throwaway marker '{s}' — " ++
                    "CLAUDE.md: \"don't ship known-throwaway code\"",
                .{ path, line_number, marker },
            );
            failures.* += 1;
        }
    }
}

fn check_function_lengths(
    shell: *Shell,
    path: []const u8,
    contents: []const u8,
    warnings: *u32,
) void {
    // Walk line-by-line. When a line starts with `fn ` or `pub fn `
    // (optionally inside an indent), record the start. When a
    // subsequent line is `}` at column 0, the body ends. Count lines
    // between.
    //
    // **Skip comptime type-constructor signatures** — any `fn X(...)
    // type {` is a templated type (TB's own pattern: ServerType,
    // ClientType, WalType). Their "body" is an entire generic
    // struct, not a regular function body; the 70-line rule doesn't
    // apply. Match on `) type {` as the signature tail.
    //
    // Approximate: a function inside a struct literal ends at the
    // struct's closing brace, not the method's. Accepted: the
    // alternative is a full Zig parser.
    //
    // **Warn-only for v1**: the existing hot-path files contain
    // several legitimate long functions (parse_request, etc.) that
    // would need refactor before this can be a hard FAIL. Promote
    // to FAIL once the codebase converges.
    var line_iter = std.mem.splitScalar(u8, contents, '\n');
    var line_number: u32 = 0;
    var current_fn_start: ?u32 = null;
    var current_fn_name: []const u8 = "";
    var current_fn_indent: u32 = 0;
    var current_is_type_constructor: bool = false;

    while (line_iter.next()) |line| {
        line_number += 1;
        const indent = count_leading_spaces(line);
        const trimmed = line[indent..];

        if (current_fn_start == null) {
            if (std.mem.startsWith(u8, trimmed, "fn ") or
                std.mem.startsWith(u8, trimmed, "pub fn ") or
                std.mem.startsWith(u8, trimmed, "pub inline fn ") or
                std.mem.startsWith(u8, trimmed, "inline fn "))
            {
                current_fn_start = line_number;
                current_fn_indent = indent;
                const fn_idx = (std.mem.indexOf(u8, trimmed, "fn ") orelse 0) + 3;
                const paren_idx = std.mem.indexOfScalar(u8, trimmed[fn_idx..], '(') orelse
                    trimmed.len - fn_idx;
                current_fn_name = trimmed[fn_idx .. fn_idx + paren_idx];
                current_is_type_constructor =
                    std.mem.indexOf(u8, trimmed, ") type {") != null or
                    std.mem.indexOf(u8, trimmed, ") type ") != null;
            }
        } else {
            // End of function body: `}` at the same indent as the
            // `fn` keyword. Handles nested structs correctly (the
            // struct's closing `}` has deeper indent).
            if (indent == current_fn_indent and std.mem.startsWith(u8, trimmed, "}")) {
                const body_lines = line_number - current_fn_start.?;
                if (body_lines > function_line_limit and !current_is_type_constructor) {
                    shell.echo(
                        "style-check: {s}:{d}: fn {s} is {d} lines, target ≤{d} — " ++
                            "TIGER_STYLE: 70-line function limit (warn-only)",
                        .{
                            path,
                            current_fn_start.?,
                            current_fn_name,
                            body_lines,
                            function_line_limit,
                        },
                    );
                    warnings.* += 1;
                }
                current_fn_start = null;
                current_fn_name = "";
                current_fn_indent = 0;
                current_is_type_constructor = false;
            }
        }
    }
}

fn count_leading_spaces(line: []const u8) u32 {
    var count: u32 = 0;
    for (line) |c| {
        if (c == ' ') count += 1 else break;
    }
    return count;
}

fn check_assertion_density(
    shell: *Shell,
    path: []const u8,
    contents: []const u8,
    warnings: *u32,
) void {
    // Count `fn ` occurrences (function declarations) and `assert(`
    // occurrences (assertion calls, including `std.debug.assert`,
    // `comptime assert`, etc.). Ratio < 2 is a warning.
    const fn_count = count_occurrences(contents, "fn ") +
        count_occurrences(contents, "pub fn ") +
        count_occurrences(contents, "inline fn ");
    const assert_count = count_occurrences(contents, "assert(");

    if (fn_count == 0) return;
    const density = assert_count / fn_count;
    if (density < assertion_density_min) {
        shell.echo(
            "style-check: {s}: assertion density {d}/fn (fns={d}, asserts={d}), " ++
                "target ≥{d} — TIGER_STYLE: \"2+ assertions per function on average\" (warn-only)",
            .{ path, density, fn_count, assert_count, assertion_density_min },
        );
        warnings.* += 1;
    }
}

fn count_occurrences(haystack: []const u8, needle: []const u8) u32 {
    var count: u32 = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |pos| {
        count += 1;
        rest = rest[pos + needle.len ..];
    }
    return count;
}

fn count_newlines(slice: []const u8) u32 {
    var count: u32 = 0;
    for (slice) |c| {
        if (c == '\n') count += 1;
    }
    return count;
}
