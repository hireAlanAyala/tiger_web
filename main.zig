const std = @import("std");
const stdx = @import("stdx");
pub const build_options = @import("build_options");
const IO = @import("framework/io.zig").IO;
const App = @import("app.zig");
// Resolve Handlers (needs IO for sidecar), then construct SM.
// SM is handler-agnostic — pure framework services.
const StateMachine = App.StateMachineWith(App.Storage);
const ServerType = @import("framework/server.zig").ServerType;
const TimeReal = @import("framework/time.zig").TimeReal;
const Trace = @import("trace.zig");
const TraceWriter = @import("trace_writer.zig").TraceWriter;
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

/// One GPA for all init-time allocations. TB pattern: GPA at startup,
/// no allocations after init. page_allocator wastes 4KB per small alloc.
var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};

pub fn main() !void {
    const allocator = gpa.allocator();

    var args = std.process.args();
    const cli = stdx.flags(&args, CliArgs);
    const sidecar_argv = collect_sidecar_argv(&args);
    const secret_key = validate_config(cli);

    var io = try IO.init();
    defer io.deinit();

    var storage = try App.Storage.init(cli.db);
    defer storage.deinit();

    var sm = StateMachine.init(
        &storage,
        @truncate(std.crypto.random.int(u128)),
        secret_key,
    );

    const listen_fd = try io.open_listener(try std.net.Address.parseIp4("0.0.0.0", cli.port));
    const actual_port = resolve_port(listen_fd, cli.port);

    var wal = App.Wal.init("tiger_web.wal");
    defer wal.deinit();

    var time_real = TimeReal{};

    const trace_max_bytes = parse_trace_max(cli);
    const trace_path = generate_trace_path(cli);
    var trace_file: ?std.fs.File = if (cli.trace)
        std.fs.cwd().createFile(&trace_path, .{}) catch |err| {
            log.err("failed to create trace file: {}", .{err});
            std.process.exit(1);
        }
    else
        null;
    defer if (trace_file) |*f| f.close();

    var trace_writer: ?TraceWriter = if (trace_file) |f|
        TraceWriter.init(f, trace_max_bytes)
    else
        null;

    var tracer = try Trace.Tracer.init(allocator, time_real.time(), .{
        .writer = if (trace_writer) |*tw| tw.any() else null,
        .log_trace = cli.log_trace,
    });

    if (cli.trace) {
        log.info("tracing to {s} (max {s})", .{
            @as([]const u8, &trace_path),
            cli.@"trace-max".?,
        });
    }
    var server = try Server.init(allocator, &io, &sm, &tracer, listen_fd, time_real.time(), &wal);

    try wire_sidecar(&server, cli, allocator);
    var supervisor = try init_supervisor(sidecar_argv, allocator);

    log_startup(cli, actual_port);
    emit_readiness_signal(cli.port, actual_port);

    run_loop(&server, &io, &supervisor);
}

// --- Init helpers (each under 70 lines) ---

/// Parse --trace-max value (e.g. "50mb", "100kb", "1gb") to bytes.
/// Required when --trace is set. Exits on missing or invalid value.
fn parse_trace_max(cli: CliArgs) u64 {
    if (!cli.trace) return 0;
    const raw = cli.@"trace-max" orelse {
        log.err("--trace-max is required when using --trace (e.g. --trace-max=50mb)", .{});
        std.process.exit(1);
    };

    var i: usize = 0;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
    if (i == 0) {
        log.err("--trace-max: invalid value '{s}' (e.g. 50mb, 100kb, 1gb)", .{raw});
        std.process.exit(1);
    }
    const number = std.fmt.parseInt(u64, raw[0..i], 10) catch {
        log.err("--trace-max: invalid number '{s}'", .{raw[0..i]});
        std.process.exit(1);
    };
    const suffix = raw[i..];
    const multiplier: u64 = if (std.ascii.eqlIgnoreCase(suffix, "kb"))
        1024
    else if (std.ascii.eqlIgnoreCase(suffix, "mb"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "gb"))
        1024 * 1024 * 1024
    else if (suffix.len == 0)
        1 // bare number = bytes
    else {
        log.err("--trace-max: unknown unit '{s}' (use kb, mb, or gb)", .{suffix});
        std.process.exit(1);
    };
    return number * multiplier;
}

/// Generate a trace filename from the current timestamp.
/// Format: trace-YYYY-MM-DD-HHMMSS.json (30 chars + sentinel)
const trace_path_len = "trace-YYYY-MM-DD-HHMMSS.json".len;

fn generate_trace_path(cli: CliArgs) [trace_path_len:0]u8 {
    var buf: [trace_path_len:0]u8 = undefined;
    if (!cli.trace) return buf;
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = ts };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const day_secs = epoch.getDaySeconds();
    _ = std.fmt.bufPrint(&buf, "trace-{d:0>4}-{d:0>2}-{d:0>2}-{d:0>2}{d:0>2}{d:0>2}.json", .{
        day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    buf[trace_path_len] = 0;
    return buf;
}

/// Collect sidecar command argv from extended args after `--`.
/// Static buffer — the returned slice must outlive main() because
/// the supervisor respawns processes using this argv.
var sidecar_argv_buf: [16][]const u8 = undefined;

fn collect_sidecar_argv(args: *std.process.ArgIterator) ?[]const []const u8 {
    var argc: usize = 0;
    while (args.next()) |arg| {
        if (argc >= sidecar_argv_buf.len) {
            log.err("too many sidecar command arguments (max {d})", .{sidecar_argv_buf.len});
            std.process.exit(1);
        }
        sidecar_argv_buf[argc] = arg;
        argc += 1;
    }
    return if (argc > 0) sidecar_argv_buf[0..argc] else null;
}

/// Validate CLI config and return the secret key.
fn validate_config(cli: CliArgs) *const [auth.key_length]u8 {
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
    return secret_env[0..auth.key_length];
}

/// Read back the actual port when port=0 (OS-assigned).
fn resolve_port(listen_fd: IO.fd_t, requested: u16) u16 {
    if (requested != 0) return requested;
    var bound_addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 0);
    var addr_len = bound_addr.getOsSockLen();
    std.posix.getsockname(listen_fd, &bound_addr.any, &addr_len) catch unreachable;
    return bound_addr.getPort();
}

/// Wire sidecar bus after server is at its final address.
fn wire_sidecar(server: *Server, cli: CliArgs, allocator: std.mem.Allocator) !void {
    const sidecar_path: ?[]const u8 = if (App.sidecar_enabled)
        (cli.sidecar orelse "/tmp/tiger_web_sidecar.sock")
    else
        null;
    try server.wire_sidecar(allocator, sidecar_path);
}

/// Init supervisor if sidecar argv was provided.
/// Optional — no `--` args means external supervision mode.
fn init_supervisor(sidecar_argv: ?[]const []const u8, allocator: std.mem.Allocator) !?Supervisor {
    if (!App.sidecar_enabled) return null;
    const argv = sidecar_argv orelse return null;
    const count = App.sidecar_count;
    var sup = try Supervisor.init(allocator, argv, count);
    try sup.spawn_all();
    return sup;
}

fn log_startup(cli: CliArgs, actual_port: u16) void {
    log.info("storage=sqlite wal=tiger_web.wal tick_interval={d}ms connections={d}", .{
        tick_ns / std.time.ns_per_ms,
        Server.max_connections,
    });
    if (cli.log_debug) log.info("log_level=debug log_trace={}", .{cli.log_trace});
    if (App.sidecar_enabled) log.info("sidecar mode enabled", .{});
    log.info("listening on port {d}", .{actual_port});
}

/// Readiness signal: write the port to stdout as a bare number.
/// load_driver.zig reads this to know the server is bound.
fn emit_readiness_signal(requested_port: u16, actual_port: u16) void {
    if (requested_port == 0) {
        std.io.getStdOut().writer().print("{d}\n", .{actual_port}) catch {};
    }
}

// --- Main event loop ---

fn run_loop(server: *Server, io: *IO, supervisor: *?Supervisor) void {
    var was_sidecar_connected: bool = false;
    while (true) {
        server.tick();

        // Composition root wiring: server ↔ supervisor.
        // No cross-references — main.zig reads public state from both.
        // The supervisor watches processes via waitpid — no "restart"
        // signal needed. The sidecar detects the closed socket and exits.
        if (supervisor.*) |*sup| {
            const connected = server.sidecar_any_ready();
            if (!was_sidecar_connected and connected) {
                sup.notify_connected();
            }
            was_sidecar_connected = connected;
            sup.tick(server.tick_count);
        }

        io.run_for_ns(tick_ns);
    }
}

const CliArgs = struct {
    port: u16 = 3000,
    log_debug: bool = false,
    log_trace: bool = false,
    trace: bool = false,
    @"trace-max": ?[]const u8 = null,
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
