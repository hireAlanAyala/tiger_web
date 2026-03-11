const std = @import("std");
const IO = @import("io.zig").IO;
const SimIO = @import("sim.zig").SimIO;
const SqliteStorage = @import("storage.zig").SqliteStorage;
const state_machine = @import("state_machine.zig");
const MemoryStorage = state_machine.MemoryStorage;
const ServerType = @import("server.zig").ServerType;
const ConnectionType = @import("connection.zig").ConnectionType;

// Production instantiations.
const ProdStateMachine = state_machine.StateMachineType(SqliteStorage);
const ProdServer = ServerType(IO, SqliteStorage);
const ProdConnection = ConnectionType(IO);

// Test/sim instantiations.
const TestStateMachine = state_machine.StateMachineType(MemoryStorage);
const TestServer = ServerType(SimIO, MemoryStorage);
const TestConnection = ConnectionType(SimIO);

/// Comptime: build the full type introspection map as a JSON string.
/// This enumerates every declaration on each generic instantiation,
/// plus field types, so the graph tool can resolve method calls correctly.
const type_map_json = blk: {
    @setEvalBranchQuota(10000);
    var buf: [32768]u8 = undefined;
    var w = Writer{ .buf = &buf, .pos = 0 };

    w.raw("{\"instantiations\":[");

    // Production types.
    w.dumpType("StateMachine<SqliteStorage>", "state_machine.zig", ProdStateMachine);
    w.raw(",");
    w.dumpType("Server<IO,SqliteStorage>", "server.zig", ProdServer);
    w.raw(",");
    w.dumpType("Connection<IO>", "connection.zig", ProdConnection);
    w.raw(",");

    // Test types.
    w.dumpType("StateMachine<MemoryStorage>", "state_machine.zig", TestStateMachine);
    w.raw(",");
    w.dumpType("Server<SimIO,MemoryStorage>", "server.zig", TestServer);
    w.raw(",");
    w.dumpType("Connection<SimIO>", "connection.zig", TestConnection);
    w.raw(",");

    // Concrete (non-generic) types.
    w.dumpType("SqliteStorage", "storage.zig", SqliteStorage);
    w.raw(",");
    w.dumpType("MemoryStorage", "state_machine.zig", MemoryStorage);
    w.raw(",");
    w.dumpType("SimIO", "sim.zig", SimIO);
    w.raw(",");
    w.dumpType("IO", "io.zig", IO);

    w.raw("],");

    // Storage interface: shared methods between SqliteStorage and MemoryStorage.
    // This lets the graph tool know which calls are "through the Storage interface."
    w.raw("\"storage_interface\":[");
    {
        const decls = @typeInfo(SqliteStorage).@"struct".decls;
        for (decls, 0..) |decl, i| {
            if (i > 0) w.raw(",");
            w.raw("\"");
            w.raw(decl.name);
            w.raw("\"");
        }
    }
    w.raw("],");

    // IO interface: shared methods between IO and SimIO.
    w.raw("\"io_interface\":[");
    {
        const decls = @typeInfo(IO).@"struct".decls;
        for (decls, 0..) |decl, i| {
            if (i > 0) w.raw(",");
            w.raw("\"");
            w.raw(decl.name);
            w.raw("\"");
        }
    }
    w.raw("]}\n");

    const final = buf[0..w.pos];
    break :blk final[0..final.len].*;
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(&type_map_json);
}

/// Comptime string writer — no allocator needed.
const Writer = struct {
    buf: *[32768]u8,
    pos: usize,

    fn raw(w: *Writer, s: []const u8) void {
        @memcpy(w.buf[w.pos..][0..s.len], s);
        w.pos += s.len;
    }

    fn dumpType(w: *Writer, comptime name: []const u8, comptime file: []const u8, comptime T: type) void {
        const info = @typeInfo(T);
        if (info != .@"struct") return;

        w.raw("{\"name\":\"");
        w.raw(name);
        w.raw("\",\"file\":\"");
        w.raw(file);
        w.raw("\",\"decls\":[");

        const decls = info.@"struct".decls;
        var first = true;
        for (decls) |decl| {
            if (!first) w.raw(",");
            first = false;
            w.raw("\"");
            w.raw(decl.name);
            w.raw("\"");
        }
        w.raw("],\"fields\":[");

        const fields = info.@"struct".fields;
        var first_f = true;
        for (fields) |field| {
            if (!first_f) w.raw(",");
            first_f = false;
            w.raw("{\"name\":\"");
            w.raw(field.name);
            w.raw("\",\"type\":\"");
            w.raw(@typeName(field.type));
            w.raw("\"}");
        }
        w.raw("]}");
    }
};
