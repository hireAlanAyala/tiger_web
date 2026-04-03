//! Sidecar simulation tests — full-stack tests with deterministic IO.
//!
//! Exercises the complete sidecar pipeline (route → prefetch → handle →
//! render) through the real Server + SM + MessageBus + Connection stack.
//! SimSidecar acts as the sidecar process: parses CALL frames, builds
//! RESULT frames, injects via SimIO. Hardcoded responses — tests the
//! framework pipeline, not handler logic.
//!
//! This binary is compiled with sidecar_enabled = true (via build_options).

const std = @import("std");
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const http = @import("framework/http.zig");
const App = @import("app.zig");
const Storage = App.Storage;
const ServerType = @import("framework/server.zig").ServerType;
const PRNG = @import("stdx").PRNG;
const TimeSim = @import("framework/time.zig").TimeSim;
const auth = @import("framework/auth.zig");
const SimIO = @import("sim_io.zig").SimIO;

pub const std_options: std.Options = .{
    .log_level = .err,
};

const Server = ServerType(App, SimIO, Storage);
const Handlers = App.HandlersFor(Storage, SimIO);
const StateMachine = App.StateMachineWith(Storage, Handlers.BusType.connections_max);

const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

// =====================================================================
// SimSidecar — deterministic sidecar process simulator
// =====================================================================

const SimSidecar = struct {
    io: *SimIO,
    slot: usize,
    listen_fd: SimIO.fd_t,

    // Frame accumulation — partial delivery means CRC-framed data
    // may arrive across multiple ticks.
    frame_buf: [protocol.frame_max + 8]u8,
    frame_len: u32,
    recv_pos: u32, // how far we've consumed from io.clients[slot].recv_buf

    // Pending response — built after parsing a CALL, injected after delay.
    response_buf: [protocol.frame_max + 8]u8,
    response_len: u32,
    response_pending: bool,

    /// Count of CALLs processed. Tests use this to detect pipeline
    /// progress (e.g., wait until handle CALL is done before
    /// injecting a fault during render).
    calls_processed: u32,

    fn init(io: *SimIO, slot: usize, listen_fd: SimIO.fd_t) SimSidecar {
        return .{
            .io = io,
            .slot = slot,
            .listen_fd = listen_fd,
            .frame_buf = undefined,
            .frame_len = 0,
            .recv_pos = 0,
            .response_buf = undefined,
            .response_len = 0,
            .response_pending = false,
            .calls_processed = 0,
        };
    }

    /// Connect the sidecar to the server's sidecar bus.
    /// Just marks the SimIO client as connected. The caller must run
    /// ticks for the accept to complete, then call inject_ready().
    fn connect(self: *SimSidecar) void {
        assert(!self.io.clients[self.slot].connected);
        self.io.connect_client(self.slot, self.listen_fd);
        self.frame_len = 0;
        self.recv_pos = 0;
        self.response_pending = false;
    }

    /// Inject the READY handshake frame. Call after the bus has accepted
    /// the connection (client is accepted, Connection is connected).
    fn inject_ready(self: *SimSidecar) void {
        // READY frame: [tag=0x20][version: u16 BE]
        var ready_payload: [3]u8 = undefined;
        ready_payload[0] = @intFromEnum(protocol.CallTag.ready);
        std.mem.writeInt(u16, ready_payload[1..3], protocol.protocol_version, .big);
        var wire_buf: [11]u8 = undefined; // 8 header + 3 payload
        const wire = build_wire_frame(&wire_buf, &ready_payload);
        self.io.inject_bytes(self.slot, wire);
    }

    fn disconnect(self: *SimSidecar) void {
        self.io.disconnect_client(self.slot);
        self.response_pending = false;
    }

    /// Process one tick. Reads new bytes from the SimIO client recv_buf
    /// (data the server sent to us), accumulates CRC frames, parses
    /// CALLs, builds and injects RESULTs.
    fn tick(self: *SimSidecar) void {
        // Inject pending response.
        if (self.response_pending) {
            self.io.inject_bytes(self.slot, self.response_buf[0..self.response_len]);
            self.response_pending = false;
        }

        // Read new bytes from recv_buf.
        const client = &self.io.clients[self.slot];
        if (!client.connected) return;
        if (client.recv_len <= self.recv_pos) return;

        const new_data = client.recv_buf[self.recv_pos..client.recv_len];
        const space = self.frame_buf.len - self.frame_len;
        // In sim, frames are always smaller than frame_buf (frame_max + 8).
        // Overflow means a bug in the test or protocol, not partial delivery.
        assert(new_data.len <= space);
        @memcpy(self.frame_buf[self.frame_len..][0..new_data.len], new_data);
        self.frame_len += @intCast(new_data.len);
        self.recv_pos += @intCast(new_data.len);

        // Try to parse a complete CRC frame.
        self.try_process_frame();
    }

    fn try_process_frame(self: *SimSidecar) void {
        // Need at least 8 bytes for the header.
        if (self.frame_len < 8) return;

        const payload_len = std.mem.readInt(u32, self.frame_buf[0..4], .big);
        const total = 8 + payload_len;
        if (self.frame_len < total) return; // incomplete

        // Validate CRC.
        const stored_crc = std.mem.readInt(u32, self.frame_buf[4..8], .little);
        var crc = Crc32.init();
        crc.update(self.frame_buf[0..4]); // len bytes
        crc.update(self.frame_buf[8..][0..payload_len]); // payload
        assert(crc.final() == stored_crc); // sim frames are valid

        const payload = self.frame_buf[8..][0..payload_len];
        self.process_call(payload);

        // Compact: shift remaining bytes forward.
        const remaining = self.frame_len - total;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.frame_buf[0..remaining], self.frame_buf[total..][0..remaining]);
        }
        self.frame_len = @intCast(remaining);
    }

    fn process_call(self: *SimSidecar, payload: []const u8) void {
        // CALL format: [tag=0x10][request_id: u32 BE][name_len: u16 BE][name][args...]
        assert(payload.len >= 7);
        assert(payload[0] == @intFromEnum(protocol.CallTag.call));
        const request_id = std.mem.readInt(u32, payload[1..5], .big);
        const name_len = std.mem.readInt(u16, payload[5..7], .big);
        assert(7 + name_len <= payload.len);
        const name = payload[7..][0..name_len];
        const args = payload[7 + name_len ..];

        // Build RESULT based on function name.
        var result_payload: [1024]u8 = undefined;
        var pos: usize = 0;

        // RESULT header: [tag=0x11][request_id: u32 BE][flag: u8]
        result_payload[0] = @intFromEnum(protocol.CallTag.result);
        pos += 1;
        std.mem.writeInt(u32, result_payload[pos..][0..4], request_id, .big);
        pos += 4;
        result_payload[pos] = @intFromEnum(protocol.ResultFlag.success);
        pos += 1;

        // Result data depends on function name.
        if (std.mem.eql(u8, name, "route")) {
            pos += build_route_result(result_payload[pos..], args);
        } else if (std.mem.eql(u8, name, "prefetch")) {
            // Empty result — just success flag (already written).
        } else if (std.mem.eql(u8, name, "handle")) {
            pos += build_handle_result(result_payload[pos..]);
        } else if (std.mem.eql(u8, name, "render")) {
            const html_content = "<div>sim</div>";
            @memcpy(result_payload[pos..][0..html_content.len], html_content);
            pos += html_content.len;
        } else {
            // Unknown function — still return success with empty data.
        }

        // Wrap in CRC wire frame and queue for injection.
        self.response_len = @intCast(build_wire_frame_into(&self.response_buf, result_payload[0..pos]));
        self.response_pending = true;
        self.calls_processed += 1;
    }

    /// Build route RESULT data: [operation: u8][id: 16 bytes LE][body]
    fn build_route_result(buf: []u8, args: []const u8) usize {
        // Args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
        assert(args.len >= 5);
        var apos: usize = 0;
        _ = args[apos]; // method byte
        apos += 1;
        const path_len = std.mem.readInt(u16, args[apos..][0..2], .big);
        apos += 2;
        const path = args[apos..][0..path_len];
        apos += path_len;
        const body_len = std.mem.readInt(u16, args[apos..][0..2], .big);
        apos += 2;
        const body = args[apos..][0..body_len];

        const op: message.Operation = if (std.mem.eql(u8, path, "/products"))
            .create_product
        else
            .list_products;

        var pos: usize = 0;
        buf[pos] = @intFromEnum(op);
        pos += 1;
        @memset(buf[pos..][0..16], 0); // zero UUID
        pos += 16;
        if (body.len > 0) {
            @memcpy(buf[pos..][0..body.len], body);
            pos += body.len;
        }
        return pos;
    }

    /// Build handle RESULT data:
    /// [status_name_len: u16 BE]["ok"][session_action: 0][write_count: 0]
    fn build_handle_result(buf: []u8) usize {
        var pos: usize = 0;
        const status_name = "ok";
        std.mem.writeInt(u16, buf[pos..][0..2], status_name.len, .big);
        pos += 2;
        @memcpy(buf[pos..][0..status_name.len], status_name);
        pos += status_name.len;
        buf[pos] = 0; // session_action = none
        pos += 1;
        buf[pos] = 0; // write_count = 0
        pos += 1;
        return pos;
    }
};

// =====================================================================
// CRC wire frame helpers
// =====================================================================

fn build_wire_frame_into(buf: []u8, payload: []const u8) usize {
    const len: u32 = @intCast(payload.len);
    const total = 8 + payload.len;
    assert(total <= buf.len);

    std.mem.writeInt(u32, buf[0..4], len, .big);
    @memcpy(buf[8..][0..payload.len], payload);

    var crc = Crc32.init();
    crc.update(buf[0..4]);
    crc.update(buf[8..][0..payload.len]);
    std.mem.writeInt(u32, buf[4..8], crc.final(), .little);

    return total;
}

fn build_wire_frame(buf: []u8, payload: []const u8) []const u8 {
    const total = build_wire_frame_into(buf, payload);
    return buf[0..total];
}

// =====================================================================
// Test harness — shared setup/teardown for all sidecar sim tests
// =====================================================================

const TestHarness = struct {
    io: SimIO,
    storage: Storage,
    sm: StateMachine,
    server: Server,
    sidecar: SimSidecar,
    sidecar_b: SimSidecar, // standby (hot standby tests)
    allocator: std.mem.Allocator,
    post_count: u8,

    const http_listen_fd: SimIO.fd_t = 1;
    const sidecar_listen_fd: SimIO.fd_t = 2;
    const sidecar_slot: usize = 0;
    const sidecar_slot_b: usize = 2; // second sidecar connection
    const http_slot: usize = 1;
    const http_slot_b: usize = 3; // second HTTP client (concurrent tests)
    /// Max ticks for run_until/run_server_until before panic.
    /// 500 ticks = 5s at 10ms/tick. Tight enough to catch slow
    /// convergence, generous enough for partial delivery + timeout.
    const max_wait_ticks: usize = 600;

    /// In-place init — the harness must be at its final address
    /// before init because Server stores &io and &sm pointers.
    /// Caller: `var h: TestHarness = undefined; try h.init();`
    fn init(h: *TestHarness) !void {
        h.allocator = std.testing.allocator;
        var seed_prng = PRNG.from_seed_testing();
        h.io = SimIO.init(seed_prng.int(u64));
        h.storage = try Storage.init(":memory:");

        var time_sim = TimeSim{};
        h.sm = StateMachine.init(&h.storage, false, 0, test_key);
        h.server = try Server.init(h.allocator, &h.io, &h.sm, http_listen_fd, time_sim.time(), null);
        try h.server.wire_sidecar(h.allocator, null);
        h.server.sidecar_bus.listen_fd = sidecar_listen_fd;

        h.sidecar = SimSidecar.init(&h.io, sidecar_slot, sidecar_listen_fd);
        h.sidecar_b = SimSidecar.init(&h.io, sidecar_slot_b, sidecar_listen_fd);
        h.post_count = 0;
    }

    fn deinit(h: *TestHarness) void {
        // Disconnect both sidecars and drain until bus connections close.
        if (h.io.clients[sidecar_slot].connected) {
            h.sidecar.disconnect();
        }
        if (h.io.clients[sidecar_slot_b].connected) {
            h.sidecar_b.disconnect();
        }
        if (h.server.sidecar_bus.is_connected()) {
            h.run_server_until(bus_closed);
        }
        h.server.deinit(h.allocator);
        h.storage.deinit();
    }

    fn bus_closed(h: *TestHarness) bool {
        return !h.server.sidecar_bus.is_connected();
    }

    /// Connect primary sidecar and complete READY handshake.
    fn connect_sidecar(h: *TestHarness) void {
        h.sidecar.connect();
        h.run_until(sidecar_accepted);
        h.sidecar.inject_ready();
        h.run_until(sidecar_connected);
    }

    /// Connect standby sidecar and complete READY handshake.
    fn connect_standby(h: *TestHarness) void {
        h.sidecar_b.connect();
        h.run_until(standby_accepted);
        h.sidecar_b.inject_ready();
        h.run_until(standby_ready);
    }

    fn sidecar_accepted(h: *TestHarness) bool {
        return h.io.clients[sidecar_slot].accepted;
    }

    fn standby_accepted(h: *TestHarness) bool {
        return h.io.clients[sidecar_slot_b].accepted;
    }

    fn standby_ready(h: *TestHarness) bool {
        // Standby is ready when its slot has completed READY.
        // It won't be active (primary was first).
        return h.server.sidecar_connections_ready[1];
    }

    fn sidecar_connected(h: *TestHarness) bool {
        return h.server.sidecar_any_ready();
    }

    fn sidecar_disconnected(h: *TestHarness) bool {
        return !h.server.sidecar_any_ready();
    }

    fn slot_1_ready(h: *TestHarness) bool {
        return h.server.sidecar_connections_ready[1];
    }

    fn handler_pending(h: *TestHarness) bool {
        // Check any handler for pending state (first non-idle slot).
        for (&h.server.handlers, &h.server.pipeline_slots) |*handler, *slot| {
            if (slot.stage != .idle) return handler.is_handler_pending();
        }
        return false;
    }

    /// Route + prefetch + handle CALLs complete (3 calls).
    fn handle_call_done(h: *TestHarness) bool {
        return h.sidecar.calls_processed >= 3;
    }

    /// All 4 CALLs processed (route + prefetch + handle + render).
    /// The render RESULT is pending but not yet injected.
    fn render_call_done(h: *TestHarness) bool {
        return h.sidecar.calls_processed >= 4;
    }

    /// Connect HTTP client on http_slot.
    fn connect_http(h: *TestHarness) void {
        h.io.connect_client(http_slot, http_listen_fd);
        h.run_until(http_accepted);
    }

    fn http_accepted(h: *TestHarness) bool {
        return h.io.clients[http_slot].accepted;
    }

    /// Prepare for next HTTP request. Handles both keep-alive (clear
    /// response buffer) and Connection: close (reconnect).
    fn prepare_next_request(h: *TestHarness) void {
        h.io.clear_response(http_slot);
        if (h.io.clients[http_slot].server_closed) {
            // Connection: close — need a fresh connection.
            h.io.connect_client(http_slot, http_listen_fd);
            h.run_until(http_accepted);
        }
        // Keep-alive — connection still open, just cleared the buffer.
    }

    /// Inject a POST to /products with a unique UUID.
    /// Each call uses a different ID to avoid duplicate key errors.
    fn inject_post(h: *TestHarness) void {
        h.post_count += 1;
        var id_buf: [32]u8 = "aabbccdd11223344aabbccdd11223300".*;
        // Vary the last two hex chars by post_count.
        const hex = "0123456789abcdef";
        id_buf[30] = hex[h.post_count / 16];
        id_buf[31] = hex[h.post_count % 16];

        var body_buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"id\":\"{s}\",\"name\":\"Widget\",\"price_cents\":100}}", .{id_buf}) catch unreachable;
        h.io.inject_post(http_slot, "/products", body);
    }

    /// Tick server + sidecar + IO until predicate is true.
    /// Panics if max_ticks exceeded — the condition should always
    /// be reachable. No magic tick counts, no hope.
    fn run_until(h: *TestHarness, comptime predicate: fn (*TestHarness) bool) void {
        for (0..max_wait_ticks) |_| {
            h.tick_all();
            if (predicate(h)) return;
        }
        @panic("run_until: condition not reached");
    }

    /// Tick server + IO only (sidecar not ticked). For simulating
    /// stuck sidecar or advancing server state without sidecar
    /// processing.
    fn run_server_until(h: *TestHarness, comptime predicate: fn (*TestHarness) bool) void {
        for (0..max_wait_ticks) |_| {
            h.server.tick();
            h.io.run_for_ns(10 * std.time.ns_per_ms);
            if (predicate(h)) return;
        }
        @panic("run_server_until: condition not reached");
    }

    /// One tick of everything.
    fn tick_all(h: *TestHarness) void {
        h.server.tick();
        h.sidecar.tick();
        h.sidecar_b.tick();
        h.io.run_for_ns(10 * std.time.ns_per_ms);
    }

    /// Run until HTTP response arrives. Tries both keep-alive and
    /// close responses (503 uses Connection: close).
    fn wait_response(h: *TestHarness) ?SimIO.HttpResponse {
        for (0..max_wait_ticks) |_| {
            h.tick_all();
            if (h.io.read_response(http_slot)) |resp| return resp;
            if (h.io.read_close_response(http_slot)) |resp| return resp;
        }
        return null;
    }

    // --- Concurrent dispatch helpers ---

    /// Connect second HTTP client.
    fn connect_http_b(h: *TestHarness) void {
        h.io.connect_client(http_slot_b, http_listen_fd);
        h.run_until(http_b_accepted);
    }

    fn http_b_accepted(h: *TestHarness) bool {
        return h.io.clients[http_slot_b].accepted;
    }

    /// Inject POST on second HTTP client.
    fn inject_post_b(h: *TestHarness) void {
        h.post_count += 1;
        var id_buf: [32]u8 = "bbccddee22334455bbccddee22334400".*;
        const hex = "0123456789abcdef";
        id_buf[30] = hex[h.post_count / 16];
        id_buf[31] = hex[h.post_count % 16];

        var body_buf: [128]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"id\":\"{s}\",\"name\":\"Gadget\",\"price_cents\":200}}", .{id_buf}) catch unreachable;
        h.io.inject_post(http_slot_b, "/products", body);
    }

    /// Wait for response on second HTTP client.
    fn wait_response_b(h: *TestHarness) ?SimIO.HttpResponse {
        for (0..max_wait_ticks) |_| {
            h.tick_all();
            if (h.io.read_response(http_slot_b)) |resp| return resp;
            if (h.io.read_close_response(http_slot_b)) |resp| return resp;
        }
        return null;
    }

    /// Wait until BOTH HTTP clients have responses.
    fn wait_both_responses(h: *TestHarness) ?struct { a: SimIO.HttpResponse, b: SimIO.HttpResponse } {
        var resp_a: ?SimIO.HttpResponse = null;
        var resp_b: ?SimIO.HttpResponse = null;
        for (0..max_wait_ticks) |_| {
            h.tick_all();
            if (resp_a == null) {
                resp_a = h.io.read_response(http_slot) orelse h.io.read_close_response(http_slot);
            }
            if (resp_b == null) {
                resp_b = h.io.read_response(http_slot_b) orelse h.io.read_close_response(http_slot_b);
            }
            if (resp_a != null and resp_b != null) return .{ .a = resp_a.?, .b = resp_b.? };
        }
        return null;
    }

    /// Count active (non-idle) pipeline slots.
    fn active_slot_count(h: *TestHarness) u32 {
        var count: u32 = 0;
        for (&h.server.pipeline_slots) |*slot| {
            if (slot.stage != .idle) count += 1;
        }
        return count;
    }

    /// Both sidecar handlers have processed at least one CALL each.
    fn both_sidecars_called(h: *TestHarness) bool {
        return h.sidecar.calls_processed >= 1 and h.sidecar_b.calls_processed >= 1;
    }
};

// =====================================================================
// Tests
// =====================================================================

test {
    std.testing.log_level = .err;
}

test "CRC wire frame: SimSidecar build agrees with Connection validate" {
    // Pair assertion: build_wire_frame_into (SimSidecar's encoder) must
    // produce frames that Connection.advance (the real decoder) accepts.
    // Both hash [len BE] ++ [payload], store CRC as [LE] at offset 4.
    const payload = "test payload data";
    var buf: [128]u8 = undefined;
    const total = build_wire_frame_into(&buf, payload);

    // Verify structure: [len: u32 BE][crc: u32 LE][payload]
    const len = std.mem.readInt(u32, buf[0..4], .big);
    try std.testing.expectEqual(@as(u32, payload.len), len);
    try std.testing.expectEqual(@as(usize, 8 + payload.len), total);
    try std.testing.expect(std.mem.eql(u8, buf[8..][0..payload.len], payload));

    // Recompute CRC the same way Connection.advance does and verify match.
    const stored_crc = std.mem.readInt(u32, buf[4..8], .little);
    var crc = Crc32.init();
    crc.update(buf[0..4]); // len bytes
    crc.update(buf[8..][0..len]); // payload bytes
    try std.testing.expectEqual(crc.final(), stored_crc);
}

test "sidecar: basic request-response" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    try std.testing.expect(h.server.sidecar_any_ready());

    h.connect_http();
    h.inject_post();

    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}

test "sidecar: down at startup → 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    // Don't connect sidecar — server has no sidecar.
    try std.testing.expect(!h.server.sidecar_any_ready());

    h.connect_http();
    h.inject_post();

    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

test "sidecar: disconnect mid-request → 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_http();
    h.inject_post();

    // Let the server start processing (CALL sent to sidecar).
    h.run_until(TestHarness.handler_pending);

    // Disconnect sidecar mid-exchange.
    h.sidecar.disconnect();
    h.run_server_until(TestHarness.sidecar_disconnected);

    // Server should return 503 (pipeline was reset).
    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

test "sidecar: reconnect after disconnect → 200" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_http();

    // First request succeeds.
    h.inject_post();
    const resp1 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);

    // Disconnect sidecar.
    h.sidecar.disconnect();
    h.run_server_until(TestHarness.sidecar_disconnected);

    // Reconnect sidecar.
    h.connect_sidecar();
    try std.testing.expect(h.server.sidecar_any_ready());

    // New request succeeds.
    h.prepare_next_request();
    h.inject_post();
    const resp2 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resp2.status_code);
}

test "sidecar: multiple requests during disconnect → all 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    // Don't connect sidecar.
    h.connect_http();

    // First request → 503.
    h.inject_post();
    const resp1 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp1.status_code);

    // Second request → 503 (reconnect because Connection: close).
    h.prepare_next_request();
    h.inject_post();
    const resp2 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp2.status_code);
}

test "sidecar: connect then disconnect before READY → 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    // Connect sidecar but don't send READY.
    h.sidecar.connect();
    h.run_until(TestHarness.sidecar_accepted);
    // Disconnect before READY.
    h.sidecar.disconnect();
    h.run_server_until(TestHarness.bus_closed);

    try std.testing.expect(!h.server.sidecar_any_ready());

    h.connect_http();
    h.inject_post();
    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

test "sidecar: response timeout → terminate → 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_http();
    h.inject_post();

    // Tick server (not sidecar) until the pipeline is pending.
    h.run_server_until(TestHarness.handler_pending);

    // Tick past the 500-tick timeout WITHOUT ticking the sidecar.
    // The sidecar is "stuck" — never responds to the CALL.
    h.run_server_until(TestHarness.sidecar_disconnected);

    // The original request's connection was closed during timeout.
    // Reconnect and verify 503 (sidecar is disconnected).
    h.prepare_next_request();
    h.inject_post();
    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

test "sidecar: disconnect during render → fallback HTML" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_http();
    h.inject_post();

    // Tick until the render CALL is processed by the sidecar (4 calls:
    // route + prefetch + handle + render). The render RESULT is pending
    // (built but not yet injected).
    h.run_until(TestHarness.render_call_done);

    // The render RESULT is pending. Don't tick the sidecar — the
    // server is waiting for the render response. Disconnect now.
    // Writes are already committed (handle was sync).
    // The server must NOT retry (would duplicate writes). It sends
    // fallback HTML instead.
    h.sidecar.disconnect();
    h.run_server_until(TestHarness.sidecar_disconnected);

    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    // Fallback response is 200 (operation succeeded, render degraded).
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    // Body contains the fallback text, not the sidecar's "<div>sim</div>".
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Operation completed") != null);
}

test "sidecar: protocol violation → terminate → 503" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_http();
    h.inject_post();

    // Tick server (not sidecar) until CALL is in-flight.
    h.run_server_until(TestHarness.handler_pending);

    // Inject a malformed RESULT with wrong request_id.
    var result_payload: [6]u8 = undefined;
    result_payload[0] = @intFromEnum(protocol.CallTag.result);
    std.mem.writeInt(u32, result_payload[1..5], 0xDEADBEEF, .big); // wrong id
    result_payload[5] = @intFromEnum(protocol.ResultFlag.success);
    var wire_buf: [14]u8 = undefined;
    const wire = build_wire_frame(&wire_buf, &result_payload);
    h.io.inject_bytes(TestHarness.sidecar_slot, wire);

    // Tick to deliver the bad frame. Server detects violation → terminate.
    h.run_server_until(TestHarness.sidecar_disconnected);

    // Next request gets 503.
    h.prepare_next_request();
    h.inject_post();
    const resp = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 503), resp.status_code);
}

// =====================================================================
// Hot standby tests — two sidecars, failover without 503
// =====================================================================

test "sidecar: hot standby — kill active, standby takes over" {
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    // Connect both sidecars — both slots become ready.
    h.connect_sidecar();
    h.connect_standby();
    try std.testing.expect(h.server.sidecar_any_ready());
    try std.testing.expect(h.server.sidecar_connections_ready[0]);
    try std.testing.expect(h.server.sidecar_connections_ready[1]);

    // First request succeeds via slot 0.
    h.connect_http();
    h.inject_post();
    const resp1 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resp1.status_code);

    // Kill sidecar on slot 0. Slot 0 disabled, slot 1 still ready.
    h.sidecar.disconnect();
    h.run_server_until(TestHarness.slot_1_ready);

    // Slot 0 disabled, slot 1 still ready.
    try std.testing.expect(h.server.sidecar_any_ready());
    try std.testing.expect(!h.server.sidecar_connections_ready[0]);
    try std.testing.expect(h.server.sidecar_connections_ready[1]);

    // Next request succeeds via slot 1 — no 503.
    h.prepare_next_request();
    h.inject_post();
    const resp2 = h.wait_response() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resp2.status_code);
}

// =====================================================================
// Concurrent dispatch tests
// =====================================================================

test "concurrent: two requests to two slots, both succeed" {
    // Two HTTP clients, two sidecars. Each request routes to a different
    // slot. Both complete independently. Exercises round-robin dispatch.
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_standby();

    // Two HTTP connections, two requests.
    h.connect_http();
    h.connect_http_b();
    h.inject_post();
    h.inject_post_b();

    // Both should complete — dispatched to slot 0 and slot 1.
    const resps = h.wait_both_responses() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resps.a.status_code);
    try std.testing.expectEqual(@as(u16, 200), resps.b.status_code);
}

test "concurrent: slot recovery during concurrent dispatch" {
    // Two requests in-flight. Kill one sidecar. Its request gets
    // recovered (pipeline reset). The other completes normally.
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_standby();

    h.connect_http();
    h.connect_http_b();
    h.inject_post();
    h.inject_post_b();

    // Wait until both sidecars have received at least one CALL.
    h.run_until(TestHarness.both_sidecars_called);

    // Kill sidecar on slot 0. Its request is recovered.
    h.sidecar.disconnect();

    // Wait for both responses. Slot 1's request completes normally (200).
    // Slot 0's request was reset — HTTP connection retries next tick,
    // routes to slot 1 (the only ready slot) and completes.
    const resps = h.wait_both_responses() orelse return error.TestUnexpectedResult;

    // At least one must be 200 (the undisturbed slot).
    const any_200 = resps.a.status_code == 200 or resps.b.status_code == 200;
    try std.testing.expect(any_200);
}

test "concurrent: handle_lock serializes writes" {
    // Verify that at most one slot is in .handle at any point.
    // Enforced by handle_lock + invariants (which run every tick via
    // defer). If two slots enter .handle simultaneously, the invariant
    // crashes the test. Reaching the end without crash = serialization works.
    var h: TestHarness = undefined;
    try h.init();
    defer h.deinit();

    h.connect_sidecar();
    h.connect_standby();

    h.connect_http();
    h.connect_http_b();
    h.inject_post();
    h.inject_post_b();

    const resps = h.wait_both_responses() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 200), resps.a.status_code);
    try std.testing.expectEqual(@as(u16, 200), resps.b.status_code);

    // handle_lock must be free after all requests complete.
    try std.testing.expectEqual(@as(?u8, null), h.server.handle_lock);
}
