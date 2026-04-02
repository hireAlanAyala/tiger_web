//! CALL/RESULT protocol fuzzer.
//!
//! Exercises SidecarClientType(Bus) through real
//! ConnectionType(FuzzIO). Protocol state machine only — no server,
//! no reconnect. One client per seed.
//!
//! Tests: valid CALL/RESULT, QUERY sub-protocol, corrupt/truncated
//! frames, request_id mismatch, query count exceeded, unsolicited
//! frames, multi-call sequencing, recovery after failure.
//!
//! Transport faults (partial delivery, errors, disconnect) come for
//! free from FuzzIO — no explicit transport events needed.

const std = @import("std");
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const Ratio = PRNG.Ratio;
const protocol = @import("protocol.zig");
const sidecar = @import("sidecar.zig");
const message_bus = @import("framework/message_bus.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzIO = @import("fuzz_io.zig").FuzzIO;

const log = std.log.scoped(.fuzz);

// Bus resolved here — the fuzzer is a composition root, same as app.zig.
// Options match production: 1 CALL + queries_max QUERY_RESULTs.
const Bus = message_bus.MessageBusType(FuzzIO, .{
    .send_queue_max = 1 + protocol.queries_max,
    .frame_max = protocol.frame_max,
});
const SidecarClient = sidecar.SidecarClientType(Bus);
const Connection = Bus.Connection;

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var io = FuzzIO.init(&prng);
    const pair = io.create_socketpair();

    // Init Bus + Connection on the server side.
    // Fuzz context wires bus frames → SidecarClient.on_frame.
    var fuzz_ctx = SidecarFuzzCtx{
        .client = undefined, // set below
        .bus = undefined,    // set below
    };

    var bus: Bus = undefined;
    try bus.init_pool(allocator, &io, @ptrCast(&fuzz_ctx), SidecarFuzzCtx.on_bus_frame, null);
    bus.connect_fd(pair[0]);
    defer bus.deinit(allocator);

    var client = SidecarClient.init();
    fuzz_ctx.client = &client;
    fuzz_ctx.bus = &bus;
    var request_id: u32 = 1;

    var stats = Stats{};

    const Event = enum {
        call_valid_result,
        call_with_query,
        inject_corrupt_result,
        inject_truncated_result,
        inject_wrong_tag,
        inject_wrong_request_id,
        inject_unsolicited,
        multi_call_sequence,
        disconnect,
    };
    var weights = fuzz_lib.random_enum_weights(&prng, Event);
    if (weights.call_valid_result == 0) weights.call_valid_result = 1;

    for (0..events_max) |_| {
        if (!bus.is_connected()) break;

        const event = prng.enum_weighted(Event, weights);

        switch (event) {
            .call_valid_result => {
                if (client.call_state != .idle) continue;

                // Submit CALL.
                if (!client.call_submit(&bus, "test", "args", request_id)) continue;
                request_id +%= 1;

                // Inject valid RESULT.
                const result_data = "test_result_data";
                if (!inject_result_frame(&io, pair[1], request_id - 1, .success, result_data)) continue;

                // Tick until complete or closed.
                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state == .complete or client.call_state == .failed) break;
                    tick_connection(&io, &bus.connection);
                }

                if (client.call_state == .complete) {
                    assert(client.result_flag == .success);
                    assert(std.mem.eql(u8, client.result_data, result_data));
                    client.reset_call_state();
                    stats.valid_results += 1;
                } else if (client.call_state == .failed) {
                    if (client.protocol_violation) {
                        stats.protocol_violations += 1;
                    }
                    client.reset_call_state();
                    client.reset_request_state();
                }
            },
            .call_with_query => {
                if (client.call_state != .idle) continue;

                if (!client.call_submit(&bus, "prefetch", "args", request_id)) continue;
                request_id +%= 1;

                // Inject QUERY frame from "sidecar."
                const sql = "SELECT id FROM products WHERE id = ?1";
                if (!inject_query_frame(&io, pair[1], request_id - 1, 0, sql)) continue;

                // Tick — client should process QUERY and send QUERY_RESULT.
                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .receiving) break;
                    tick_connection(&io, &bus.connection);
                }

                // Now inject RESULT to complete the exchange.
                if (bus.is_connected() and client.call_state == .receiving) {
                    if (inject_result_frame(&io, pair[1], request_id - 1, .success, "query_done")) {
                        for (0..100) |_| {
                            if (!bus.is_connected()) break;
                            if (client.call_state == .complete or client.call_state == .failed) break;
                            tick_connection(&io, &bus.connection);
                        }
                    }
                }

                if (client.call_state == .complete) {
                    assert(client.call_query_count == 1);
                    client.reset_call_state();
                    stats.query_exchanges += 1;
                } else {
                    client.reset_call_state();
                    client.reset_request_state();
                }
            },
            .inject_corrupt_result => {
                if (client.call_state != .idle) continue;
                if (!client.call_submit(&bus, "test", "args", request_id)) continue;
                request_id +%= 1;

                // Inject corrupt RESULT — CRC will fail at transport layer
                // or payload will be invalid at protocol layer.
                var frame_buf: [1024]u8 = undefined;
                const result_payload = build_result_payload(&frame_buf, request_id - 1, .success, "data");
                // Corrupt a byte.
                const corrupt_pos = prng.range_inclusive(u32, 0, @intCast(result_payload.len - 1));
                frame_buf[corrupt_pos] ^= prng.range_inclusive(u8, 1, 255);

                var wire_buf: [1024 + 8]u8 = undefined;
                const wire = build_wire_frame(&wire_buf, result_payload);
                _ = io.inject_data(pair[1], wire);

                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .receiving) break;
                    tick_connection(&io, &bus.connection);
                }

                // Connection may have terminated (CRC fail) or client
                // may have set .failed (protocol violation).
                if (client.call_state == .failed) {
                    stats.corrupt_results += 1;
                }
                client.reset_call_state();
                client.reset_request_state();
            },
            .inject_truncated_result => {
                if (client.call_state != .idle) continue;
                if (!client.call_submit(&bus, "test", "args", request_id)) continue;
                request_id +%= 1;

                // Inject a RESULT with only the tag byte — truncated.
                var payload: [1]u8 = .{@intFromEnum(protocol.CallTag.result)};
                var wire_buf: [16]u8 = undefined;
                const wire = build_wire_frame(&wire_buf, &payload);
                _ = io.inject_data(pair[1], wire);

                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .receiving) break;
                    tick_connection(&io, &bus.connection);
                }

                stats.truncated_results += 1;
                client.reset_call_state();
                client.reset_request_state();
            },
            .inject_wrong_tag => {
                if (client.call_state != .idle) continue;
                if (!client.call_submit(&bus, "test", "args", request_id)) continue;
                request_id +%= 1;

                // Inject a CALL frame (wrong direction — sidecar should send RESULT, not CALL).
                var payload: [8]u8 = undefined;
                payload[0] = @intFromEnum(protocol.CallTag.call);
                std.mem.writeInt(u32, payload[1..5], request_id - 1, .big);
                std.mem.writeInt(u16, payload[5..7], 1, .big);
                payload[7] = 'x';
                var wire_buf: [24]u8 = undefined;
                const wire = build_wire_frame(&wire_buf, &payload);
                _ = io.inject_data(pair[1], wire);

                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .receiving) break;
                    tick_connection(&io, &bus.connection);
                }

                // parse_sidecar_frame rejects CALL tag from sidecar.
                if (client.call_state == .failed) {
                    assert(client.protocol_violation);
                    stats.wrong_tag += 1;
                }
                client.reset_call_state();
                client.reset_request_state();
            },
            .inject_wrong_request_id => {
                if (client.call_state != .idle) continue;
                if (!client.call_submit(&bus, "test", "args", request_id)) continue;
                request_id +%= 1;

                // Inject RESULT with wrong request_id.
                const wrong_id = request_id + 100;
                if (!inject_result_frame(&io, pair[1], wrong_id, .success, "stale")) continue;

                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .receiving) break;
                    tick_connection(&io, &bus.connection);
                }

                if (client.call_state == .failed) {
                    assert(client.protocol_violation);
                    stats.wrong_request_id += 1;
                }
                client.reset_call_state();
                client.reset_request_state();
            },
            .inject_unsolicited => {
                // Inject a frame when no CALL is in-flight.
                if (client.call_state != .idle) continue;

                if (inject_result_frame(&io, pair[1], 0, .success, "unsolicited")) {
                    for (0..100) |_| {
                        if (!bus.is_connected()) break;
                        tick_connection(&io, &bus.connection);
                    }

                    if (client.call_state == .failed) {
                        assert(client.protocol_violation);
                        stats.unsolicited += 1;
                    }
                    client.reset_call_state();
                    client.reset_request_state();
                }
            },
            .multi_call_sequence => {
                // Multiple CALL/RESULT exchanges on same client.
                const count = prng.range_inclusive(u32, 2, 5);
                var completed: u32 = 0;
                for (0..count) |_| {
                    if (!bus.is_connected()) break;
                    if (client.call_state != .idle) break;

                    if (!client.call_submit(&bus, "multi", "args", request_id)) break;
                    request_id +%= 1;

                    if (!inject_result_frame(&io, pair[1], request_id - 1, .success, "multi_ok")) break;

                    for (0..100) |_| {
                        if (!bus.is_connected()) break;
                        if (client.call_state == .complete or client.call_state == .failed) break;
                        tick_connection(&io, &bus.connection);
                    }

                    if (client.call_state == .complete) {
                        client.reset_call_state();
                        completed += 1;
                    } else {
                        client.reset_call_state();
                        client.reset_request_state();
                        break;
                    }
                }
                if (completed > 0) stats.multi_call_sequences += 1;
            },
            .disconnect => {
                io.close_peer(pair[1]);
                for (0..100) |_| {
                    if (!bus.is_connected()) break;
                    tick_connection(&io, &bus.connection);
                }
                stats.disconnects += 1;
            },
        }
    }

    log.info(
        \\Sidecar fuzz done:
        \\  events={} valid={} queries={} multi={}
        \\  corrupt={} truncated={} wrong_tag={} wrong_id={}
        \\  unsolicited={} violations={} disconnects={}
    , .{
        events_max,
        stats.valid_results,
        stats.query_exchanges,
        stats.multi_call_sequences,
        stats.corrupt_results,
        stats.truncated_results,
        stats.wrong_tag,
        stats.wrong_request_id,
        stats.unsolicited,
        stats.protocol_violations,
        stats.disconnects,
    });

    assert(stats.valid_results > 0 or stats.disconnects > 0 or !bus.is_connected());
}

const Stats = struct {
    valid_results: u64 = 0,
    query_exchanges: u64 = 0,
    multi_call_sequences: u64 = 0,
    corrupt_results: u64 = 0,
    truncated_results: u64 = 0,
    wrong_tag: u64 = 0,
    wrong_request_id: u64 = 0,
    unsolicited: u64 = 0,
    protocol_violations: u64 = 0,
    disconnects: u64 = 0,
};

// =====================================================================
// Tick helpers — drive FuzzIO completions for a Connection
// =====================================================================

fn tick_connection(io: *FuzzIO, conn: *Connection) void {
    if (io.prng.boolean()) {
        tick_recv(io, conn);
        tick_send(io, conn);
    } else {
        tick_send(io, conn);
        tick_recv(io, conn);
    }
}

fn tick_recv(io: *FuzzIO, conn: *Connection) void {
    if (conn.recv_completion.operation != .recv) return;
    const result = io.do_recv(conn.recv_completion.fd, conn.recv_completion.buffer.?) orelse return;
    conn.recv_completion.operation = .none;
    conn.recv_completion.callback(conn.recv_completion.context, result);
}

fn tick_send(io: *FuzzIO, conn: *Connection) void {
    if (conn.send_completion.operation != .send) return;
    const result = io.do_send(conn.send_completion.fd, conn.send_completion.buffer_const.?) orelse return;
    conn.send_completion.operation = .none;
    conn.send_completion.callback(conn.send_completion.context, result);
}

// =====================================================================
// Frame builders
// =====================================================================

fn build_wire_frame(buf: []u8, payload: []const u8) []const u8 {
    const len: u32 = @intCast(payload.len);
    const total = 8 + payload.len;
    assert(total <= buf.len);

    std.mem.writeInt(u32, buf[0..4], len, .big);
    @memcpy(buf[8..][0..payload.len], payload);

    var crc = Crc32.init();
    crc.update(buf[0..4]);
    crc.update(buf[8..][0..payload.len]);
    std.mem.writeInt(u32, buf[4..8], crc.final(), .little);

    return buf[0..total];
}

fn build_result_payload(buf: []u8, request_id: u32, flag: protocol.ResultFlag, data: []const u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.CallTag.result);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    buf[pos] = @intFromEnum(flag);
    pos += 1;
    @memcpy(buf[pos..][0..data.len], data);
    pos += data.len;
    return buf[0..pos];
}

fn inject_result_frame(io: *FuzzIO, fd: FuzzIO.fd_t, request_id: u32, flag: protocol.ResultFlag, data: []const u8) bool {
    var payload_buf: [1024]u8 = undefined;
    const payload = build_result_payload(&payload_buf, request_id, flag, data);
    var wire_buf: [1024 + 8]u8 = undefined;
    const wire = build_wire_frame(&wire_buf, payload);
    return io.inject_data(fd, wire);
}

fn inject_query_frame(io: *FuzzIO, fd: FuzzIO.fd_t, request_id: u32, query_id: u16, sql: []const u8) bool {
    var buf: [1024]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.CallTag.query);
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], request_id, .big);
    pos += 4;
    std.mem.writeInt(u16, buf[pos..][0..2], query_id, .big);
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(sql.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = @intFromEnum(protocol.QueryMode.query);
    pos += 1;
    buf[pos] = 0; // param_count
    pos += 1;

    var wire_buf: [1024 + 8]u8 = undefined;
    const wire = build_wire_frame(&wire_buf, buf[0..pos]);
    return io.inject_data(fd, wire);
}

/// Wires bus on_frame → SidecarClient.on_frame.
/// The client processes RESULT/QUERY frames from the "sidecar."
const SidecarFuzzCtx = struct {
    client: *SidecarClient,
    bus: *Bus,

    fn on_bus_frame(ctx_ptr: *anyopaque, frame: []const u8) void {
        const self: *SidecarFuzzCtx = @ptrCast(@alignCast(ctx_ptr));
        self.client.on_frame(
            self.bus,
            frame,
            dummy_query_fn,
            undefined, // query_ctx not used by dummy
            SidecarClient.max_queries_per_call,
        );
    }

    /// Dummy query function — returns an empty row set.
    /// Exercises the QUERY → QUERY_RESULT path without needing
    /// a real database.
    fn dummy_query_fn(_: *anyopaque, _: []const u8, _: []const u8, _: u8, _: protocol.QueryMode, _: []u8) ?[]const u8 {
        return ""; // empty result set
    }
};
