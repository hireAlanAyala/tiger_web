const std = @import("std");
const IO = @import("io.zig").IO;
const ServerType = @import("server.zig").ServerType;
const StateMachine = @import("state_machine.zig").StateMachine;

const Server = ServerType(IO);
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.main));

/// Tick interval in nanoseconds (10ms).
const tick_ns: u64 = 10 * std.time.ns_per_ms;

/// Shutdown timeout: 5 seconds = 500 ticks at 10ms/tick.
const shutdown_timeout_ticks: u32 = 500;

var shutdown_requested: bool = false;

fn signal_handler(_: c_int) callconv(.c) void {
    shutdown_requested = true;
}

pub fn main() !void {
    // Parse port from args, default to 3000.
    const port = parsePort();

    const address = try std.net.Address.parseIp4("0.0.0.0", port);

    var io = try IO.init();
    defer io.deinit();

    var state_machine = try StateMachine.init(std.heap.page_allocator);
    defer state_machine.deinit(std.heap.page_allocator);

    const listen_fd = try IO.open_listener(address);

    var server = Server.init(&io, &state_machine, listen_fd);

    // Install signal handlers for graceful shutdown.
    const act = std.posix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    log.info("listening on port {d}", .{port});

    // Main event loop — the heart of Tiger Style.
    // 1. Tick: process inbox, execute state machine, flush outbox.
    // 2. IO: poll for network events, fire callbacks.
    var shutdown_tick: ?u32 = null;

    while (true) {
        server.tick();
        io.run_for_ns(tick_ns);

        if (shutdown_requested and shutdown_tick == null) {
            log.info("shutdown initiated", .{});
            server.shutdown();
            shutdown_tick = server.tick_count;
        }

        if (shutdown_tick) |start_tick| {
            if (!server.has_active_connections()) {
                log.info("shutdown complete", .{});
                break;
            }
            // Force exit after timeout.
            if (server.tick_count -% start_tick >= shutdown_timeout_ticks) {
                log.warn("shutdown timeout, forcing exit", .{});
                break;
            }
        }
    }
}

fn parsePort() u16 {
    var args = std.process.args();
    _ = args.skip(); // program name

    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--port=")) {
            const port_str = arg["--port=".len..];
            return std.fmt.parseInt(u16, port_str, 10) catch 3000;
        }
    }

    return 3000;
}
