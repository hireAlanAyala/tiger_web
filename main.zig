const std = @import("std");
const IO = @import("tiger_framework").io.IO;
const App = @import("app.zig");
const SqliteStorage = @import("storage.zig").SqliteStorage;
const StateMachine = App.StateMachineType(SqliteStorage);
const ServerType = @import("tiger_framework").server.ServerType;
const TimeReal = @import("tiger_framework").time.TimeReal;
const auth = @import("tiger_framework").auth;
const flags = @import("tiger_framework").flags;

const Server = ServerType(App, IO, SqliteStorage);
const marks = @import("tiger_framework").marks;
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
    const cli = flags.parse(&args, CliArgs);

    if (cli.log_trace and !cli.log_debug) {
        log.err("--log-debug must be provided when using --log-trace", .{});
        std.process.exit(1);
    }

    log_level_runtime = if (cli.log_debug) .debug else .info;

    const secret_env = std.posix.getenv("SECRET_KEY") orelse {
        log.err("SECRET_KEY not set", .{});
        std.process.exit(1);
    };
    if (secret_env.len != auth.key_length) {
        log.err("SECRET_KEY must be exactly {d} bytes, got {d}", .{ auth.key_length, secret_env.len });
        std.process.exit(1);
    }
    const secret_key: *const [auth.key_length]u8 = secret_env[0..auth.key_length];

    const address = try std.net.Address.parseIp4("0.0.0.0", cli.port);

    var io = try IO.init();
    defer io.deinit();

    var storage = try SqliteStorage.init("tiger_web.db");
    defer storage.deinit();
    const sm_seed: u64 = @truncate(std.crypto.random.int(u128));
    var sm = StateMachine.init(&storage, cli.log_trace, sm_seed, secret_key);

    const listen_fd = try IO.open_listener(address);

    var wal = App.Wal.init("tiger_web.wal");
    defer wal.deinit();

    var time_real = TimeReal{};
    var server = try Server.init(std.heap.page_allocator, &io, &sm, listen_fd, time_real.time(), &wal);

    log.info("storage=sqlite wal=tiger_web.wal tick_interval={d}ms connections={d}", .{
        tick_ns / std.time.ns_per_ms,
        Server.max_connections,
    });
    if (cli.log_debug) log.info("log_level=debug log_trace={}", .{cli.log_trace});
    // Sidecar: connect to external unix socket process.
    if (cli.sidecar) |path| {
        App.sidecar = .{ .path = path };
        if (!App.sidecar.?.connect()) {
            log.err("failed to connect to sidecar at {s}", .{path});
            std.process.exit(1);
        }
        log.info("sidecar={s}", .{path});
    }

    log.info("listening on port {d}", .{cli.port});

    // Main event loop. No signal handling — let the OS kill the process.
    while (true) {
        server.tick();
        io.run_for_ns(tick_ns);
    }
}

const CliArgs = struct {
    port: u16 = 3000,
    log_debug: bool = false,
    log_trace: bool = false,
    sidecar: ?[]const u8 = null,
};
