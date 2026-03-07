const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const http = @import("http.zig");
const state_machine = @import("state_machine.zig");
const MemoryStorage = state_machine.MemoryStorage;
const StateMachine = state_machine.StateMachineType(MemoryStorage);
const ServerType = @import("server.zig").ServerType;
const ConnectionType = @import("connection.zig").ConnectionType;
const marks = @import("marks.zig");

/// Simulated IO that replaces the real epoll-based IO for deterministic testing.
/// All operations complete synchronously during `run_for_ns`. A seeded PRNG
/// controls ordering and fault injection.
pub const SimIO = struct {
    pub const fd_t = i32;

    pub const Completion = struct {
        fd: fd_t = 0,
        operation: Op = .none,
        context: *anyopaque = undefined,
        callback: *const fn (*anyopaque, i32) void = undefined,
        buffer: ?[]u8 = null,
        buffer_const: ?[]const u8 = null,

        const Op = enum {
            none,
            accept,
            recv,
            send,
        };
    };

    const max_clients = 8;
    const max_pending = 64;
    const client_buf_size = (http.recv_buf_max + http.send_buf_max) * 2;

    /// Pending completion queue.
    pending: [max_pending]PendingOp,
    pending_count: u32,

    /// Simulated client connections.
    clients: [max_clients]SimClient,
    next_fd: fd_t,

    /// PRNG for deterministic behavior.
    prng_state: u64,

    /// Fault injection probabilities (0-100). Each operation rolls the PRNG
    /// and fails with -1 if the roll is below the threshold. Zero means no
    /// faults. Same seed → same faults → fully reproducible.
    accept_fault_probability: u8,
    recv_fault_probability: u8,
    send_fault_probability: u8,

    const PendingOp = struct {
        completion: *Completion,
        active: bool,
    };

    const SimClient = struct {
        connected: bool,
        accepted: bool,
        fd: fd_t,
        // Data injected by the test, to be "received" by the server.
        send_buf: [client_buf_size]u8,
        send_len: u32,
        send_pos: u32,
        // Data sent by the server, readable by the test.
        recv_buf: [client_buf_size]u8,
        recv_len: u32,

        fn init() SimClient {
            return .{
                .connected = false,
                .accepted = false,
                .fd = 0,
                .send_buf = undefined,
                .send_len = 0,
                .send_pos = 0,
                .recv_buf = undefined,
                .recv_len = 0,
            };
        }
    };

    pub fn init(seed: u64) SimIO {
        var sim = SimIO{
            .pending = undefined,
            .pending_count = 0,
            .clients = undefined,
            .next_fd = 100, // Start at 100 to distinguish from listen fd.
            .prng_state = seed,
            .accept_fault_probability = 0,
            .recv_fault_probability = 0,
            .send_fault_probability = 0,
        };
        for (&sim.pending) |*p| {
            p.* = .{ .completion = undefined, .active = false };
        }
        for (&sim.clients) |*c| {
            c.* = SimClient.init();
        }
        return sim;
    }

    pub fn deinit(_: *SimIO) void {}

    // --- Test control API ---

    /// Simulate a client connecting.
    pub fn connect_client(self: *SimIO, client_index: usize) void {
        assert(client_index < max_clients);
        assert(!self.clients[client_index].connected);
        self.clients[client_index].connected = true;
        self.clients[client_index].fd = self.next_fd;
        self.next_fd += 1;
        self.clients[client_index].send_len = 0;
        self.clients[client_index].send_pos = 0;
        self.clients[client_index].recv_len = 0;
    }

    /// Simulate a client disconnecting. The next recv/send on this
    /// fd will return -1, triggering connection close on the server.
    pub fn disconnect_client(self: *SimIO, client_index: usize) void {
        assert(client_index < max_clients);
        assert(self.clients[client_index].connected);
        self.clients[client_index].connected = false;
    }

    /// Inject raw bytes from a simulated client.
    pub fn inject_bytes(self: *SimIO, client_index: usize, data: []const u8) void {
        assert(client_index < max_clients);
        const client = &self.clients[client_index];
        assert(client.connected);
        assert(client.send_len + data.len <= client_buf_size);
        @memcpy(client.send_buf[client.send_len..][0..data.len], data);
        client.send_len += @intCast(data.len);
    }

    /// Inject an HTTP POST request with a body.
    pub fn inject_post(self: *SimIO, client_index: usize, path: []const u8, body: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "POST ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\nContent-Length: ";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        var cl_buf: [10]u8 = undefined;
        const cl_str = format_u32(&cl_buf, @intCast(body.len));
        @memcpy(buf[pos..][0..cl_str.len], cl_str);
        pos += cl_str.len;

        const end = "\r\n\r\n";
        @memcpy(buf[pos..][0..end.len], end);
        pos += end.len;
        @memcpy(buf[pos..][0..body.len], body);
        pos += body.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP PUT request to a path with a body.
    pub fn inject_put(self: *SimIO, client_index: usize, path: []const u8, body: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "PUT ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\nContent-Length: ";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        var cl_buf: [10]u8 = undefined;
        const cl_str = format_u32(&cl_buf, @intCast(body.len));
        @memcpy(buf[pos..][0..cl_str.len], cl_str);
        pos += cl_str.len;

        const end = "\r\n\r\n";
        @memcpy(buf[pos..][0..end.len], end);
        pos += end.len;
        @memcpy(buf[pos..][0..body.len], body);
        pos += body.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP GET to a path.
    pub fn inject_get(self: *SimIO, client_index: usize, path: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "GET ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\n\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP DELETE to a path.
    pub fn inject_delete(self: *SimIO, client_index: usize, path: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "DELETE ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\n\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Parsed HTTP response for test verification.
    pub const HttpResponse = struct {
        status_code: u16,
        body: []const u8,
    };

    /// Read the HTTP response received by a simulated client.
    pub fn read_response(self: *SimIO, client_index: usize) ?HttpResponse {
        assert(client_index < max_clients);
        const client = &self.clients[client_index];
        if (client.recv_len == 0) return null;
        const data = client.recv_buf[0..client.recv_len];

        // Find end of headers.
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;

        // Parse status code from "HTTP/1.1 NNN ...".
        if (data.len < 12) return null;
        if (!std.mem.startsWith(u8, data, "HTTP/1.1 ")) return null;
        const status_code = std.fmt.parseInt(u16, data[9..12], 10) catch return null;

        // Find Content-Length in response headers.
        const headers = data[0 .. header_end + 2];
        const cl_marker = "Content-Length: ";
        const cl_pos = std.mem.indexOf(u8, headers, cl_marker) orelse return null;
        const cl_start = cl_pos + cl_marker.len;
        const cl_end = std.mem.indexOf(u8, headers[cl_start..], "\r\n") orelse return null;
        const content_length = std.fmt.parseInt(u32, headers[cl_start..][0..cl_end], 10) catch return null;

        const body_start = header_end + 4;
        if (data.len < body_start + content_length) return null;

        const body = data[body_start..][0..content_length];

        return .{
            .status_code = status_code,
            .body = body,
        };
    }

    /// Consume the first HTTP response from the client's recv buffer,
    /// shifting any remaining bytes (from pipelined responses) forward.
    pub fn clear_response(self: *SimIO, client_index: usize) void {
        assert(client_index < max_clients);
        const client = &self.clients[client_index];
        if (client.recv_len == 0) return;

        const data = client.recv_buf[0..client.recv_len];
        // Find the end of the first response (headers + body).
        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse {
            client.recv_len = 0;
            return;
        };
        const headers = data[0 .. header_end + 2];
        const cl_marker = "Content-Length: ";
        const cl_pos = std.mem.indexOf(u8, headers, cl_marker) orelse {
            client.recv_len = 0;
            return;
        };
        const cl_start = cl_pos + cl_marker.len;
        const cl_end = std.mem.indexOf(u8, headers[cl_start..], "\r\n") orelse {
            client.recv_len = 0;
            return;
        };
        const content_length = std.fmt.parseInt(u32, headers[cl_start..][0..cl_end], 10) catch {
            client.recv_len = 0;
            return;
        };
        const response_end: u32 = @intCast(header_end + 4 + content_length);
        if (response_end >= client.recv_len) {
            client.recv_len = 0;
            return;
        }
        // Shift remaining bytes forward.
        const remaining: u32 = client.recv_len - response_end;
        std.mem.copyForwards(u8, client.recv_buf[0..remaining], client.recv_buf[response_end..client.recv_len]);
        client.recv_len = remaining;
    }

    // --- IO interface (called by server/connection code) ---

    pub fn accept(self: *SimIO, _: fd_t, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        completion.* = .{
            .fd = 0,
            .operation = .accept,
            .context = context,
            .callback = callback,
        };
        self.enqueue(completion);
    }

    pub fn recv(self: *SimIO, fd: fd_t, buffer: []u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        assert(buffer.len > 0);
        completion.* = .{
            .fd = fd,
            .operation = .recv,
            .context = context,
            .callback = callback,
            .buffer = buffer,
        };
        self.enqueue(completion);
    }

    pub fn send(self: *SimIO, fd: fd_t, buffer: []const u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        assert(buffer.len > 0);
        completion.* = .{
            .fd = fd,
            .operation = .send,
            .context = context,
            .callback = callback,
            .buffer_const = buffer,
        };
        self.enqueue(completion);
    }

    pub fn close(self: *SimIO, fd: fd_t) void {
        // Cancel any pending completions for this fd.
        // Mirrors real IO: closing an fd cancels all pending operations on it.
        for (&self.pending) |*p| {
            if (p.active and p.completion.fd == fd) {
                p.completion.operation = .none;
                p.active = false;
                self.pending_count -= 1;
            }
        }
    }

    /// Process all pending completions. This is the simulation's equivalent
    /// of epoll_wait — it completes all pending operations synchronously.
    /// Only processes completions that were pending at the start of this call,
    /// not ones enqueued during processing (those wait for the next cycle).
    pub fn run_for_ns(self: *SimIO, _: u64) void {
        // Snapshot which completions to process this cycle.
        var to_process: [max_pending]*Completion = undefined;
        var count: u32 = 0;
        for (&self.pending) |*p| {
            if (!p.active) continue;
            to_process[count] = p.completion;
            p.active = false;
            count += 1;
        }
        self.pending_count -= count;

        // Process the snapshot. New enqueues during processing go to the
        // next cycle, preventing infinite loops.
        for (to_process[0..count]) |completion| {
            self.complete(completion);
        }
    }

    fn enqueue(self: *SimIO, completion: *Completion) void {
        // Deduplicate: if this completion is already pending, skip.
        // Mirrors real IO — you can't double-submit the same completion.
        for (&self.pending) |*p| {
            if (p.active and p.completion == completion) return;
        }
        for (&self.pending) |*p| {
            if (!p.active) {
                p.* = .{ .completion = completion, .active = true };
                self.pending_count += 1;
                return;
            }
        }
        unreachable; // Pending queue full.
    }

    fn complete(self: *SimIO, completion: *Completion) void {
        const op = completion.operation;
        assert(op != .none);
        completion.operation = .none;

        switch (op) {
            .accept => {
                if (self.fault(.accept)) {
                    completion.callback(completion.context, -1);
                    return;
                }
                // Find a connected client that hasn't been accepted yet.
                for (&self.clients) |*client| {
                    if (client.connected and !client.accepted) {
                        const fd = client.fd;
                        client.accepted = true;
                        completion.callback(completion.context, fd);
                        return;
                    }
                }
                // No clients waiting — re-enqueue for later.
                completion.operation = .accept;
                self.enqueue(completion);
            },
            .recv => {
                if (self.fault(.recv)) {
                    completion.callback(completion.context, -1);
                    return;
                }
                // Find the client by fd and deliver their injected data.
                for (&self.clients) |*client| {
                    if (client.connected and client.fd == completion.fd) {
                        const remaining = client.send_len - client.send_pos;
                        if (remaining == 0) {
                            // No data available — don't call back yet.
                            // Re-enqueue for later.
                            completion.operation = .recv;
                            self.enqueue(completion);
                            return;
                        }
                        const buf = completion.buffer.?;
                        const max_n = @min(remaining, @as(u32, @intCast(buf.len)));
                        // Partial delivery: PRNG picks 1..max_n bytes.
                        // Simulates TCP fragmentation / partial reads.
                        const n = 1 + @as(u32, @intCast(self.prng_next() % max_n));
                        @memcpy(buf[0..n], client.send_buf[client.send_pos..][0..n]);
                        client.send_pos += n;
                        completion.callback(completion.context, @intCast(n));
                        return;
                    }
                }
                // Unknown fd — connection error.
                completion.callback(completion.context, -1);
            },
            .send => {
                if (self.fault(.send)) {
                    completion.callback(completion.context, -1);
                    return;
                }
                // Find the client by fd and capture the sent data.
                for (&self.clients) |*client| {
                    if (client.connected and client.fd == completion.fd) {
                        const buf = completion.buffer_const.?;
                        const total: u32 = @intCast(buf.len);
                        // Partial send: PRNG picks 1..total bytes.
                        // Simulates partial TCP writes.
                        const n = 1 + @as(u32, @intCast(self.prng_next() % total));
                        assert(client.recv_len + n <= client_buf_size);
                        @memcpy(client.recv_buf[client.recv_len..][0..n], buf[0..n]);
                        client.recv_len += n;
                        completion.callback(completion.context, @intCast(n));
                        return;
                    }
                }
                completion.callback(completion.context, -1);
            },
            .none => unreachable,
        }
    }

    /// Roll the PRNG against the fault probability for the given operation.
    /// Returns true if this operation should fail.
    fn fault(self: *SimIO, op: Completion.Op) bool {
        const probability = switch (op) {
            .accept => self.accept_fault_probability,
            .recv => self.recv_fault_probability,
            .send => self.send_fault_probability,
            .none => unreachable,
        };
        if (probability == 0) return false;
        return self.prng_next() % 100 < probability;
    }

    fn prng_next(self: *SimIO) u64 {
        return splitmix64(&self.prng_state);
    }
};

/// SplitMix64 — same as TigerBeetle's PRNG seed expansion.
/// Standalone so both SimIO and fuzzer tests can use it.
fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Format a u32 as a decimal string into buf. Returns the written slice.
fn format_u32(buf: *[10]u8, val: u32) []const u8 {
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var pos: usize = 10;
    while (v > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[pos..10];
}

const Server = ServerType(SimIO, MemoryStorage);

/// Run ticks until the server processes pending work.
fn run_ticks(server: *Server, io: *SimIO, n: usize) void {
    for (0..n) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
}

/// Run ticks until an HTTP response arrives for the given client, or return
/// null after max_ticks. Handles variable tick counts from partial delivery.
fn run_until_response(server: *Server, io: *SimIO, client_index: usize, max_ticks: usize) ?SimIO.HttpResponse {
    for (0..max_ticks) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
        if (io.read_response(client_index)) |resp| return resp;
    }
    return null;
}

/// Helper: check that a JSON response body contains a substring.
fn json_contains(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

// =====================================================================
// Product CRUD integration tests
// =====================================================================

const test_uuid1 = "aabbccdd11223344aabbccdd11223344";
const test_uuid2 = "aabbccdd11223344aabbccdd11223345";

test "product CRUD — create, get, update, delete" {
    var sim_io = SimIO.init(0xb001);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // CREATE
    const create_body = "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"description\":\"A cool widget\",\"price_cents\":1999,\"inventory\":50,\"active\":true}";
    sim_io.inject_post(0, "/products", create_body);
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    try std.testing.expect(json_contains(create_resp.body, "\"id\":\"" ++ test_uuid1 ++ "\""));
    try std.testing.expect(json_contains(create_resp.body, "\"name\":\"Widget\""));
    try std.testing.expect(json_contains(create_resp.body, "\"price_cents\":1999"));
    sim_io.clear_response(0);

    // GET
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Widget\""));
    sim_io.clear_response(0);

    // UPDATE
    const update_body =
        \\{"name":"Super Widget","description":"An even cooler widget","price_cents":2999,"inventory":100,"active":true}
    ;
    sim_io.inject_put(0, "/products/" ++ test_uuid1, update_body);
    const update_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(update_resp.status_code, 200);
    try std.testing.expect(json_contains(update_resp.body, "\"name\":\"Super Widget\""));
    try std.testing.expect(json_contains(update_resp.body, "\"price_cents\":2999"));
    sim_io.clear_response(0);

    // GET after update
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const get2_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get2_resp.status_code, 200);
    try std.testing.expect(json_contains(get2_resp.body, "\"name\":\"Super Widget\""));
    sim_io.clear_response(0);

    // DELETE
    sim_io.inject_delete(0, "/products/" ++ test_uuid1);
    const del_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(del_resp.status_code, 200);
    sim_io.clear_response(0);

    // GET after delete — should be 404
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const gone_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(gone_resp.status_code, 404);
}

test "product list — empty then populated" {
    var sim_io = SimIO.init(0xb002);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // List when empty.
    sim_io.inject_get(0, "/products");
    const empty_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(empty_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, empty_resp.body, "[]");
    sim_io.clear_response(0);

    // Create two products.
    sim_io.inject_post(0, "/products",
        \\{"id":"00000000000000000000000000000001","name":"A","price_cents":100}
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    sim_io.inject_post(0, "/products",
        \\{"id":"00000000000000000000000000000002","name":"B","price_cents":200}
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // List should contain both.
    sim_io.inject_get(0, "/products");
    const list_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(list_resp.status_code, 200);
    try std.testing.expect(json_contains(list_resp.body, "\"name\":\"A\""));
    try std.testing.expect(json_contains(list_resp.body, "\"name\":\"B\""));
}

test "product get missing returns 404" {
    var sim_io = SimIO.init(0xb003);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_get(0, "/products/00000000000000000000000000000999");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 404);
}

test "product delete missing returns 404" {
    var sim_io = SimIO.init(0xb004);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_delete(0, "/products/00000000000000000000000000000999");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 404);
}

test "product client-provided IDs across creates" {
    var sim_io = SimIO.init(0xb005);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"First\"}"
    );
    const r1 = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(json_contains(r1.body, "\"id\":\"" ++ test_uuid1 ++ "\""));
    sim_io.clear_response(0);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid2 ++ "\",\"name\":\"Second\"}"
    );
    const r2 = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(json_contains(r2.body, "\"id\":\"" ++ test_uuid2 ++ "\""));
}

test "deterministic replay — same seed same result" {
    var results: [2]u16 = undefined;

    for (0..2) |run| {
        var sim_io = SimIO.init(12345);
        var storage = try MemoryStorage.init(std.testing.allocator);
        defer storage.deinit(std.testing.allocator);
        var sm = StateMachine.init(&storage);
        var server = Server.init(&sim_io, &sm, 1);

        sim_io.connect_client(0);
        sim_io.inject_post(0, "/products",
            "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
        );
        const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(create_resp.status_code, 200);
        sim_io.clear_response(0);

        sim_io.inject_get(0, "/products/" ++ test_uuid1);
        const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        results[run] = get_resp.status_code;
    }

    try std.testing.expectEqual(results[0], results[1]);
    try std.testing.expectEqual(results[0], @as(u16, 200));
}

// =====================================================================
// Infrastructure tests — connection plumbing, pipelining, disconnects
// =====================================================================

test "pipelining — back-to-back requests on one connection" {
    var sim_io = SimIO.init(0x1234);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Inject CREATE + GET back-to-back (pipelined).
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"PipeWidget\",\"price_cents\":100}"
    );
    sim_io.inject_get(0, "/products/" ++ test_uuid1);

    // First response: CREATE 200.
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    sim_io.clear_response(0);

    // Second response: GET 200 with the product.
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"PipeWidget\""));
}

test "connection drops and reconnects — state machine survives" {
    var sim_io = SimIO.init(0xdead);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product before the drop.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Survivor\",\"price_cents\":100}"
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    sim_io.clear_response(0);

    // Drop the connection.
    sim_io.disconnect_client(0);
    run_ticks(&server, &sim_io, 50);

    // Reconnect on a different client slot.
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // The state machine should still have the product.
    sim_io.inject_get(1, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 1, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Survivor\""));
}

test "timeout — partial request triggers close" {
    var sim_io = SimIO.init(0xface);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Inject a partial request (no header terminator).
    sim_io.inject_bytes(0, "GET /products HTTP/1.1\r\n");
    run_ticks(&server, &sim_io, 10);

    // Connection should still be alive before timeout.
    var found_receiving = false;
    for (&server.connections, server.connections_busy) |*conn, busy| {
        if (busy and conn.state == .receiving) {
            found_receiving = true;
            break;
        }
    }
    try std.testing.expect(found_receiving);

    // Disconnect the client so SimIO won't try to deliver more data,
    // then tick past the timeout.
    sim_io.disconnect_client(0);

    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
    }

    // After timeout, the receiving connection should be freed.
    var any_active = false;
    for (&server.connections, server.connections_busy) |*conn, busy| {
        if (busy and conn.state != .free and conn.state != .accepting) {
            any_active = true;
            break;
        }
    }
    try std.testing.expect(!any_active);
}

// =====================================================================
// Coverage mark tests
// =====================================================================

test "mark: disconnect triggers recv peer closed" {
    var sim_io = SimIO.init(0xa001);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    const mark = marks.check("recv: peer closed");
    sim_io.disconnect_client(0);
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: send fault triggers send error" {
    var sim_io = SimIO.init(0xa002);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product so there's something to GET.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"TestProduct\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Enable 100% send faults, then GET. The response send will fail.
    sim_io.send_fault_probability = 100;
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const mark = marks.check("send: error");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: idle connection triggers timeout" {
    var sim_io = SimIO.init(0xa003);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Send a partial request so connection stays in receiving state.
    sim_io.inject_bytes(0, "GET /products HTTP/1.1\r\n");
    run_ticks(&server, &sim_io, 10);

    // Disconnect so SimIO won't deliver more data, then tick past timeout.
    sim_io.disconnect_client(0);

    const mark = marks.check("connection timed out");
    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
    }
    try mark.expect_hit();
}

test "mark: garbage bytes trigger invalid HTTP" {
    var sim_io = SimIO.init(0xa004);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    const mark = marks.check("invalid HTTP");
    sim_io.inject_bytes(0, "GARBAGE\x00\x01\x02\r\n\r\n");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: unknown route triggers unmapped request" {
    var sim_io = SimIO.init(0xa005);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // GET / doesn't match any known route — triggers unmapped.
    const mark = marks.check("unmapped request");
    sim_io.inject_bytes(0, "GET / HTTP/1.1\r\n\r\n");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: accept failure logs warning" {
    var sim_io = SimIO.init(0xa007);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    // 100% accept fault — every accept attempt fails.
    sim_io.accept_fault_probability = 100;
    sim_io.connect_client(0);
    const mark = marks.check("accept failed");
    run_ticks(&server, &sim_io, 10);
    try mark.expect_hit();
}

// =====================================================================
// Storage fault injection tests
// =====================================================================

test "storage busy fault — prefetch retries next tick then succeeds" {
    var sim_io = SimIO.init(0xc001);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    // Create a product first (no faults).
    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Enable 100% busy faults. GET will be retried each tick.
    storage.busy_fault_probability = 100;
    storage.prng_state = 0xc001;
    sim_io.inject_get(0, "/products/" ++ test_uuid1);

    // Tick a few times with busy faults — connection stays .ready.
    const mark = marks.check("storage: busy fault injected");
    run_ticks(&server, &sim_io, 20);
    try mark.expect_hit();

    // Verify no response yet (still busy-looping).
    try std.testing.expect(sim_io.read_response(0) == null);

    // Disable busy faults — next tick should succeed.
    storage.busy_fault_probability = 0;
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expect(json_contains(resp.body, "\"name\":\"Widget\""));
}

test "product get_inventory — returns inventory count" {
    var sim_io = SimIO.init(0xb006);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product with inventory.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100,\"inventory\":42}"
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    sim_io.clear_response(0);

    // GET inventory sub-resource.
    sim_io.inject_get(0, "/products/" ++ test_uuid1 ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(inv_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, inv_resp.body, "{\"inventory\":42}");
    sim_io.clear_response(0);

    // GET inventory for missing product — 404.
    sim_io.inject_get(0, "/products/00000000000000000000000000000999/inventory");
    const missing_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(missing_resp.status_code, 404);
}

// =====================================================================
// Collection tests — multi-read prefetch stress
// =====================================================================

const test_col_uuid1 = "cc000000000000000000000000000001";
const test_col_uuid2 = "cc000000000000000000000000000002";

test "collection CRUD — create, get, list, delete" {
    var sim_io = SimIO.init(0xd001);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create collection.
    sim_io.inject_post(0, "/collections",
        "{\"id\":\"" ++ test_col_uuid1 ++ "\",\"name\":\"Summer Sale\"}"
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    try std.testing.expect(json_contains(create_resp.body, "\"name\":\"Summer Sale\""));
    try std.testing.expect(json_contains(create_resp.body, "\"id\":\"" ++ test_col_uuid1 ++ "\""));
    sim_io.clear_response(0);

    // Get collection (no products yet).
    sim_io.inject_get(0, "/collections/" ++ test_col_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Summer Sale\""));
    try std.testing.expect(json_contains(get_resp.body, "\"products\":[]"));
    sim_io.clear_response(0);

    // List collections.
    sim_io.inject_get(0, "/collections");
    const list_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(list_resp.status_code, 200);
    try std.testing.expect(json_contains(list_resp.body, "\"name\":\"Summer Sale\""));
    sim_io.clear_response(0);

    // Delete collection.
    sim_io.inject_delete(0, "/collections/" ++ test_col_uuid1);
    const del_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(del_resp.status_code, 200);
    sim_io.clear_response(0);

    // Get after delete — 404.
    sim_io.inject_get(0, "/collections/" ++ test_col_uuid1);
    const gone_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(gone_resp.status_code, 404);
}

test "collection with products — multi-read prefetch" {
    var sim_io = SimIO.init(0xd002);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create two products.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid2 ++ "\",\"name\":\"Gadget\",\"price_cents\":200}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Create a collection.
    sim_io.inject_post(0, "/collections",
        "{\"id\":\"" ++ test_col_uuid1 ++ "\",\"name\":\"Summer Sale\"}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Add both products to the collection.
    sim_io.inject_bytes(0, "POST /collections/" ++ test_col_uuid1 ++ "/products/" ++ test_uuid1 ++ " HTTP/1.1\r\n\r\n");
    const add1 = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(add1.status_code, 200);
    sim_io.clear_response(0);

    sim_io.inject_bytes(0, "POST /collections/" ++ test_col_uuid1 ++ "/products/" ++ test_uuid2 ++ " HTTP/1.1\r\n\r\n");
    const add2 = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(add2.status_code, 200);
    sim_io.clear_response(0);

    // GET collection — should return collection + both products.
    // This is the multi-read prefetch: collection entity + product list.
    sim_io.inject_get(0, "/collections/" ++ test_col_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Summer Sale\""));
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Widget\""));
    try std.testing.expect(json_contains(get_resp.body, "\"name\":\"Gadget\""));
}

test "add member — missing collection returns 404" {
    var sim_io = SimIO.init(0xd003);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product but no collection.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\"}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Add to non-existent collection — 404.
    sim_io.inject_bytes(0, "POST /collections/" ++ test_col_uuid1 ++ "/products/" ++ test_uuid1 ++ " HTTP/1.1\r\n\r\n");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 404);
}

test "add member — missing product returns 404" {
    var sim_io = SimIO.init(0xd004);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a collection but no product.
    sim_io.inject_post(0, "/collections",
        "{\"id\":\"" ++ test_col_uuid1 ++ "\",\"name\":\"Empty\"}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Add non-existent product — 404.
    sim_io.inject_bytes(0, "POST /collections/" ++ test_col_uuid1 ++ "/products/" ++ test_uuid1 ++ " HTTP/1.1\r\n\r\n");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 404);
}

test "delete collection cascades memberships" {
    var sim_io = SimIO.init(0xd005);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create product + collection + membership.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\"}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    sim_io.inject_post(0, "/collections",
        "{\"id\":\"" ++ test_col_uuid1 ++ "\",\"name\":\"Temp\"}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    sim_io.inject_bytes(0, "POST /collections/" ++ test_col_uuid1 ++ "/products/" ++ test_uuid1 ++ " HTTP/1.1\r\n\r\n");
    _ = run_until_response(&server, &sim_io, 0, 500) orelse return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Delete collection — memberships should be cleaned up.
    sim_io.inject_delete(0, "/collections/" ++ test_col_uuid1);
    const del_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(del_resp.status_code, 200);
    sim_io.clear_response(0);

    // Product should still exist.
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const product_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(product_resp.status_code, 200);
    try std.testing.expect(json_contains(product_resp.body, "\"name\":\"Widget\""));
}

test "storage err fault — returns 503" {
    var sim_io = SimIO.init(0xc002);
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = StateMachine.init(&storage);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // 100% err faults on storage.
    storage.err_fault_probability = 100;
    storage.prng_state = 0xc002;

    const mark = marks.check("storage: err fault injected");
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try mark.expect_hit();
    try std.testing.expectEqual(resp.status_code, 503);
    try std.testing.expect(json_contains(resp.body, "\"error\":\"service unavailable\""));
}
