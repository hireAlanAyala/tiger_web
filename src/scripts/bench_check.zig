//! Benchmark discipline check.
//!
//! Enforces that every `*_benchmark.zig` file at repo root satisfies
//! the plan's engineering-value-7 contract:
//!
//!   - Calls `bench.assert_budget(...)` so smoke-mode catches
//!     order-of-magnitude regressions.
//!   - References `docs/internal/benchmark-budgets.md` in its
//!     header, so the budget number is traceable to a 3-run
//!     calibration record and not picked from the air.
//!
//! Why automate this: the plan text said the same thing and humans
//! (me) still failed to follow it on the first pass. Discipline
//! that isn't enforced is advice. A reviewer reading a diff
//! months from now shouldn't have to remember the calibration rule
//! — the build should reject commits that violate it.
//!
//! Invoked via `zig build scripts -- bench-check` and wired into
//! the `unit-test` build step, so every commit runs this check.

const std = @import("std");
const log = std.log;
const assert = std.debug.assert;

const Shell = @import("../shell.zig");

pub const CLIArgs = struct {};

// Every benchmark file in this list must satisfy the invariants in
// `check_file`. Keep in sync with `build.zig:bench_sources`.
const bench_files = [_][]const u8{
    "src/aegis_checksum_benchmark.zig",
    "src/crc_frame_benchmark.zig",
    "src/hmac_session_benchmark.zig",
    "src/wal_parse_benchmark.zig",
    "src/route_match_benchmark.zig",
    "src/state_machine_benchmark.zig",
};

const required_budgets_doc_ref = "docs/internal/benchmark-budgets.md";
const required_assert_budget_call = "bench.assert_budget(";

pub fn main(shell: *Shell, gpa: std.mem.Allocator, _: CLIArgs) !void {
    var failures: u32 = 0;
    for (bench_files) |path| {
        check_file(shell, gpa, path) catch |err| {
            shell.echo("bench-check: {s}: {s}", .{ path, @errorName(err) });
            failures += 1;
        };
    }

    if (failures > 0) {
        shell.echo("bench-check: {d} file(s) failed discipline checks", .{failures});
        std.process.exit(1);
    }

    shell.echo(
        "bench-check: all {d} benchmark files satisfy budget + calibration discipline",
        .{bench_files.len},
    );
}

fn check_file(shell: *Shell, gpa: std.mem.Allocator, path: []const u8) !void {
    const contents = shell.cwd.readFileAlloc(gpa, path, 64 * 1024) catch |err| {
        shell.echo("bench-check: cannot read {s}: {s}", .{ path, @errorName(err) });
        return error.ReadFailed;
    };
    defer gpa.free(contents);

    // Invariant 1: file must reference the budgets doc (so the
    // budget constant is traceable to a 3-run calibration record).
    if (std.mem.indexOf(u8, contents, required_budgets_doc_ref) == null) {
        shell.echo(
            "  missing header reference to '{s}' — the budget number must point at the calibration record, not be picked from the air",
            .{required_budgets_doc_ref},
        );
        return error.MissingBudgetsDocReference;
    }

    // Invariant 2: file must call assert_budget. Without this, smoke
    // mode can't catch order-of-magnitude regressions and the
    // benchmark becomes observation-only.
    if (std.mem.indexOf(u8, contents, required_assert_budget_call) == null) {
        shell.echo(
            "  no call to '{s}' — every benchmark must guard smoke mode with a budget assertion",
            .{required_assert_budget_call},
        );
        return error.MissingAssertBudget;
    }
}
