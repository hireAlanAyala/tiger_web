//! CPU profiling via perf — automated server + load + report.
//!
//! Spawns the server in release mode, attaches perf record, runs the
//! load test, stops both, and prints the perf report. One command,
//! reproducible results. Requires `perf` (Linux perf_events).
//!
//! Usage:
//!   zig build scripts -- perf
//!   zig build scripts -- perf --connections=128 --requests=200000

const std = @import("std");
const posix = std.posix;
const log = std.log;
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

pub const CLIArgs = struct {
    connections: u16 = 128,
    requests: u32 = 100_000,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;

    // Check perf is available.
    shell.exec("perf version", .{}) catch {
        shell.echo("{ansi-red}error: perf is not installed. Install with: sudo pacman -S perf{ansi-reset}", .{});
        std.process.exit(1);
    };

    // Build server and load test in release mode.
    // Use exec() not exec_zig() — the perf script runs standalone,
    // not from a build step that sets ZIG_EXE.
    log.info("building release...", .{});
    try shell.exec("./zig/zig build -Doptimize=ReleaseSafe", .{});

    // Clean up stale files from previous runs.
    cleanup(shell);

    // Start server with ephemeral port.
    log.info("starting server...", .{});
    var server = try shell.spawn(
        .{
            .stdin_behavior = .Pipe,
            .stdout_behavior = .Pipe,
            .stderr_behavior = .Inherit,
        },
        "zig-out/bin/tiger-web --port=0 --db=tiger_web_perf.db",
        .{},
    );

    // Read port from stdout readiness signal.
    var port_buf: [6]u8 = undefined;
    const port_n = server.stdout.?.read(&port_buf) catch {
        log.err("failed to read port from server", .{});
        _ = server.kill() catch {};
        std.process.exit(1);
    };
    if (port_n == 0) {
        log.err("server exited before writing port", .{});
        std.process.exit(1);
    }
    const port_end = if (port_n > 0 and port_buf[port_n - 1] == '\n') port_n - 1 else port_n;
    const port_str = port_buf[0..port_end];

    log.info("server on port {s}, attaching perf...", .{port_str});

    // Attach perf to the server process.
    var pid_buf: [10]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{server.id}) catch unreachable;
    var perf = try shell.spawn(
        .{ .stderr_behavior = .Inherit },
        "perf record -g --call-graph dwarf -p {pid} -o perf.data",
        .{ .pid = pid_str },
    );

    // Small delay to let perf attach before load starts.
    std.time.sleep(200 * std.time.ns_per_ms);

    // Run load test.
    log.info("running load test: {d} connections, {d} requests...", .{
        cli_args.connections,
        cli_args.requests,
    });
    try shell.exec(
        "zig-out/bin/tiger-load --port={port} --connections={connections} --requests={requests}",
        .{
            .port = port_str,
            .connections = cli_args.connections,
            .requests = cli_args.requests,
        },
    );

    // Stop perf.
    _ = posix.kill(perf.id, posix.SIG.INT) catch {};
    _ = perf.wait() catch {};

    // Stop server.
    if (server.stdin) |stdin| {
        stdin.close();
        server.stdin = null;
    }
    _ = posix.kill(server.id, posix.SIG.TERM) catch {};
    _ = server.wait() catch {};

    // Print report. perf report writes to stderr, so capture and print.
    shell.echo("\n=== CPU by library ===\n", .{});
    const dso_report = try shell.exec_stdout_stderr(
        "perf report -i perf.data --stdio --no-children -g none -s dso --percent-limit=1",
        .{},
    );
    if (dso_report[0].len > 0) shell.echo("{s}", .{dso_report[0]});
    if (dso_report[1].len > 0) shell.echo("{s}", .{dso_report[1]});

    shell.echo("\n=== Top functions ===\n", .{});
    const sym_report = try shell.exec_stdout_stderr(
        "perf report -i perf.data --stdio --no-children -g none -s dso,symbol --percent-limit=0.5",
        .{},
    );
    if (sym_report[0].len > 0) shell.echo("{s}", .{sym_report[0]});
    if (sym_report[1].len > 0) shell.echo("{s}", .{sym_report[1]});

    // Clean up after report.
    cleanup(shell);
}

fn cleanup(shell: *Shell) void {
    shell.exec("rm -f perf.data tiger_web_perf.db tiger_web_perf.db-wal tiger_web_perf.db-shm tiger_web.wal", .{}) catch {};
}
