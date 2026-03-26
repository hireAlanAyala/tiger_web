//! CI pipeline orchestration.
//!
//! Runs the full test suite: unit tests, simulation tests, fuzz smoke,
//! annotation scanner. Called by GitHub Actions via `zig build scripts -- ci test`.
//!
//! TODO: Port from TigerBeetle's src/scripts/ci.zig. See docs/plans/post-cfo-port.md.

const std = @import("std");
const Shell = @import("../shell.zig");

pub const CLIArgs = struct {
    @"--": void,
    target: Target,

    pub const Target = enum {
        test_,
        smoke,
    };
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;
    _ = cli_args;
    shell.echo("{ansi-red}error: ci subcommand not yet implemented — see docs/plans/post-cfo-port.md{ansi-reset}", .{});
    std.process.exit(1);
}
