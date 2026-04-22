//! CPU profiling via perf — currently a stub.
//!
//! The load driver this script used to orchestrate (`tiger-load`) was
//! removed in benchmark-tracking/phase-A. Its replacement
//! (`tiger-web benchmark`) lands in phase D, at which point this
//! script is re-wired to drive it. Until then, invoking the script
//! fails explicitly rather than breaking at runtime on a missing
//! binary. Full orchestration (server spawn, perf attach, report) is
//! in git history at commit 67993e8~1:scripts/perf.zig.

const std = @import("std");

const Shell = @import("../shell.zig");

pub const CLIArgs = struct {
    connections: u16 = 128,
    requests: u32 = 100_000,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;
    _ = cli_args;
    shell.echo(
        \\error: `zig build scripts -- perf` is temporarily unavailable.
        \\
        \\The load driver (`tiger-load`) was removed in phase A of the
        \\benchmark-tracking plan. Its replacement (`tiger-web benchmark`)
        \\ships in phase D. See docs/plans/benchmark-tracking.md.
        \\
    , .{});
    std.process.exit(1);
}
