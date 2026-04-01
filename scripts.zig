//! Automation scripts for Tiger Web.
//!
//! Design rationale (from TigerBeetle):
//! - Bash is not cross platform, suffers from high accidental complexity, and is a second language.
//!   We strive to centralize on Zig for all of the things.
//! - While build.zig is great for _building_ software using a graph of tasks with dependency
//!   tracking, higher-level orchestration is easier if you just write direct imperative code.
//! - To minimize the number of things that need compiling and improve link times, all scripts are
//!   subcommands of a single binary.
//!
//!   This is a special case of the following rule-of-thumb: length of `build.zig` should be O(1).
const std = @import("std");

const stdx = @import("stdx");
const Shell = @import("shell.zig");

const cfo = @import("./scripts/cfo.zig");
const ci = @import("./scripts/ci.zig");
const coverage = @import("./scripts/coverage.zig");
const metrics = @import("./scripts/metrics.zig");
const perf_script = @import("./scripts/perf.zig");

pub fn log_fn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !std.log.logEnabled(message_level, scope)) return;
    stdx.log_with_timestamp(message_level, scope, format, args);
}

pub const std_options: std.Options = .{ .logFn = log_fn };

const CLIArgs = union(enum) {
    cfo: cfo.CLIArgs,
    ci: ci.CLIArgs,
    coverage: coverage.CLIArgs,
    metrics: metrics.CLIArgs,
    perf: perf_script.CLIArgs,

    pub const help =
        \\Usage:
        \\
        \\  zig build scripts -- [-h | --help]
        \\
        \\  zig build scripts -- cfo [--budget=<duration>] [--refresh=<duration>] [--concurrency=<n>]
        \\
        \\  zig build scripts -- ci [--validate-release]
        \\
        \\  zig build scripts -- coverage
        \\
        \\  zig build scripts -- metrics [--no-fetch]
        \\
        \\  zig build scripts -- perf [--connections=<n>] [--requests=<n>]
        \\
        \\Options:
        \\
        \\  -h, --help
        \\        Print this help message and exit.
        \\
    ;
};

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer switch (gpa_allocator.deinit()) {
        .ok => {},
        .leak => @panic("memory leak"),
    };

    const gpa = gpa_allocator.allocator();

    const shell = try Shell.create(gpa);
    defer shell.destroy();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const cli_args = stdx.flags(&args, CLIArgs);

    switch (cli_args) {
        .cfo => |args_cfo| try cfo.main(shell, gpa, args_cfo),
        .ci => |args_ci| try ci.main(shell, gpa, args_ci),
        .coverage => |args_cov| try coverage.main(shell, gpa, args_cov),
        .metrics => |args_metrics| try metrics.main(shell, gpa, args_metrics),
        .perf => |args_perf| try perf_script.main(shell, gpa, args_perf),
    }
}
