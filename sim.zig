const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const http = @import("http.zig");
const crc = std.hash.crc.Crc32;
const StateMachine = @import("state_machine.zig").StateMachine;
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

    /// Inject an HTTP PUT request from a simulated client.
    pub fn inject_put(self: *SimIO, client_index: usize, key: []const u8, value: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "PUT /";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
        const line2 = " HTTP/1.1\r\nContent-Length: ";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        var cl_buf: [10]u8 = undefined;
        const cl_str = format_u32(&cl_buf, @intCast(value.len));
        @memcpy(buf[pos..][0..cl_str.len], cl_str);
        pos += cl_str.len;

        const end = "\r\n\r\n";
        @memcpy(buf[pos..][0..end.len], end);
        pos += end.len;
        @memcpy(buf[pos..][0..value.len], value);
        pos += value.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP GET request from a simulated client.
    pub fn inject_get(self: *SimIO, client_index: usize, key: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "GET /";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
        const line2 = " HTTP/1.1\r\n\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP DELETE request from a simulated client.
    pub fn inject_delete(self: *SimIO, client_index: usize, key: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "DELETE /";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..key.len], key);
        pos += key.len;
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

        // Verify X-Checksum if present.
        const checksum_marker = "X-Checksum: ";
        if (std.mem.indexOf(u8, headers, checksum_marker)) |ck_pos| {
            const ck_start = ck_pos + checksum_marker.len;
            if (ck_start + 8 <= headers.len) {
                const hex_str = headers[ck_start..][0..8];
                const expected_crc = std.fmt.parseInt(u32, hex_str, 16) catch return null;
                const actual_crc = crc.hash(body);
                if (expected_crc != actual_crc) return null;
            }
        }

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

    pub fn close(_: *SimIO, _: fd_t) void {
        // No-op in simulation.
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

const Server = ServerType(SimIO);

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

test "put then get returns value" {
    var sim_io = SimIO.init(42);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    // Connect a client.
    sim_io.connect_client(0);

    // PUT hello=world
    sim_io.inject_put(0, "hello", "world");
    const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);

    // Clear response buffer for next request.
    sim_io.clear_response(0);

    // GET hello
    sim_io.inject_get(0, "hello");
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, get_resp.body, "world");
}

test "get missing key returns not_found" {
    var sim_io = SimIO.init(99);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    sim_io.inject_get(0, "missing");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 404);
}

test "delete existing key" {
    var sim_io = SimIO.init(7);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);

    // PUT
    sim_io.inject_put(0, "key", "value");
    const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);
    sim_io.clear_response(0);

    // DELETE
    sim_io.inject_delete(0, "key");
    const del_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(del_resp.status_code, 200);
    sim_io.clear_response(0);

    // GET — should be not_found
    sim_io.inject_get(0, "key");
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 404);
}

test "deterministic replay — same seed same result" {
    // Run the same scenario twice with the same seed and verify identical behavior.
    var results: [2]u16 = undefined;

    for (0..2) |run| {
        var sim_io = SimIO.init(12345);
        var sm = try StateMachine.init(std.testing.allocator);
        defer sm.deinit(std.testing.allocator);
        var server = Server.init(&sim_io, &sm, 1);

        sim_io.connect_client(0);
        sim_io.inject_put(0, "determinism", "test");
        const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(put_resp.status_code, 200);
        sim_io.clear_response(0);

        sim_io.inject_get(0, "determinism");
        const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        results[run] = get_resp.status_code;
    }

    try std.testing.expectEqual(results[0], results[1]);
    try std.testing.expectEqual(results[0], @as(u16, 200));
}

test "overwrite value" {
    var sim_io = SimIO.init(55);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);

    // PUT key=v1
    sim_io.inject_put(0, "key", "v1");
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // PUT key=v2 (overwrite)
    sim_io.inject_put(0, "key", "v2");
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // GET key — should return v2
    sim_io.inject_get(0, "key");
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, resp.body, "v2");
}

test "fuzzer — random operations verified against oracle" {
    // PRNG-driven fuzzer: generates random PUT/GET/DELETE operations,
    // sends them as HTTP through the full Server → Connection → SimIO
    // stack, and verifies every response against a simple oracle.
    //
    // SimIO's partial delivery (random 1..N byte recv/send) exercises
    // HTTP parsing at every possible byte boundary.

    const key_pool_size = 16;
    const max_value_len = 32;
    const ops_per_seed = 500;
    const seed_count = 100;

    for (0..seed_count) |seed_offset| {
        const seed: u64 = seed_offset * 7919 + 1;
        var sim_io = SimIO.init(seed);
        var sm = try StateMachine.init(std.testing.allocator);
        defer sm.deinit(std.testing.allocator);
        var server = Server.init(&sim_io, &sm, 1);

        sim_io.connect_client(0);

        // Oracle: for each key index, track existence and value.
        var oracle_exists = [_]bool{false} ** key_pool_size;
        var oracle_values: [key_pool_size][max_value_len]u8 = undefined;
        var oracle_value_lens = [_]u8{0} ** key_pool_size;

        var fuzz_state: u64 = seed +% 0xcafe;

        for (0..ops_per_seed) |_| {
            const op_choice = splitmix64(&fuzz_state) % 10;
            const key_idx: usize = @intCast(splitmix64(&fuzz_state) % key_pool_size);

            // Generate key: "k" + 2-digit index.
            var key_buf: [3]u8 = undefined;
            key_buf[0] = 'k';
            key_buf[1] = '0' + @as(u8, @intCast(key_idx / 10));
            key_buf[2] = '0' + @as(u8, @intCast(key_idx % 10));
            const key: []const u8 = &key_buf;

            if (op_choice < 4) {
                // 40% GET
                sim_io.inject_get(0, key);
                const resp = run_until_response(&server, &sim_io, 0, 500) orelse
                    return error.TestUnexpectedResult;

                if (oracle_exists[key_idx]) {
                    try std.testing.expectEqual(resp.status_code, 200);
                    const expected = oracle_values[key_idx][0..oracle_value_lens[key_idx]];
                    try std.testing.expectEqualSlices(u8, resp.body, expected);
                } else {
                    try std.testing.expectEqual(resp.status_code, 404);
                }
            } else if (op_choice < 8) {
                // 40% PUT
                const val_len: usize = @intCast(1 + splitmix64(&fuzz_state) % max_value_len);
                var val_buf: [max_value_len]u8 = undefined;
                for (0..val_len) |i| {
                    val_buf[i] = @intCast(65 + splitmix64(&fuzz_state) % 26);
                }
                const value: []const u8 = val_buf[0..val_len];

                sim_io.inject_put(0, key, value);
                const resp = run_until_response(&server, &sim_io, 0, 500) orelse
                    return error.TestUnexpectedResult;

                try std.testing.expectEqual(resp.status_code, 200);

                // Update oracle.
                oracle_exists[key_idx] = true;
                oracle_value_lens[key_idx] = @intCast(val_len);
                @memcpy(oracle_values[key_idx][0..val_len], value);
            } else {
                // 20% DELETE
                sim_io.inject_delete(0, key);
                const resp = run_until_response(&server, &sim_io, 0, 500) orelse
                    return error.TestUnexpectedResult;

                if (oracle_exists[key_idx]) {
                    try std.testing.expectEqual(resp.status_code, 200);
                    oracle_exists[key_idx] = false;
                } else {
                    try std.testing.expectEqual(resp.status_code, 404);
                }
            }

            sim_io.clear_response(0);
        }
    }
}

test "fuzzer — multiple clients" {
    // Exercises concurrent connections: multiple clients issue random
    // operations against the same state machine. The oracle is shared
    // across all clients since they all talk to the same KV store.

    const key_pool_size = 8;
    const max_value_len = 16;
    const num_clients = 4;
    const ops_per_client = 100;

    var sim_io = SimIO.init(0xbeef);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    // Connect all clients. Run ticks between connects so the server
    // can accept each one.
    for (0..num_clients) |i| {
        sim_io.connect_client(i);
        run_ticks(&server, &sim_io, 10);
    }

    // Shared oracle.
    var oracle_exists = [_]bool{false} ** key_pool_size;
    var oracle_values: [key_pool_size][max_value_len]u8 = undefined;
    var oracle_value_lens = [_]u8{0} ** key_pool_size;

    var fuzz_state: u64 = 0xbeef_cafe;

    // Round-robin clients, one operation at a time.
    for (0..ops_per_client * num_clients) |op_num| {
        const client: usize = op_num % num_clients;
        const op_choice = splitmix64(&fuzz_state) % 3;
        const key_idx: usize = @intCast(splitmix64(&fuzz_state) % key_pool_size);

        var key_buf: [3]u8 = undefined;
        key_buf[0] = 'k';
        key_buf[1] = '0' + @as(u8, @intCast(key_idx / 10));
        key_buf[2] = '0' + @as(u8, @intCast(key_idx % 10));
        const key: []const u8 = &key_buf;

        switch (op_choice) {
            0 => {
                sim_io.inject_get(client, key);
                const resp = run_until_response(&server, &sim_io, client, 500) orelse
                    return error.TestUnexpectedResult;

                if (oracle_exists[key_idx]) {
                    try std.testing.expectEqual(resp.status_code, 200);
                    const expected = oracle_values[key_idx][0..oracle_value_lens[key_idx]];
                    try std.testing.expectEqualSlices(u8, resp.body, expected);
                } else {
                    try std.testing.expectEqual(resp.status_code, 404);
                }
            },
            1 => {
                const val_len: usize = @intCast(1 + splitmix64(&fuzz_state) % max_value_len);
                var val_buf: [max_value_len]u8 = undefined;
                for (0..val_len) |i| {
                    val_buf[i] = @intCast(65 + splitmix64(&fuzz_state) % 26);
                }
                const value: []const u8 = val_buf[0..val_len];

                sim_io.inject_put(client, key, value);
                const resp = run_until_response(&server, &sim_io, client, 500) orelse
                    return error.TestUnexpectedResult;
                try std.testing.expectEqual(resp.status_code, 200);

                oracle_exists[key_idx] = true;
                oracle_value_lens[key_idx] = @intCast(val_len);
                @memcpy(oracle_values[key_idx][0..val_len], value);
            },
            2 => {
                sim_io.inject_delete(client, key);
                const resp = run_until_response(&server, &sim_io, client, 500) orelse
                    return error.TestUnexpectedResult;

                if (oracle_exists[key_idx]) {
                    try std.testing.expectEqual(resp.status_code, 200);
                    oracle_exists[key_idx] = false;
                } else {
                    try std.testing.expectEqual(resp.status_code, 404);
                }
            },
            else => unreachable,
        }

        sim_io.clear_response(client);
    }
}

test "fuzzer — connection drops and reconnects" {
    // Tests fault injection: randomly disconnect a client mid-session,
    // let the server clean up, reconnect, and verify the state machine
    // is still consistent.

    var sim_io = SimIO.init(0xdead);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // PUT a key before the drop.
    sim_io.inject_put(0, "survive", "this");
    const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);
    sim_io.clear_response(0);

    // Drop the connection.
    sim_io.disconnect_client(0);
    // Run ticks so the server discovers the disconnect and cleans up.
    run_ticks(&server, &sim_io, 50);

    // Reconnect on a different client slot.
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // The state machine should still have the key.
    sim_io.inject_get(1, "survive");
    const get_resp = run_until_response(&server, &sim_io, 1, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, get_resp.body, "this");
}

test "pipelining — back-to-back requests on one connection" {
    // Inject two complete HTTP requests into the client buffer before
    // any ticks run. The server must process both via keep-alive,
    // shifting leftover bytes after the first response.
    var sim_io = SimIO.init(0x1234);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Inject PUT + GET back-to-back (pipelined).
    sim_io.inject_put(0, "pipekey", "pipevalue");
    sim_io.inject_get(0, "pipekey");

    // First response: PUT 200.
    const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);
    sim_io.clear_response(0);

    // Second response: GET 200 with the value.
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, get_resp.body, "pipevalue");
}

test "pipelining — fuzzer with random pipeline depth" {
    // PRNG-driven: for each seed, pipeline 1-4 requests before waiting
    // for responses. Exercises the leftover-byte shift at every boundary.
    const seed_count = 50;
    const ops_per_seed = 100;

    for (0..seed_count) |seed_offset| {
        const seed: u64 = seed_offset * 3571 + 0x1234;
        var sim_io = SimIO.init(seed);
        var sm = try StateMachine.init(std.testing.allocator);
        defer sm.deinit(std.testing.allocator);
        var server = Server.init(&sim_io, &sm, 1);

        sim_io.connect_client(0);
        run_ticks(&server, &sim_io, 10);

        var fuzz_state: u64 = seed +% 0xbead;
        var op_count: usize = 0;

        while (op_count < ops_per_seed) {
            // Choose pipeline depth: 1-4 requests.
            const depth: usize = @intCast(1 + splitmix64(&fuzz_state) % 4);
            const actual_depth = @min(depth, ops_per_seed - op_count);

            // Inject all requests at once.
            for (0..actual_depth) |_| {
                var key_buf: [4]u8 = undefined;
                key_buf[0] = 'p';
                key_buf[1] = @intCast(65 + splitmix64(&fuzz_state) % 26);
                key_buf[2] = @intCast(65 + splitmix64(&fuzz_state) % 26);
                key_buf[3] = @intCast(65 + splitmix64(&fuzz_state) % 26);

                const op = splitmix64(&fuzz_state) % 3;
                if (op < 2) {
                    // PUT
                    var val_buf: [8]u8 = undefined;
                    for (&val_buf) |*b| b.* = @intCast(65 + splitmix64(&fuzz_state) % 26);
                    sim_io.inject_put(0, &key_buf, &val_buf);
                } else {
                    // GET
                    sim_io.inject_get(0, &key_buf);
                }
            }

            // Drain all responses.
            for (0..actual_depth) |_| {
                const resp = run_until_response(&server, &sim_io, 0, 500) orelse
                    return error.TestUnexpectedResult;
                // Any 200/404 is valid — we're testing the pipeline mechanics, not the oracle.
                assert(resp.status_code == 200 or resp.status_code == 404);
                sim_io.clear_response(0);
            }

            op_count += actual_depth;
        }
    }
}

test "mid-send disconnect — server recovers" {
    // PUT a large value, start getting the response, then disconnect
    // before the server finishes sending. Verify the server cleans up
    // and remains functional for other clients.
    var sim_io = SimIO.init(0xd15c0);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    // Client 0: PUT a value so it's stored.
    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Use a moderately large value so the response takes multiple send cycles.
    var big_value: [4096]u8 = undefined;
    @memset(&big_value, 'X');
    sim_io.inject_put(0, "bigkey", &big_value);
    const put_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);
    sim_io.clear_response(0);

    // Now GET the big value — response will be large.
    sim_io.inject_get(0, "bigkey");
    // Run a few ticks so the server starts sending, but don't wait for completion.
    run_ticks(&server, &sim_io, 5);

    // Disconnect mid-send.
    sim_io.disconnect_client(0);
    // Let the server discover the disconnect and clean up.
    run_ticks(&server, &sim_io, 50);

    // Client 1: verify the server is still functional.
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);
    sim_io.inject_get(1, "bigkey");
    const get_resp = run_until_response(&server, &sim_io, 1, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, get_resp.body, &big_value);
}

test "mid-send disconnect — fuzzer with random disconnect timing" {
    // For each seed, PUT a value, start a GET, disconnect after a random
    // number of ticks, then verify recovery with a new client.
    const seed_count = 50;

    for (0..seed_count) |seed_offset| {
        const seed: u64 = seed_offset * 6131 + 0xd15c0;
        var sim_io = SimIO.init(seed);
        var sm = try StateMachine.init(std.testing.allocator);
        defer sm.deinit(std.testing.allocator);
        var server = Server.init(&sim_io, &sm, 1);

        var fuzz_state: u64 = seed +% 0xface;

        // Client 0: store a value.
        sim_io.connect_client(0);
        run_ticks(&server, &sim_io, 10);

        const val_len: usize = @intCast(1 + splitmix64(&fuzz_state) % 4096);
        var val_buf: [4096]u8 = undefined;
        for (val_buf[0..val_len]) |*b| b.* = @intCast(65 + splitmix64(&fuzz_state) % 26);

        sim_io.inject_put(0, "dk", val_buf[0..val_len]);
        _ = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        sim_io.clear_response(0);

        // Start GET, run random number of ticks, then disconnect.
        sim_io.inject_get(0, "dk");
        const ticks_before_disconnect: usize = @intCast(1 + splitmix64(&fuzz_state) % 20);
        run_ticks(&server, &sim_io, ticks_before_disconnect);

        sim_io.disconnect_client(0);
        run_ticks(&server, &sim_io, 50);

        // Client 1: verify server still works.
        sim_io.connect_client(1);
        run_ticks(&server, &sim_io, 10);
        sim_io.inject_get(1, "dk");
        const resp = run_until_response(&server, &sim_io, 1, 500) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(resp.status_code, 200);
        try std.testing.expectEqualSlices(u8, resp.body, val_buf[0..val_len]);
    }
}

test "buffer boundaries — key_max and value_max" {
    // Test with keys and values at exactly the maximum allowed sizes.
    var sim_io = SimIO.init(0xed6e);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Maximum-length key (key_max = 256 bytes).
    var max_key: [message.key_max]u8 = undefined;
    @memset(&max_key, 'K');

    // Maximum-length value (value_max = 64KB).
    var max_value: [message.value_max]u8 = undefined;
    @memset(&max_value, 'V');

    // PUT with max key + max value.
    sim_io.inject_put(0, &max_key, &max_value);
    const put_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(put_resp.status_code, 200);
    sim_io.clear_response(0);

    // GET with max key — should return max value.
    sim_io.inject_get(0, &max_key);
    const get_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expectEqualSlices(u8, get_resp.body, &max_value);
    sim_io.clear_response(0);

    // DELETE with max key.
    sim_io.inject_delete(0, &max_key);
    const del_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(del_resp.status_code, 200);
    sim_io.clear_response(0);

    // Verify deleted.
    sim_io.inject_get(0, &max_key);
    const gone_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(gone_resp.status_code, 404);
}

test "buffer boundaries — value sizes at powers of 2" {
    // Test values at sizes that are common boundary points: 1, 2, 4, ..., value_max.
    var sim_io = SimIO.init(0xb0e2);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    var size: usize = 1;
    var idx: u8 = 0;
    while (size <= message.value_max) : (size *= 2) {
        var key_buf: [4]u8 = undefined;
        key_buf[0] = 's';
        key_buf[1] = '0' + idx / 10;
        key_buf[2] = '0' + idx % 10;
        key_buf[3] = 0;
        const key = key_buf[0..3];

        var val_buf: [message.value_max]u8 = undefined;
        // Fill with a pattern based on size so values are distinct.
        @memset(val_buf[0..size], @intCast(65 + idx % 26));
        const value = val_buf[0..size];

        sim_io.inject_put(0, key, value);
        const put_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(put_resp.status_code, 200);
        sim_io.clear_response(0);

        sim_io.inject_get(0, key);
        const get_resp = run_until_response(&server, &sim_io, 0, 2000) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(get_resp.status_code, 200);
        try std.testing.expectEqualSlices(u8, get_resp.body, value);
        sim_io.clear_response(0);

        idx += 1;
    }
}

test "timeout — partial request triggers close" {
    // Send an incomplete HTTP request (no \r\n\r\n terminator) and verify
    // the connection gets closed after the timeout period.
    var sim_io = SimIO.init(0xface);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Inject a partial request (no header terminator).
    sim_io.inject_bytes(0, "GET /hello HTTP/1.1\r\n");
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
    // then tick past the timeout. The recv will fail (-1) and the
    // connection would close from that, but even without the disconnect
    // the timeout logic would eventually close it.
    sim_io.disconnect_client(0);

    // Tick just past the timeout.
    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
        // Don't call io.run_for_ns to avoid stale completion issues
        // after the connection slot has been freed and recycled.
    }

    // After timeout, the receiving connection should be freed.
    // An accepting connection may still exist (no IO cycles to complete it).
    var any_active = false;
    for (&server.connections, server.connections_busy) |*conn, busy| {
        if (busy and conn.state != .free and conn.state != .accepting) {
            any_active = true;
            break;
        }
    }
    try std.testing.expect(!any_active);
}

// --- Coverage mark tests ---
//
// Each test below exists to prove one mark site fires. Minimal setup,
// one mark check, one expect_hit. Named for the scenario, not the mark.

test "mark: disconnect triggers recv peer closed" {
    var sim_io = SimIO.init(0xa001);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
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
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // PUT a value so there's something to GET.
    sim_io.inject_put(0, "key", "value");
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    sim_io.clear_response(0);

    // Enable 100% send faults, then GET. The response send will fail.
    sim_io.send_fault_probability = 100;
    sim_io.inject_get(0, "key");
    const mark = marks.check("send: error");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: idle connection triggers timeout" {
    var sim_io = SimIO.init(0xa003);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Send a partial request so connection stays in receiving state.
    sim_io.inject_bytes(0, "GET /hello HTTP/1.1\r\n");
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
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    const mark = marks.check("invalid HTTP");
    sim_io.inject_bytes(0, "GARBAGE\x00\x01\x02\r\n\r\n");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: empty key triggers unmapped request" {
    var sim_io = SimIO.init(0xa005);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // GET / has an empty key after stripping the leading slash — translate returns null.
    const mark = marks.check("unmapped request");
    sim_io.inject_bytes(0, "GET / HTTP/1.1\r\n\r\n");
    run_ticks(&server, &sim_io, 50);
    try mark.expect_hit();
}

test "mark: many puts triggers approaching capacity" {
    var sim_io = SimIO.init(0xa006);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Fill past the 90% threshold (capacity=4096, capacity_max=3072, 90% = 2764).
    // Insert 2765 unique keys to cross the threshold.
    var key_buf: [10]u8 = undefined;
    for (0..2765) |i| {
        // Generate unique keys: "k" + zero-padded index.
        key_buf[0] = 'k';
        var num = @as(u32, @intCast(i));
        var pos: usize = 5;
        while (pos > 1) {
            pos -= 1;
            key_buf[pos] = '0' + @as(u8, @intCast(num % 10));
            num /= 10;
        }
        const key = key_buf[0..6];
        sim_io.inject_put(0, key, "v");
        _ = run_until_response(&server, &sim_io, 0, 500) orelse
            return error.TestUnexpectedResult;
        sim_io.clear_response(0);
    }

    // The next put should trigger the approaching capacity warning.
    const mark = marks.check("approaching capacity");
    sim_io.inject_put(0, "trigger", "v");
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try mark.expect_hit();
}

test "mark: accept failure logs warning" {
    var sim_io = SimIO.init(0xa007);
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);
    var server = Server.init(&sim_io, &sm, 1);

    // 100% accept fault — every accept attempt fails.
    sim_io.accept_fault_probability = 100;
    sim_io.connect_client(0);
    const mark = marks.check("accept failed");
    run_ticks(&server, &sim_io, 10);
    try mark.expect_hit();
}
