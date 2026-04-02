//! Sidecar simulation tests — full-stack tests with deterministic IO.
//!
//! Exercises the complete sidecar pipeline (route → prefetch → handle →
//! render) through the real Server + SM + MessageBus + Connection stack.
//! SimSidecar acts as the sidecar process: parses CALL frames, builds
//! RESULT frames, injects via SimIO. Hardcoded responses — tests the
//! framework pipeline, not handler logic.
//!
//! This binary is compiled with sidecar_enabled = true (via build_options).
//! The root module re-exports build_options so app.zig reads it.

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
const StateMachine = App.StateMachineWith(Storage, Handlers);

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
        };
    }

    /// Connect the sidecar to the server's sidecar bus.
    /// Just marks the SimIO client as connected. The caller must run
    /// ticks for the accept to complete, then call inject_ready().
    fn connect(self: *SimSidecar) void {
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
        const copy_len = @min(new_data.len, space);
        @memcpy(self.frame_buf[self.frame_len..][0..copy_len], new_data[0..copy_len]);
        self.frame_len += @intCast(copy_len);
        self.recv_pos += @intCast(copy_len);

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
            pos += self.build_route_result(result_payload[pos..], args);
        } else if (std.mem.eql(u8, name, "prefetch")) {
            // Empty result — just success flag (already written).
        } else if (std.mem.eql(u8, name, "handle")) {
            pos += build_handle_result(result_payload[pos..]);
        } else if (std.mem.eql(u8, name, "render")) {
            const html = "<div>sim</div>";
            @memcpy(result_payload[pos..][0..html.len], html);
            pos += html.len;
        } else {
            // Unknown function — still return success with empty data.
        }

        // Wrap in CRC wire frame and queue for injection.
        self.response_len = @intCast(build_wire_frame_into(&self.response_buf, result_payload[0..pos]));
        self.response_pending = true;
    }

    /// Build route RESULT data: [operation: u8][id: 16 bytes LE][body]
    /// Parses the route args to extract method + path, maps to an operation.
    fn build_route_result(_: *SimSidecar, buf: []u8, args: []const u8) usize {
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

        // Simple path → operation mapping for sim.
        const op: message.Operation = if (std.mem.eql(u8, path, "/products"))
            .create_product
        else
            .list_products;

        var pos: usize = 0;
        buf[pos] = @intFromEnum(op);
        pos += 1;
        // id: 16 bytes LE (zero UUID).
        @memset(buf[pos..][0..16], 0);
        pos += 16;
        // Copy body if present.
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

/// Build a CRC wire frame into a caller-provided buffer.
/// Returns the total frame length (8 + payload.len).
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

/// Build a CRC wire frame — returns a slice into the provided buffer.
fn build_wire_frame(buf: []u8, payload: []const u8) []const u8 {
    const total = build_wire_frame_into(buf, payload);
    return buf[0..total];
}

// =====================================================================
// Test infrastructure
// =====================================================================

fn run_ticks(server: *Server, sidecar: *SimSidecar, io: *SimIO, n: usize) void {
    for (0..n) |_| {
        server.tick();
        sidecar.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
}

fn run_until_response(server: *Server, sidecar: *SimSidecar, io: *SimIO, client_index: usize, max_ticks: usize) ?SimIO.HttpResponse {
    for (0..max_ticks) |_| {
        server.tick();
        sidecar.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
        if (io.read_response(client_index)) |resp| return resp;
    }
    return null;
}

/// Write "Cookie: <name>=<signed_value>\r\n" into buf.
fn write_cookie_header(buf: []u8) usize {
    const prefix = "Cookie: " ++ auth.cookie_name ++ "=";
    @memcpy(buf[0..prefix.len], prefix);
    var cookie_buf: [auth.cookie_value_max]u8 = undefined;
    const cookie_val = auth.sign_cookie(&cookie_buf, 1, .authenticated, test_key);
    @memcpy(buf[prefix.len..][0..cookie_val.len], cookie_val);
    const crlf = "\r\n";
    @memcpy(buf[prefix.len + cookie_val.len ..][0..crlf.len], crlf);
    return prefix.len + cookie_val.len + crlf.len;
}

// =====================================================================
// Tests
// =====================================================================

test {
    std.testing.log_level = .err;
}

test "sidecar: basic request-response" {
    const allocator = std.testing.allocator;
    var sim_io = SimIO.init(12345);
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    const http_listen_fd: SimIO.fd_t = 1;
    const sidecar_listen_fd: SimIO.fd_t = 2;

    var sm = StateMachine.init(&storage, .{}, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = try Server.init(allocator, &sim_io, &sm, http_listen_fd, time_sim.time(), null);
    defer server.deinit(allocator);

    // Wire sidecar bus. null path = sim mode — set listen_fd directly.
    try server.wire_sidecar(allocator, null);
    server.sidecar_bus.listen_fd = sidecar_listen_fd;

    // Connect sidecar — accept, then READY handshake.
    var sidecar = SimSidecar.init(&sim_io, 0, sidecar_listen_fd);
    defer {
        // Disconnect the sidecar client and drain until the bus
        // connection closes. The 3-phase terminate needs IO
        // completions to drain (recv returns -1 → terminate_join
        // → terminate_close).
        if (sim_io.clients[0].connected) {
            sidecar.disconnect();
        }
        for (0..50) |_| {
            server.tick();
            sim_io.run_for_ns(10 * std.time.ns_per_ms);
        }
        server.sidecar_bus.deinit(allocator);
    }
    sidecar.connect();
    run_ticks(&server, &sidecar, &sim_io, 10); // accept completes
    sidecar.inject_ready();
    run_ticks(&server, &sidecar, &sim_io, 10); // READY delivered

    // Verify sidecar is connected.
    try std.testing.expect(server.sidecar_connected);

    // Connect HTTP client and inject request.
    sim_io.connect_client(1, http_listen_fd);
    run_ticks(&server, &sidecar, &sim_io, 5);

    // Inject a POST to /products (will be routed as create_product by SimSidecar).
    const body = "{\"id\":\"aabbccdd11223344aabbccdd11223344\",\"name\":\"Widget\",\"price_cents\":100}";
    sim_io.inject_post(1, "/products", body);

    // Run until we get an HTTP response.
    const resp = run_until_response(&server, &sidecar, &sim_io, 1, 500) orelse
        return error.TestUnexpectedResult;

    // Sidecar pipeline completed — we got a response.
    // The status code depends on whether the sidecar render returned valid HTML.
    // With our hardcoded "<div>sim</div>", the server should return 200.
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
}
