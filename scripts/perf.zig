//! CPU profiling via perf — automated server + load + report.
//!
//! Spawns the server in release mode, attaches `perf record`, runs
//! `tiger-web benchmark` against it, stops both, and prints the
//! per-DSO + per-symbol reports. One command, reproducible results.
//! Requires `perf` (Linux perf_events).
//!
//! Usage:
//!   zig build scripts -- perf
//!   zig build scripts -- perf --connections=128 --requests=200000
//!
//! **History:** originally orchestrated the pre-Phase-A `tiger-load`
//! binary. Phase A deleted that binary; this script was stubbed
//! until Phase D shipped `tiger-web benchmark`. Now re-wired. The
//! server-spawn + port-read pattern is shared with
//! `scripts/devhub.zig:run_sla_benchmark`.

const std = @import("std");
const posix = std.posix;
const log = std.log;

const Shell = @import("../shell.zig");

pub const CLIArgs = struct {
    connections: u16 = 128,
    requests: u32 = 100_000,
};

const perf_db_path = "tiger_web_perf.db";

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;

    shell.exec("perf version", .{}) catch {
        shell.echo("error: perf is not installed. Install with: sudo pacman -S perf", .{});
        std.process.exit(1);
    };

    log.info("building release...", .{});
    try shell.exec_zig("build -Doptimize=ReleaseSafe", .{});

    cleanup(shell);

    log.info("starting server...", .{});
    var server = try shell.spawn(
        .{
            .stdin_behavior = .Pipe,
            .stdout_behavior = .Pipe,
            .stderr_behavior = .Inherit,
        },
        "zig-out/bin/tiger-web start --port=0 --db={db}",
        .{ .db = perf_db_path },
    );

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
    const port = port_buf[0..port_end];

    log.info("server on port {s}, attaching perf...", .{port});

    var pid_buf: [10]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{server.id}) catch unreachable;
    var perf = try shell.spawn(
        .{ .stderr_behavior = .Inherit },
        "perf record -g --call-graph dwarf -p {pid} -o perf.data",
        .{ .pid = pid_str },
    );

    // Small delay to let perf attach before load starts.
    std.time.sleep(200 * std.time.ns_per_ms);

    log.info("running benchmark: {d} connections, {d} requests...", .{
        cli_args.connections,
        cli_args.requests,
    });
    var conns_buf: [8]u8 = undefined;
    var reqs_buf: [12]u8 = undefined;
    const conns_str = std.fmt.bufPrint(&conns_buf, "{d}", .{cli_args.connections}) catch unreachable;
    const reqs_str = std.fmt.bufPrint(&reqs_buf, "{d}", .{cli_args.requests}) catch unreachable;
    try shell.exec(
        "zig-out/bin/tiger-web benchmark --port={port} --connections={conns} --requests={reqs}",
        .{ .port = port, .conns = conns_str, .reqs = reqs_str },
    );

    // Stop perf first (flushes perf.data), then the server.
    _ = posix.kill(perf.id, posix.SIG.INT) catch {};
    _ = perf.wait() catch {};

    if (server.stdin) |stdin| {
        stdin.close();
        server.stdin = null;
    }
    _ = posix.kill(server.id, posix.SIG.TERM) catch {};
    _ = server.wait() catch {};

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

    cleanup(shell);
}

fn cleanup(shell: *Shell) void {
    const files = [_][]const u8{
        "perf.data",
        perf_db_path,
        perf_db_path ++ "-wal",
        perf_db_path ++ "-shm",
        "tiger_web.wal",
    };
    for (files) |file| {
        shell.cwd.deleteFile(file) catch {};
    }
}
