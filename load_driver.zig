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
const build_options = @import("build_options");

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

    if (cli.port != null and !std.mem.eql(u8, cli.db, "tiger_web_load.db")) {
        log.err("--db: incompatible with --port (external server owns its database)", .{});
        std.process.exit(1);
    }

    if (cli.sidecar and cli.port != null) {
        log.err("--sidecar: incompatible with --port (external server manages its own sidecar)", .{});
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

    const weights = if (cli.ops) |ops| ops.weights else load_gen.default_weights;

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

    if (cli.sidecar) {
        try stdout.print("mode: sidecar\n", .{});
    }

    if (cli.port) |port| {
        run_load(allocator, &io, port, &cli, weights);
    } else {
        // Build absolute db path — the TS sidecar's cwd differs from ours.
        const local_db_path: ?[]const u8 = if (cli.sidecar and cli.local_db) blk: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.posix.getcwd(&cwd_buf) catch break :blk @as(?[]const u8, null);
            break :blk std.fs.path.join(allocator, &.{ cwd, cli.db }) catch break :blk @as(?[]const u8, null);
        } else null;
        var server_proc = try spawn_server(allocator, cli.db, cli.sidecar, local_db_path);

        // Measure db size before seed phase for comparison.
        const db_empty_size = stat_file_size(cli.db);

        defer {
            shutdown_server(&server_proc);
            report_db_sizes(stdout, cli.db, db_empty_size);
            cleanup_files(cli.db);
        }
        run_load(allocator, &io, server_proc.port, &cli, weights);
    }
}

fn run_load(allocator: std.mem.Allocator, io: *IO, port: u16, cli: *const CliArgs, weights: load_gen.Weights) void {
    const gen = load_gen.LoadGen.init(
        allocator,
        io,
        port,
        cli.connections,
        cli.requests,
        cli.seed,
        cli.seed_count,
        cli.analysis,
        weights,
    );
    defer gen.deinit(allocator);

    gen.run();
}

// =================================================================
// Server lifecycle
// =================================================================

const sidecar_count: u8 = build_options.sidecar_count;

const ServerProcess = struct {
    server_child: std.process.Child,
    sidecar_children: [sidecar_count]?std.process.Child,
    port: u16,
    sock_path_buf: [64]u8,
    sock_path_len: u8,
};

/// Generate a unique socket path using the server PID to avoid
/// collisions between concurrent or crashed runs.
fn make_sock_path(buf: *[64]u8, pid: i32) u8 {
    const path = std.fmt.bufPrint(buf, "/tmp/tiger_web_load_{d}.sock", .{pid}) catch @panic("sock path too long");
    return @intCast(path.len);
}

fn sock_path_slice(proc: *const ServerProcess) []const u8 {
    return proc.sock_path_buf[0..proc.sock_path_len];
}

fn spawn_server(allocator: std.mem.Allocator, db: [:0]const u8, sidecar: bool, local_db_path: ?[]const u8) !ServerProcess {
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);

    const dir = std.fs.path.dirname(self_path) orelse ".";
    const server_path = try std.fs.path.join(allocator, &.{ dir, "tiger-web" });
    defer allocator.free(server_path);

    // Clean stale files from previous runs.
    cleanup_files(db);

    var db_arg_buf: [256]u8 = undefined;
    const db_arg = std.fmt.bufPrint(&db_arg_buf, "--db={s}", .{db}) catch @panic("db path too long");

    // Generate unique socket path using our PID — no collisions.
    var sock_path_buf: [64]u8 = undefined;
    const sock_path_len = make_sock_path(&sock_path_buf, @intCast(std.c.getpid()));
    const sock_path = sock_path_buf[0..sock_path_len];

    // Clean stale socket from a previous run with the same PID (unlikely but safe).
    std.fs.deleteFileAbsolute(sock_path) catch {};

    var sidecar_arg_buf: [96]u8 = undefined;
    const sidecar_arg = if (sidecar)
        std.fmt.bufPrint(&sidecar_arg_buf, "--sidecar={s}", .{sock_path}) catch @panic("sidecar path too long")
    else
        "";

    const server_argv = if (sidecar)
        &[_][]const u8{ server_path, "start", "--port=0", db_arg, sidecar_arg }
    else
        &[_][]const u8{ server_path, "start", "--port=0", db_arg };

    var server_child = std.process.Child.init(server_argv, allocator);
    server_child.stdin_behavior = .Pipe;
    server_child.stdout_behavior = .Pipe;
    server_child.stderr_behavior = .Inherit;
    server_child.request_resource_usage_statistics = true;
    try server_child.spawn();
    errdefer {
        _ = server_child.kill() catch {};
    }

    const port = read_port_from_stdout(server_child.stdout.?) catch |err| {
        log.err("failed to read port from server: {s}", .{@errorName(err)});
        _ = server_child.kill() catch {};
        std.process.exit(1);
    };

    log.info("server started on port {d}", .{port});

    var result = ServerProcess{
        .server_child = server_child,
        .sidecar_children = .{null} ** sidecar_count,
        .port = port,
        .sock_path_buf = sock_path_buf,
        .sock_path_len = sock_path_len,
    };

    // Spawn sidecar TS runtimes and verify they connect.
    if (sidecar) {
        for (&result.sidecar_children, 0..) |*sc, i| {
            sc.* = spawn_sidecar(allocator, sock_path, local_db_path) catch |err| {
                log.err("sidecar {d} spawn failed: {s}", .{ i, @errorName(err) });
                _ = server_child.kill() catch {};
                std.process.exit(1);
            };
            // Stagger spawns — give each process time to connect before
            // the next one starts. Prevents socket accept race.
            std.time.sleep(500 * std.time.ns_per_ms);
        }

        // Verify all sidecars connected by polling the server's HTTP port.
        // The server returns 503 until all expected sidecars are ready.
        // Poll with a 10-second timeout.
        if (!wait_sidecar_ready(port)) {
            log.err("sidecar(s) failed to connect within timeout", .{});
            shutdown_server(&result);
            std.process.exit(1);
        }
        log.info("{d} sidecar(s) ready", .{sidecar_count});
    }

    return result;
}

fn spawn_sidecar(allocator: std.mem.Allocator, sock_path: []const u8, local_db_path: ?[]const u8) !std.process.Child {
    // The TS runtime must run from the ecommerce-ts directory so
    // relative imports in call_runtime.ts resolve correctly.
    // Find project root from our own exe path (zig-out/bin/tiger-load → project root).
    const self_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_path);
    const bin_dir = std.fs.path.dirname(self_path) orelse ".";
    const zig_out = std.fs.path.dirname(bin_dir) orelse ".";
    const project_root = std.fs.path.dirname(zig_out) orelse ".";

    // Don't free — Child stores pointers into these for spawn().
    // Leaked intentionally; load driver is short-lived.
    const runtime_path = try std.fs.path.join(allocator, &.{ project_root, "adapters/call_runtime.ts" });
    const cwd_path = try std.fs.path.join(allocator, &.{ project_root, "examples/ecommerce-ts" });

    const argv: []const []const u8 = if (local_db_path) |dbp|
        &.{ "npx", "tsx", runtime_path, sock_path, dbp }
    else
        &.{ "npx", "tsx", runtime_path, sock_path };

    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    child.cwd = cwd_path;
    try child.spawn();
    return child;
}

/// Poll the server until a GET request returns 200 (not 503).
/// The server returns 503 when no sidecar is connected.
/// Returns false if timeout (10 seconds) is exceeded.
fn wait_sidecar_ready(port: u16) bool {
    const timeout_ns = 10 * std.time.ns_per_s;
    const poll_interval = 200 * std.time.ns_per_ms;
    var elapsed: u64 = 0;

    while (elapsed < timeout_ns) {
        if (probe_server(port)) return true;
        std.time.sleep(poll_interval);
        elapsed += poll_interval;
    }
    return false;
}

/// Try a TCP connect + minimal GET request. Returns true if the
/// server responds with HTTP 200 (sidecar ready).
fn probe_server(port: u16) bool {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch return false;
    defer posix.close(fd);

    posix.connect(fd, &addr.any, addr.getOsSockLen()) catch return false;

    const req = "GET /products HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
    _ = posix.write(fd, req) catch return false;

    var buf: [64]u8 = undefined;
    const n = posix.read(fd, &buf) catch return false;
    if (n < 12) return false;

    // Check for "HTTP/1.1 200" — sidecar is ready.
    // "HTTP/1.1 503" means sidecar not connected yet.
    return std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 200");
}

fn read_port_from_stdout(stdout_file: std.fs.File) !u16 {
    var buf: [6]u8 = undefined;
    const n = stdout_file.read(&buf) catch return error.ServerExited;
    if (n == 0) return error.ServerExited;

    const end = if (n > 0 and buf[n - 1] == '\n') n - 1 else n;
    if (end == 0) return error.NoPortNumber;

    return std.fmt.parseInt(u16, buf[0..end], 10) catch return error.InvalidPort;
}

fn shutdown_server(proc: *ServerProcess) void {
    // Kill sidecars first — they depend on the server's socket.
    for (&proc.sidecar_children) |*sc| {
        if (sc.*) |*child| {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }
    }

    if (proc.server_child.stdin) |stdin| {
        stdin.close();
        proc.server_child.stdin = null;
    }

    posix.kill(proc.server_child.id, posix.SIG.TERM) catch {};

    _ = proc.server_child.wait() catch {};

    if (proc.server_child.resource_usage_statistics.getMaxRss()) |max_rss_bytes| {
        std.io.getStdOut().writer().print("rss: {d} bytes\n", .{max_rss_bytes}) catch {};
    }

    // Clean up socket file.
    std.fs.deleteFileAbsolute(sock_path_slice(proc)) catch {};
}

fn stat_file_size(path: [:0]const u8) ?u64 {
    const stat = std.fs.cwd().statFile(path) catch return null;
    return stat.size;
}

fn report_db_sizes(writer: anytype, db: [:0]const u8, db_empty_size: ?u64) void {
    if (db_empty_size) |empty| {
        writer.print("db empty: {d} bytes\n", .{empty}) catch {};
    }
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
    sidecar: bool = false,
    local_db: bool = false,
    ops: ?load_gen.OpsFlag = null,
    db: [:0]const u8 = "tiger_web_load.db",
};
