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
    var args = std.process.args();
    const cmd = stdx.flags(&args, Command);
    switch (cmd) {
        .start => |cli| cmd_start(cli, &args),
        .trace => |cli| cmd_trace(cli),
    }
}

fn cmd_start(cli: StartArgs, args: *std.process.ArgIterator) void {
    const allocator = gpa.allocator();
    const sidecar_argv = collect_sidecar_argv(args);
    const secret_key = validate_config(cli);

    var io = IO.init() catch |err| {
        log.err("IO init failed: {}", .{err});
        std.process.exit(1);
    };
    defer io.deinit();

    var storage = App.Storage.init(cli.db) catch |err| {
        log.err("storage init failed: {}", .{err});
        std.process.exit(1);
    };
    defer storage.deinit();

    var sm = StateMachine.init(
        &storage,
        @truncate(std.crypto.random.int(u128)),
        secret_key,
    );

    const listen_fd = io.open_listener(std.net.Address.parseIp4("0.0.0.0", cli.port) catch unreachable) catch |err| {
        log.err("listen failed: {}", .{err});
        std.process.exit(1);
    };
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

    var tracer = Trace.Tracer.init(allocator, time_real.time(), .{
        .writer = if (trace_writer) |*tw| tw.any() else null,
        .log_trace = cli.log_trace,
    }) catch |err| {
        log.err("tracer init failed: {}", .{err});
        std.process.exit(1);
    };

    if (cli.trace) {
        log.info("tracing to {s} (max {s})", .{
            @as([]const u8, &trace_path),
            cli.@"trace-max".?,
        });
    }

    var server = Server.init(allocator, &io, &sm, &tracer, listen_fd, time_real.time(), &wal) catch |err| {
        log.err("server init failed: {}", .{err});
        std.process.exit(1);
    };

    wire_sidecar(&server, cli, allocator) catch |err| {
        log.err("sidecar init failed: {}", .{err});
        std.process.exit(1);
    };
    var supervisor = init_supervisor(sidecar_argv, allocator) catch |err| {
        log.err("supervisor init failed: {}", .{err});
        std.process.exit(1);
    };

    log_startup(cli, actual_port);
    emit_readiness_signal(cli.port, actual_port);

    run_loop(&server, &io, &supervisor, &trace_writer, &tracer);
}

fn cmd_trace(cli: TraceArgs) void {
    // Parse ":port" target.
    if (cli.target.len < 2 or cli.target[0] != ':') {
        log.err("invalid target '{s}' — expected :port (e.g. :3000)", .{cli.target});
        std.process.exit(1);
    }
    const port = std.fmt.parseInt(u16, cli.target[1..], 10) catch {
        log.err("invalid port in '{s}'", .{cli.target});
        std.process.exit(1);
    };

    // Connect to admin socket.
    var path_buf: [64]u8 = undefined;
    const admin_path = std.fmt.bufPrint(&path_buf, "/tmp/tiger_web_admin_{d}.sock", .{port}) catch unreachable;

    const stdout = std.io.getStdOut().writer();
    stdout.print("connecting to server at :{d}...\n", .{port}) catch {};

    // Connect to the admin socket.
    const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
        stdout.print("failed to create socket: {}\n", .{err}) catch {};
        std.process.exit(1);
    };
    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..admin_path.len], admin_path);
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch {
        stdout.print("could not connect to {s}\n", .{admin_path}) catch {};
        stdout.print("is the server running on port {d}?\n", .{port}) catch {};
        std.process.exit(1);
    };

    // Parse max size for the trace.
    const max_bytes = parse_size(cli.max);
    _ = max_bytes;

    // TODO: Send start command, wait for Ctrl-C, send stop command.
    // Requires admin socket listener on the server side (Step 4).
    stdout.print("admin socket connected — trace toggle not yet implemented\n", .{}) catch {};
    stdout.print("use --trace --trace-max on server start for now\n", .{}) catch {};
}

// --- Init helpers (each under 70 lines) ---

/// Parse a size string (e.g. "50mb", "100kb", "1gb") to bytes.
fn parse_size(raw: []const u8) u64 {
    var i: usize = 0;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {}
    if (i == 0) {
        log.err("invalid size '{s}' (e.g. 50mb, 100kb, 1gb)", .{raw});
        std.process.exit(1);
    }
    const number = std.fmt.parseInt(u64, raw[0..i], 10) catch {
        log.err("invalid number in size '{s}'", .{raw[0..i]});
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
        log.err("unknown unit '{s}' (use kb, mb, or gb)", .{suffix});
        std.process.exit(1);
    };
    return number * multiplier;
}

/// Parse --trace-max value. Required when --trace is set.
fn parse_trace_max(cli: StartArgs) u64 {
    if (!cli.trace) return 0;
    const raw = cli.@"trace-max" orelse {
        log.err("--trace-max is required when using --trace (e.g. --trace-max=50mb)", .{});
        std.process.exit(1);
    };
    return parse_size(raw);
}

/// Generate a trace filename from the current timestamp.
/// Format: trace-YYYY-MM-DD-HHMMSS.json (30 chars + sentinel)
const trace_path_len = "trace-YYYY-MM-DD-HHMMSS.json".len;

fn generate_trace_path(cli: StartArgs) [trace_path_len:0]u8 {
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
fn validate_config(cli: StartArgs) *const [auth.key_length]u8 {
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
fn wire_sidecar(server: *Server, cli: StartArgs, allocator: std.mem.Allocator) !void {
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

fn log_startup(cli: StartArgs, actual_port: u16) void {
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

fn run_loop(
    server: *Server,
    io: *IO,
    supervisor: *?Supervisor,
    trace_writer: *?TraceWriter,
    tracer: *Trace.Tracer,
) void {
    var was_sidecar_connected: bool = false;
    var trace_limit_logged: bool = false;
    while (true) {
        server.tick();

        // Stop tracing when size limit reached. Log once, then
        // null the writer so the tracer stops emitting JSON.
        if (trace_writer.*) |*tw| {
            if (tw.limit_reached() and !trace_limit_logged) {
                log.info("trace file limit reached ({d} bytes), tracing stopped", .{tw.bytes_written});
                tracer.options.writer = null;
                trace_limit_logged = true;
            }
        }

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

const Command = union(enum) {
    start: StartArgs,
    trace: TraceArgs,

    pub const help =
        \\Usage:
        \\  tiger-web start [options] [-- sidecar-command...]
        \\  tiger-web trace --max=<size> :<port>
        \\
        \\Subcommands:
        \\  start   Start the server
        \\  trace   Attach to a running server and capture a trace
        \\
    ;
};

const StartArgs = struct {
    port: u16 = 3000,
    log_debug: bool = false,
    log_trace: bool = false,
    trace: bool = false,
    @"trace-max": ?[]const u8 = null,
    sidecar: ?[]const u8 = null,
    db: [:0]const u8 = "tiger_web.db",
    /// Extended args after `--` are the sidecar command argv.
    @"--": void,
};

const TraceArgs = struct {
    max: []const u8,
    /// Positional args follow @"--" sentinel.
    @"--": void,
    /// Positional: ":port" (e.g. ":3000")
    target: []const u8,
};
