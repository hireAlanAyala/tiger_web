const std = @import("std");
const IO = @import("io.zig").IO;
const state_machine = @import("state_machine.zig");
const SqliteStorage = @import("storage.zig").SqliteStorage;
const StateMachine = state_machine.StateMachineType(SqliteStorage);
const ServerType = @import("server.zig").ServerType;

const Server = ServerType(IO, SqliteStorage);
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.main));

/// Tick interval in nanoseconds (10ms).
const tick_ns: u64 = 10 * std.time.ns_per_ms;

pub fn main() !void {
    // Parse port from args, default to 3000.
    const port = parsePort();

    const address = try std.net.Address.parseIp4("0.0.0.0", port);

    var io = try IO.init();
    defer io.deinit();

    var storage = try SqliteStorage.init("tiger_web.db");
    defer storage.deinit();
    var sm = StateMachine.init(&storage);

    const listen_fd = try IO.open_listener(address);

    var server = Server.init(&io, &sm, listen_fd);

    log.info("listening on port {d}", .{port});

    // Main event loop. No signal handling — let the OS kill the process.
    while (true) {
        server.tick();
        io.run_for_ns(tick_ns);
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
