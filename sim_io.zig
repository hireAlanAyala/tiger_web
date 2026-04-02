//! Simulated IO — deterministic replacement for the real epoll-based IO.
//!
//! All operations complete synchronously during `run_for_ns`. A seeded
//! PRNG controls ordering, partial delivery, and fault injection.
//! Same seed → same faults → fully reproducible.
//!
//! Extracted from sim.zig so both sim.zig (native handler tests) and
//! sim_sidecar.zig (sidecar handler tests) can import it without
//! pulling in each other's test code.

const std = @import("std");
const assert = std.debug.assert;
const http = @import("framework/http.zig");
const auth = @import("framework/auth.zig");
const PRNG = @import("stdx").PRNG;

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
            readable,
        };
    };

    pub const max_clients = 8;
    const max_pending = 64;
    const client_buf_size = (http.recv_buf_max + http.send_buf_max) * 2;

    /// Pending completion queue.
    pending: [max_pending]PendingOp,
    pending_count: u32,

    /// Simulated client connections.
    clients: [max_clients]SimClient,
    next_fd: fd_t,

    /// PRNG for deterministic behavior.
    prng: PRNG,

    /// Fault injection probabilities. Each operation rolls the PRNG and
    /// fails with -1 if the roll hits. Ratio.zero() means no faults.
    /// Same seed → same faults → fully reproducible.
    accept_fault_probability: PRNG.Ratio,
    recv_fault_probability: PRNG.Ratio,
    send_fault_probability: PRNG.Ratio,
    /// Probability that send_now returns null (WouldBlock simulation).
    /// Controls how often the fast path succeeds vs falls back to async.
    /// Swarm testing should randomize this per seed.
    send_now_fault_probability: PRNG.Ratio,

    const PendingOp = struct {
        completion: *Completion,
        active: bool,
    };

    pub const SimClient = struct {
        connected: bool,
        accepted: bool,
        server_closed: bool,
        fd: fd_t,
        /// Which listener this client connects to. Models the OS:
        /// accept(listen_fd) only returns connections for that socket.
        target_listen_fd: fd_t,
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
                .server_closed = false,
                .fd = 0,
                .target_listen_fd = 1,
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
            .prng = PRNG.from_seed(seed),
            .accept_fault_probability = PRNG.Ratio.zero(),
            .recv_fault_probability = PRNG.Ratio.zero(),
            .send_fault_probability = PRNG.Ratio.zero(),
            .send_now_fault_probability = PRNG.Ratio.zero(),
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

    /// SimIO equivalent of IO.open_unix_listener. No real socket —
    /// returns a synthetic fd from the same allocator as client fds.
    /// The accept completion matches clients by this fd via
    /// target_listen_fd.
    pub fn open_unix_listener(self: *SimIO, _: []const u8) !fd_t {
        const fd = self.next_fd;
        self.next_fd += 1;
        return fd;
    }

    // --- Test control API ---

    /// Simulate a client connecting to a specific listener.
    /// Models the OS: a client connects to a socket address, which
    /// maps to a listen_fd. accept(listen_fd) only returns connections
    /// for that socket. No "match any" — that doesn't exist in the kernel.
    pub fn connect_client(self: *SimIO, client_index: usize, target_listen_fd: fd_t) void {
        assert(client_index < max_clients);
        self.clients[client_index].connected = true;
        self.clients[client_index].accepted = false;
        self.clients[client_index].server_closed = false;
        self.clients[client_index].fd = self.next_fd;
        self.next_fd += 1;
        self.clients[client_index].target_listen_fd = target_listen_fd;
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
        self.inject_with_body(client_index, "POST ", path, body, "");
    }

    pub fn inject_post_datastar(self: *SimIO, client_index: usize, path: []const u8, body: []const u8) void {
        self.inject_with_body(client_index, "POST ", path, body, "Datastar-Request: true\r\n");
    }

    /// Inject an HTTP PUT request to a path with a body.
    pub fn inject_put(self: *SimIO, client_index: usize, path: []const u8, body: []const u8) void {
        self.inject_with_body(client_index, "PUT ", path, body, "");
    }

    pub fn inject_put_datastar(self: *SimIO, client_index: usize, path: []const u8, body: []const u8) void {
        self.inject_with_body(client_index, "PUT ", path, body, "Datastar-Request: true\r\n");
    }

    fn inject_with_body(self: *SimIO, client_index: usize, method: []const u8, path: []const u8, body: []const u8, extra_headers: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        @memcpy(buf[pos..][0..method.len], method);
        pos += method.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;
        pos += write_cookie_header(buf[pos..]);
        @memcpy(buf[pos..][0..extra_headers.len], extra_headers);
        pos += extra_headers.len;
        const cl_hdr = "Content-Length: ";
        @memcpy(buf[pos..][0..cl_hdr.len], cl_hdr);
        pos += cl_hdr.len;

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
        self.inject_get_with_headers(client_index, path, "");
    }

    pub fn inject_get_datastar(self: *SimIO, client_index: usize, path: []const u8) void {
        self.inject_get_with_headers(client_index, path, "Datastar-Request: true\r\n");
    }

    fn inject_get_with_headers(self: *SimIO, client_index: usize, path: []const u8, extra_headers: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "GET ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;
        pos += write_cookie_header(buf[pos..]);
        @memcpy(buf[pos..][0..extra_headers.len], extra_headers);
        pos += extra_headers.len;
        const end = "\r\n";
        @memcpy(buf[pos..][0..end.len], end);
        pos += end.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Inject an HTTP DELETE to a path.
    pub fn inject_delete(self: *SimIO, client_index: usize, path: []const u8) void {
        self.inject_delete_with_headers(client_index, path, "");
    }

    pub fn inject_delete_datastar(self: *SimIO, client_index: usize, path: []const u8) void {
        self.inject_delete_with_headers(client_index, path, "Datastar-Request: true\r\n");
    }

    fn inject_delete_with_headers(self: *SimIO, client_index: usize, path: []const u8, extra_headers: []const u8) void {
        var buf: [http.recv_buf_max]u8 = undefined;
        var pos: usize = 0;

        const line1 = "DELETE ";
        @memcpy(buf[pos..][0..line1.len], line1);
        pos += line1.len;
        @memcpy(buf[pos..][0..path.len], path);
        pos += path.len;
        const line2 = " HTTP/1.1\r\n";
        @memcpy(buf[pos..][0..line2.len], line2);
        pos += line2.len;
        pos += write_cookie_header(buf[pos..]);
        @memcpy(buf[pos..][0..extra_headers.len], extra_headers);
        pos += extra_headers.len;
        const end = "\r\n";
        @memcpy(buf[pos..][0..end.len], end);
        pos += end.len;

        self.inject_bytes(client_index, buf[0..pos]);
    }

    /// Parsed HTTP response for test verification.
    pub const HttpResponse = struct {
        status_code: u16,
        body: []const u8,

        /// Whether this SSE response contains an error fragment.
        /// Follow-ups always return HTTP 200; the error is in the body.
        pub fn sse_has_error(self: HttpResponse) bool {
            return std.mem.indexOf(u8, self.body, "<div class=\"error\">") != null;
        }

        /// Whether the operation succeeded — works for both HTTP and SSE.
        /// HTTP: status 200. SSE follow-up: status 200 and no error fragment.
        pub fn is_ok(self: HttpResponse) bool {
            return self.status_code == 200 and !self.sse_has_error();
        }
    };

    /// Read an HTTP response with Content-Length (keep-alive).
    /// For Connection: close responses (e.g., 503), use
    /// read_close_response instead — it waits for server_closed.
    /// Sidecar sim tests use both: 200 is keep-alive, 503 is close.
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

    /// Read a Connection: close response. Waits until the server
    /// has closed the fd (server_closed = true), then returns the
    /// full body. Used for 503 and SSE responses.
    pub fn read_close_response(self: *SimIO, client_index: usize) ?HttpResponse {
        assert(client_index < max_clients);
        const client = &self.clients[client_index];
        if (!client.server_closed) return null;
        if (client.recv_len == 0) return null;
        const data = client.recv_buf[0..client.recv_len];

        const header_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
        if (data.len < 12) return null;
        if (!std.mem.startsWith(u8, data, "HTTP/1.1 ")) return null;
        const status_code = std.fmt.parseInt(u16, data[9..12], 10) catch return null;

        const body = data[header_end + 4 ..];

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
            // No Content-Length — Connection: close response.
            // The entire recv buffer is the response.
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

    pub fn accept(self: *SimIO, listen_fd: fd_t, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        completion.* = .{
            .fd = listen_fd,
            .operation = .accept,
            .context = context,
            .callback = callback,
        };
        self.enqueue(completion);
    }

    /// Readability notification — fires the callback immediately with 0.
    pub fn readable(self: *SimIO, _: fd_t, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        completion.* = .{
            .operation = .readable,
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

    /// Non-blocking send — SimIO equivalent. Returns null based on
    /// send_now_fault_probability. Matches real IO: null means
    /// "can't complete now, fall back to async."
    pub fn send_now(self: *SimIO, fd: fd_t, buffer: []const u8) ?usize {
        assert(buffer.len > 0);
        if (self.prng.chance(self.send_now_fault_probability)) return null;
        for (&self.clients) |*client| {
            if (client.fd == fd and client.connected) {
                const max = @min(buffer.len, client.recv_buf.len - client.recv_len);
                if (max == 0) return null;
                const n = self.prng.range_inclusive(u32, 1, @intCast(max));
                @memcpy(client.recv_buf[client.recv_len..][0..n], buffer[0..n]);
                client.recv_len += n;
                return n;
            }
        }
        return null;
    }

    pub fn shutdown(self: *SimIO, fd: fd_t, _: std.posix.ShutdownHow) void {
        for (&self.clients) |*client| {
            if (client.fd == fd) {
                client.server_closed = true;
            }
        }
    }

    pub fn close(self: *SimIO, fd: fd_t) void {
        for (&self.pending) |*p| {
            if (p.active and p.completion.fd == fd) {
                p.completion.operation = .none;
                p.active = false;
                self.pending_count -= 1;
            }
        }
        for (&self.clients) |*client| {
            if (client.fd == fd) {
                client.server_closed = true;
            }
        }
    }

    pub fn run_for_ns(self: *SimIO, _: u64) void {
        var to_process: [max_pending]*Completion = undefined;
        var count: u32 = 0;
        for (&self.pending) |*p| {
            if (!p.active) continue;
            to_process[count] = p.completion;
            p.active = false;
            count += 1;
        }
        self.pending_count -= count;

        for (to_process[0..count]) |completion| {
            self.complete(completion);
        }
    }

    fn enqueue(self: *SimIO, completion: *Completion) void {
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
        unreachable;
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
                for (&self.clients) |*client| {
                    if (client.connected and !client.accepted and
                        client.target_listen_fd == completion.fd)
                    {
                        const fd = client.fd;
                        client.accepted = true;
                        completion.callback(completion.context, fd);
                        return;
                    }
                }
                completion.operation = .accept;
                self.enqueue(completion);
            },
            .recv => {
                if (self.fault(.recv)) {
                    completion.callback(completion.context, -1);
                    return;
                }
                for (&self.clients) |*client| {
                    if (client.connected and client.fd == completion.fd) {
                        // After shutdown, recv returns 0 (EOF / graceful close).
                        // Models real POSIX: shutdown(SHUT_BOTH) → recv
                        // returns 0. This unblocks terminate_join.
                        if (client.server_closed) {
                            completion.callback(completion.context, 0);
                            return;
                        }
                        const remaining = client.send_len - client.send_pos;
                        if (remaining == 0) {
                            completion.operation = .recv;
                            self.enqueue(completion);
                            return;
                        }
                        const buf = completion.buffer.?;
                        const max_n = @min(remaining, @as(u32, @intCast(buf.len)));
                        const n = self.prng.range_inclusive(u32, 1, max_n);
                        @memcpy(buf[0..n], client.send_buf[client.send_pos..][0..n]);
                        client.send_pos += n;
                        completion.callback(completion.context, @intCast(n));
                        return;
                    }
                }
                completion.callback(completion.context, -1);
            },
            .send => {
                if (self.fault(.send)) {
                    completion.callback(completion.context, -1);
                    return;
                }
                for (&self.clients) |*client| {
                    if (client.connected and client.fd == completion.fd) {
                        const buf = completion.buffer_const.?;
                        const total: u32 = @intCast(buf.len);
                        const n = self.prng.range_inclusive(u32, 1, total);
                        assert(client.recv_len + n <= client_buf_size);
                        @memcpy(client.recv_buf[client.recv_len..][0..n], buf[0..n]);
                        client.recv_len += n;
                        completion.callback(completion.context, @intCast(n));
                        return;
                    }
                }
                completion.callback(completion.context, -1);
            },
            .readable => {
                completion.callback(completion.context, 0);
            },
            .none => unreachable,
        }
    }

    fn fault(self: *SimIO, op: Completion.Op) bool {
        const probability = switch (op) {
            .accept => self.accept_fault_probability,
            .recv => self.recv_fault_probability,
            .send => self.send_fault_probability,
            .readable => PRNG.Ratio.zero(),
            .none => unreachable,
        };
        return self.prng.chance(probability);
    }
};

// --- Helpers used by SimIO methods ---

const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

/// Write "Cookie: <name>=<signed_value>\r\n" into buf. Returns bytes written.
pub fn write_cookie_header(buf: []u8) usize {
    const prefix = "Cookie: " ++ auth.cookie_name ++ "=";
    @memcpy(buf[0..prefix.len], prefix);
    var cookie_buf: [auth.cookie_value_max]u8 = undefined;
    const cookie_val = auth.sign_cookie(&cookie_buf, 1, .authenticated, test_key);
    @memcpy(buf[prefix.len..][0..cookie_val.len], cookie_val);
    const crlf = "\r\n";
    @memcpy(buf[prefix.len + cookie_val.len ..][0..crlf.len], crlf);
    return prefix.len + cookie_val.len + crlf.len;
}

/// Format a u32 as a decimal string into buf. Returns the written slice.
pub fn format_u32(buf: *[10]u8, val: u32) []const u8 {
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
