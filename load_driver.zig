//! Driver script behind `zig build load`.
//!
//! Orchestrates the load test: spawns a tiger-web server (or connects to
//! an existing one), delegates to load_gen.zig for workload generation and
//! measurement, then cleans up. Follows TigerBeetle's benchmark_driver.zig
//! pattern: orchestrator owns lifecycle, load generator owns measurement.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const stdx = @import("stdx");
const IO = @import("framework/io.zig").IO;
const load_gen = @import("load_gen.zig");

const log = std.log.scoped(.load_driver);

const builtin = @import("builtin");

pub const std_options: std.Options = .{
    .log_level = .info,
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var args = std.process.args();
    const cli = stdx.flags(&args, CliArgs);

    const stdout = std.io.getStdOut().writer();

    if (builtin.mode != .ReleaseSafe and builtin.mode != .ReleaseFast) {
        try stdout.print("warning: load test should be built with -Drelease for meaningful results\n\n", .{});
    }

    // Validate incompatible args: --db cannot be used with --port.
    // When connecting to an external server, the load test doesn't
    // own the database file — reporting its size would be misleading.
    if (cli.port != null and !std.mem.eql(u8, cli.db, "tiger_web_load.db")) {
        log.err("--db: incompatible with --port (external server owns its database)", .{});
        std.process.exit(1);
    }

    if (cli.connections == 0 or cli.connections > load_gen.max_connections) {
        log.err("--connections must be between 1 and {d}", .{load_gen.max_connections});
        std.process.exit(1);
    }
    if (cli.requests == 0) {
        log.err("--requests must be > 0", .{});
        std.process.exit(1);
    }

    print_cpu_info(stdout);
    try stdout.print(
        \\seed: {d}
        \\connections: {d}
        \\requests: {d}
        \\seed count: {d}
        \\
    , .{
        cli.seed,
        cli.connections,
        cli.requests,
        cli.seed_count,
    });
    try stdout.print("\n", .{});

    var io = try IO.init();
    defer io.deinit();

    if (cli.port) |port| {
        run_load(allocator, &io, port, &cli);
    } else {
        var server_proc = try spawn_server(allocator, cli.db);
        defer {
            shutdown_server(&server_proc);
            report_db_size(stdout, cli.db);
            cleanup_files(cli.db);
        }
        run_load(allocator, &io, server_proc.port, &cli);
    }
}

fn run_load(allocator: std.mem.Allocator, io: *IO, port: u16, cli: *const CliArgs) void {
    const gen = load_gen.LoadGen.init(
        allocator,
        io,
        port,
        cli.connections,
        cli.requests,
        cli.seed,
        cli.seed_count,
        cli.analysis,
    );
    defer gen.deinit(allocator);

    gen.run();
}

// =================================================================
// Server lifecycle
// =================================================================

const ServerProcess = struct {
    child: std.process.Child,
    port: u16,
};

fn spawn_server(allocator: std.mem.Allocator, db: [:0]const u8) !ServerProcess {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse ".";
    const server_path = try std.fs.path.join(allocator, &.{ dir, "tiger-web" });
    defer allocator.free(server_path);

    var db_arg_buf: [256]u8 = undefined;
    const db_arg = std.fmt.bufPrint(&db_arg_buf, "--db={s}", .{db}) catch @panic("db path too long");

    var child = std.process.Child.init(
        &.{ server_path, "--port=0", db_arg },
        allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.request_resource_usage_statistics = true;
    try child.spawn();
    errdefer {
        _ = child.kill() catch {};
    }

    // Read port from stdout — the server writes it as a bare number + newline
    // after bind + listen. This is a deterministic readiness signal: the read
    // blocks until the server is ready, no retry loop needed.
    const port = read_port_from_stdout(child.stdout.?) catch |err| {
        log.err("failed to read port from server: {s}", .{@errorName(err)});
        _ = child.kill() catch {};
        std.process.exit(1);
    };

    log.info("server started on port {d}", .{port});

    return .{ .child = child, .port = port };
}

/// Read the port number from the server's stdout. The server writes
/// "PORT\n" as a readiness signal after bind + listen. Blocking read —
/// returns when the server is ready. Matches TB's benchmark_driver pattern.
///
/// Uses read() not readAll() — readAll blocks until the buffer is full
/// or EOF, but the server never closes stdout. read() returns as soon
/// as any data is available (the port number).
fn read_port_from_stdout(stdout_file: std.fs.File) !u16 {
    var buf: [6]u8 = undefined;
    const n = stdout_file.read(&buf) catch return error.ServerExited;
    if (n == 0) return error.ServerExited;

    // Strip trailing newline.
    const end = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
    if (end == 0) return error.NoPortNumber;

    return std.fmt.parseInt(u16, buf[0..end], 10) catch return error.InvalidPort;
}

fn shutdown_server(proc: *ServerProcess) void {
    // Close stdin pipe.
    if (proc.child.stdin) |stdin| {
        stdin.close();
        proc.child.stdin = null;
    }

    posix.kill(proc.child.id, posix.SIG.TERM) catch {};

    _ = proc.child.wait() catch {};

    // Report RSS from resource usage statistics (matches TB pattern).
    if (proc.child.resource_usage_statistics.getMaxRss()) |max_rss_bytes| {
        std.io.getStdOut().writer().print("rss: {d} bytes\n", .{max_rss_bytes}) catch {};
    }
}

fn report_db_size(writer: anytype, db: [:0]const u8) void {
    const stat = std.fs.cwd().statFile(db) catch return;
    writer.print("db after: {d} bytes\n", .{stat.size}) catch {};
}

fn cleanup_files(db: [:0]const u8) void {
    std.fs.cwd().deleteFile(db) catch {};
    var wal_buf: [256]u8 = undefined;
    const wal_path = std.fmt.bufPrint(&wal_buf, "{s}-wal", .{db}) catch return;
    std.fs.cwd().deleteFile(wal_path) catch {};
    var shm_buf: [256]u8 = undefined;
    const shm_path = std.fmt.bufPrint(&shm_buf, "{s}-shm", .{db}) catch return;
    std.fs.cwd().deleteFile(shm_path) catch {};
    std.fs.cwd().deleteFile("tiger_web.wal") catch {};
}

fn print_cpu_info(writer: anytype) void {
    const cpu_file = std.fs.openFileAbsolute("/proc/cpuinfo", .{}) catch return;
    defer cpu_file.close();

    var buf: [4096]u8 = undefined;
    const n = cpu_file.readAll(&buf) catch return;
    const data = buf[0..n];

    const model_key = "model name\t: ";
    const model_start = (std.mem.indexOf(u8, data, model_key) orelse return) + model_key.len;
    const model_end = std.mem.indexOfPos(u8, data, model_start, "\n") orelse data.len;

    writer.print("cpu: {s} (1 core)\n", .{data[model_start..model_end]}) catch {};
}

// =================================================================
// CLI
// =================================================================

const CliArgs = struct {
    port: ?u16 = null,
    connections: u16 = 10,
    requests: u32 = 10_000,
    seed: u64 = 42,
    seed_count: u32 = 1_000,
    analysis: bool = false,
    db: [:0]const u8 = "tiger_web_load.db",
};
