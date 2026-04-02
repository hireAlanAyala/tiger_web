const std = @import("std");
const stdx = @import("stdx");
pub const build_options = @import("build_options");
const IO = @import("framework/io.zig").IO;
const App = @import("app.zig");
// Resolve Handlers (needs IO for sidecar), then construct SM.
// Same resolution as the server — SM never sees IO.
const Handlers = App.HandlersFor(App.Storage, IO);
const StateMachine = App.StateMachineWith(App.Storage, Handlers);
const ServerType = @import("framework/server.zig").ServerType;
const TimeReal = @import("framework/time.zig").TimeReal;
const auth = @import("framework/auth.zig");

const Server = ServerType(App, IO, App.Storage);
const Supervisor = @import("supervisor.zig").Supervisor;
const marks = @import("framework/marks.zig");
const log = marks.wrap_log(std.log.scoped(.main));

/// Tick interval in nanoseconds (10ms).
const tick_ns: u64 = 10 * std.time.ns_per_ms;

/// Runtime log level — compile at .debug so nothing is stripped,
/// filter at runtime. Same pattern as TigerBeetle's main.zig.
pub var log_level_runtime: std.log.Level = .info;

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_runtime,
};

pub fn main() !void {
    var args = std.process.args();
    const cli = stdx.flags(&args, CliArgs);

    // Collect sidecar command argv from extended args after `--`.
    // tiger-web -- node dispatch.js → sidecar_argv = {"node", "dispatch.js"}
    var sidecar_argv_buf: [16][]const u8 = undefined;
    var sidecar_argc: usize = 0;
    while (args.next()) |arg| {
        if (sidecar_argc >= sidecar_argv_buf.len) {
            log.err("too many sidecar command arguments (max {d})", .{sidecar_argv_buf.len});
            std.process.exit(1);
        }
        sidecar_argv_buf[sidecar_argc] = arg;
        sidecar_argc += 1;
    }
    const sidecar_argv: ?[]const []const u8 = if (sidecar_argc > 0)
        sidecar_argv_buf[0..sidecar_argc]
    else
        null;

    if (cli.log_trace and !cli.log_debug) {
        log.err("--log-debug must be provided when using --log-trace", .{});
        std.process.exit(1);
    }

    log_level_runtime = if (cli.log_debug) .debug else .info;

    const dev_default_key = "tiger-web-dev-default-key-0!!!!!";
    const secret_env = std.posix.getenv("SECRET_KEY") orelse blk: {
        log.warn("SECRET_KEY not set — using development default (not safe for production)", .{});
        break :blk dev_default_key;
    };
    if (secret_env.len != auth.key_length) {
        log.err("SECRET_KEY must be exactly {d} bytes, got {d}", .{ auth.key_length, secret_env.len });
        std.process.exit(1);
    }
    const secret_key: *const [auth.key_length]u8 = secret_env[0..auth.key_length];

    const address = try std.net.Address.parseIp4("0.0.0.0", cli.port);

    var io = try IO.init();
    defer io.deinit();

    var storage = try App.Storage.init(cli.db);
    defer storage.deinit();
    const sm_seed: u64 = @truncate(std.crypto.random.int(u128));

    // Handlers: sidecar pointers default to null — Server.init
    // creates the embedded Bus/Client and wires them before first tick.
    // For native, Handlers is zero-size (.{} has no fields).
    var sm = StateMachine.init(&storage, .{}, cli.log_trace, sm_seed, secret_key);

    const listen_fd = try io.open_listener(address);

    // When port=0, the OS assigns a free port. Read it back via getsockname.
    // Used by load_driver.zig to spawn the server on an ephemeral port.
    const actual_port: u16 = if (cli.port == 0) blk: {
        var bound_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
        var addr_len = bound_addr.getOsSockLen();
        std.posix.getsockname(listen_fd, &bound_addr.any, &addr_len) catch unreachable;
        break :blk bound_addr.getPort();
    } else cli.port;

    var wal = App.Wal.init("tiger_web.wal");
    defer wal.deinit();

    var time_real = TimeReal{};
    var server = try Server.init(std.heap.page_allocator, &io, &sm, listen_fd, time_real.time(), &wal);

    // Wire sidecar Bus/Client AFTER server is at its final address.
    // Two-phase init: Server.init returns the struct, wire_sidecar
    // takes &server — pointers to embedded fields are now stable.
    const sidecar_path: ?[]const u8 = if (App.sidecar_enabled)
        (cli.sidecar orelse "/tmp/tiger_web_sidecar.sock")
    else
        null;
    try server.wire_sidecar(std.heap.page_allocator, sidecar_path);

    // Supervisor: spawn and manage the sidecar process.
    // The server owns the connection, the supervisor owns the process.
    // main.zig wires them by reading public state from both.
    var supervisor: Supervisor = undefined;
    if (App.sidecar_enabled) {
        const argv = sidecar_argv orelse {
            log.err("sidecar mode requires a command after '--' (e.g., tiger-web -- node dispatch.js)", .{});
            std.process.exit(1);
        };
        supervisor = Supervisor.init(std.heap.page_allocator, argv);
        try supervisor.spawn();
    }

    log.info("storage=sqlite wal=tiger_web.wal tick_interval={d}ms connections={d}", .{
        tick_ns / std.time.ns_per_ms,
        Server.max_connections,
    });
    if (cli.log_debug) log.info("log_level=debug log_trace={}", .{cli.log_trace});
    if (App.sidecar_enabled) log.info("sidecar mode enabled", .{});

    log.info("listening on port {d}", .{actual_port});

    // Readiness signal: write the port to stdout as a bare number + newline.
    // This is the data channel — load_driver.zig reads it to know the server
    // is bound and ready. Separate from the stderr log line which is for humans.
    // Matches TigerBeetle's benchmark_driver pattern: stdout for machine-readable
    // data, stderr for logs.
    if (cli.port == 0) {
        std.io.getStdOut().writer().print("{d}\n", .{actual_port}) catch {};
    }

    // Main event loop.
    var was_sidecar_connected: bool = false;
    while (true) {
        server.tick();

        // Composition root wiring: server ↔ supervisor.
        // No cross-references — main.zig reads public state from both.
        if (App.sidecar_enabled) {
            const connected = server.sidecar_connected;

            // Disconnect detected → tell supervisor to restart.
            if (was_sidecar_connected and !connected) {
                supervisor.request_restart(server.tick_count);
            }
            // READY completed → reset supervisor backoff.
            if (!was_sidecar_connected and connected) {
                supervisor.notify_connected();
            }

            was_sidecar_connected = connected;
            supervisor.tick(server.tick_count);
        }

        io.run_for_ns(tick_ns);
    }
}

const CliArgs = struct {
    port: u16 = 3000,
    log_debug: bool = false,
    log_trace: bool = false,
    sidecar: ?[]const u8 = null,
    db: [:0]const u8 = "tiger_web.db",
    /// Extended args after `--` are the sidecar command argv.
    /// The full command is visible in `ps aux` — explicit, no
    /// hidden config files. Standard Unix convention (docker,
    /// kubectl, ssh all use `--` for sub-commands).
    ///   tiger-web -- node dispatch.js
    ///   tiger-web -- ./my-rust-sidecar
    @"--": void,
};
