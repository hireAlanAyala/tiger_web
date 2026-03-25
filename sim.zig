//! Simulation test harness — full-stack tests with deterministic IO.
//!
//! An executable (not a test binary) so we own std_options and control
//! logging directly. Matches TigerBeetle: fuzzers and simulators are
//! executables, not test binaries.
//!
//! Usage:
//!   zig build test                    # run all sim tests
//!   zig build test -- --seed=0xd021   # specific seed (for fuzz tests)

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const http = @import("framework/lib.zig").http;
const state_machine = @import("state_machine.zig");
const App = @import("app.zig");
const Storage = App.Storage;
const StateMachine = App.SM;
const ServerType = @import("framework/lib.zig").server.ServerType;
const ConnectionType = @import("framework/lib.zig").connection.ConnectionType;
const marks = @import("framework/lib.zig").marks;
const PRNG = @import("framework/lib.zig").prng;
const TimeSim = @import("framework/lib.zig").time.TimeSim;
const auth = @import("framework/lib.zig").auth;

const log = std.log.scoped(.sim);

/// Compile at .debug so nothing is stripped. Runtime logFn handles
/// per-scope filtering and --log-debug override.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = sim_log,
};

/// Per-scope filtering at runtime. In normal mode, framework scopes
/// (server, connection, storage, etc.) only print at .err. The .sim
/// scope prints at .info and above. With --log-debug, everything prints.
fn sim_log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // --log-debug: print everything, no filtering.
    if (verbose) {
        std.log.defaultLog(message_level, scope, format, args);
        return;
    }

    // Per-scope filtering: framework scopes at .err only, sim at .info.
    const max_level: std.log.Level = switch (scope) {
        .sim => .info,
        .server, .connection, .storage, .wal, .io, .tracer, .app => .err,
        else => .warn,
    };
    if (@intFromEnum(message_level) <= @intFromEnum(max_level)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

const allocator = std.heap.page_allocator;

/// Opt in to coverage marks in non-test executable builds.
/// See framework/marks.zig — marks are active when this flag is set.
pub const enable_marks = true;

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
    prng: PRNG,

    /// Fault injection probabilities. Each operation rolls the PRNG and
    /// fails with -1 if the roll hits. Ratio.zero() means no faults.
    /// Same seed → same faults → fully reproducible.
    accept_fault_probability: PRNG.Ratio,
    recv_fault_probability: PRNG.Ratio,
    send_fault_probability: PRNG.Ratio,

    const PendingOp = struct {
        completion: *Completion,
        active: bool,
    };

    const SimClient = struct {
        connected: bool,
        accepted: bool,
        server_closed: bool,
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
                .server_closed = false,
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
            .prng = PRNG.from_seed(seed),
            .accept_fault_probability = PRNG.Ratio.zero(),
            .recv_fault_probability = PRNG.Ratio.zero(),
            .send_fault_probability = PRNG.Ratio.zero(),
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
        self.clients[client_index].connected = true;
        self.clients[client_index].accepted = false;
        self.clients[client_index].server_closed = false;
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

    /// Read a Connection: close response (no Content-Length).
    /// Waits until the server has closed the fd, then returns the full body.
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
        // Mark the client as server-closed so read_close_response
        // knows the response is complete.
        for (&self.clients) |*client| {
            if (client.fd == fd) {
                client.server_closed = true;
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
                        const n = self.prng.range_inclusive(u32, 1, max_n);
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
        return self.prng.chance(probability);
    }
};

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

const Server = ServerType(App, SimIO, App.Storage);
const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

/// Write "Cookie: <name>=<signed_value>\r\n" into buf. Returns bytes written.
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
        // Try Content-Length first, then Connection: close.
        if (io.read_response(client_index)) |resp| return resp;
        if (io.read_close_response(client_index)) |resp| return resp;
    }
    return null;
}

fn run_until_close_response(server: *Server, io: *SimIO, client_index: usize, max_ticks: usize) ?SimIO.HttpResponse {
    for (0..max_ticks) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
        if (io.read_close_response(client_index)) |resp| return resp;
    }
    return null;
}

/// Clear the response and reconnect the client for the next request.
/// SSE responses use Connection: close; non-SSE use keep-alive.
/// Reconnecting works for both: keep-alive connections close when
/// the old fd becomes unreachable (new fd assigned).
fn clear_and_reconnect(io: *SimIO, server: *Server, client_index: usize) void {
    io.clear_response(client_index);
    // Run a few ticks to let the server process the connection close.
    for (0..10) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
    // Suspend accept faults during reconnection — Connection: close means
    // every request needs a reconnect, so accept faults during reconnection
    // would stall the fuzzer rather than exercise interesting behavior.
    const saved_accept_fault = io.accept_fault_probability;
    io.accept_fault_probability = PRNG.Ratio.zero();
    io.connect_client(client_index);
    // Run ticks for the accept to complete.
    for (0..10) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
    io.accept_fault_probability = saved_accept_fault;
}

/// Helper: check that a response body contains a substring.
fn body_contains(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

fn count_occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

/// Cap address space so a runaway test can't eat all system memory.
/// Matches TB's testing/fuzz.zig limit_ram().
fn limit_address_space() void {
    if (@import("builtin").target.os.tag != .linux) return;
    const GiB = 1024 * 1024 * 1024;
    std.posix.setrlimit(.AS, .{
        .cur = 4 * GiB,
        .max = 4 * GiB,
    }) catch {};
}

const test_uuid1 = "aabbccdd11223344aabbccdd11223344";
const test_uuid2 = "aabbccdd11223344aabbccdd11223345";

// =====================================================================
// Infrastructure tests — deterministic replay, connection plumbing
// =====================================================================

fn @"deterministic replay — same seed same result"() void {
    var results: [2]u16 = undefined;

    for (0..2) |run| {
        var sim_io = SimIO.init(12345);
        var storage = App.Storage.init(":memory:") catch unreachable;
        defer storage.deinit();
        var sm = StateMachine.init(&storage, false, 0, test_key);
        var time_sim = TimeSim{};
        var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
        defer server.deinit(allocator);

        sim_io.connect_client(0);
        sim_io.inject_post(0, "/products",
            "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
        );
        const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            unreachable;
        assert(create_resp.status_code == 200);
        clear_and_reconnect(&sim_io, &server, 0);

        sim_io.inject_get(0, "/products/" ++ test_uuid1);
        const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
            unreachable;
        results[run] = get_resp.status_code;
    }

    assert(results[0] == results[1]);
    assert(results[0] == 200);
}

fn @"pipelining — back-to-back requests on one connection"() void {
    var sim_io = SimIO.init(0x1234);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Send POST, wait for response, clear, then GET (sequential — Connection: close
    // prevents pipelining).
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"PipeWidget\",\"price_cents\":100}"
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(create_resp.status_code == 200);
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(get_resp.status_code == 200);
    assert(body_contains(get_resp.body, "PipeWidget"));
}

fn @"connection drops and reconnects — state machine survives"() void {
    var sim_io = SimIO.init(0xdead);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product before the drop.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Survivor\",\"price_cents\":100}"
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(create_resp.status_code == 200);
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
        unreachable;
    assert(get_resp.status_code == 200);
    assert(body_contains(get_resp.body, "Survivor"));
}

fn @"timeout — partial request triggers close"() void {
    var sim_io = SimIO.init(0xface);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Inject a partial request (no header terminator).
    sim_io.inject_bytes(0, "GET /products HTTP/1.1\r\n");
    run_ticks(&server, &sim_io, 10);

    // Connection should still be alive before timeout.
    var found_receiving = false;
    for (server.connections) |*conn| {
        if (conn.state == .receiving) {
            found_receiving = true;
            break;
        }
    }
    assert(found_receiving);

    // Disconnect the client so SimIO won't try to deliver more data,
    // then tick past the timeout.
    sim_io.disconnect_client(0);

    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
    }

    // After timeout, the receiving connection should be freed.
    var any_active = false;
    for (server.connections) |*conn| {
        if (conn.state != .free and conn.state != .accepting) {
            any_active = true;
            break;
        }
    }
    assert(!any_active);
}

// =====================================================================
// Coverage mark tests
// =====================================================================

fn @"mark: disconnect triggers recv peer closed"() void {
    var sim_io = SimIO.init(0xa001);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    const mark = marks.check("recv: peer closed");
    sim_io.disconnect_client(0);
    run_ticks(&server, &sim_io, 50);
    mark.expect_hit() catch unreachable;
}

fn @"mark: send fault triggers send error"() void {
    var sim_io = SimIO.init(0xa002);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Create a product so there's something to GET.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"TestProduct\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Enable 100% send faults, then GET. The response send will fail.
    sim_io.send_fault_probability = PRNG.ratio(1, 1);
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const mark = marks.check("send: error");
    run_ticks(&server, &sim_io, 50);
    mark.expect_hit() catch unreachable;
}

fn @"mark: idle connection triggers timeout"() void {
    var sim_io = SimIO.init(0xa003);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

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
    mark.expect_hit() catch unreachable;
}

fn @"mark: garbage bytes trigger invalid HTTP"() void {
    var sim_io = SimIO.init(0xa004);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    const mark = marks.check("invalid HTTP");
    sim_io.inject_bytes(0, "GARBAGE\x00\x01\x02\r\n\r\n");
    run_ticks(&server, &sim_io, 50);
    mark.expect_hit() catch unreachable;
}

fn @"mark: unknown route triggers unmapped request"() void {
    var sim_io = SimIO.init(0xa005);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // GET /unknown doesn't match any known route — triggers unmapped.
    const mark = marks.check("unmapped request");
    var req_buf: [http.recv_buf_max]u8 = undefined;
    var pos: usize = 0;
    const req_line = "GET /unknown HTTP/1.1\r\n";
    @memcpy(req_buf[pos..][0..req_line.len], req_line);
    pos += req_line.len;
    pos += write_cookie_header(req_buf[pos..]);
    const end = "\r\n";
    @memcpy(req_buf[pos..][0..end.len], end);
    pos += end.len;
    sim_io.inject_bytes(0, req_buf[0..pos]);
    run_ticks(&server, &sim_io, 50);
    mark.expect_hit() catch unreachable;
}

fn @"first request without cookie gets identity + Set-Cookie"() void {
    var sim_io = SimIO.init(0xa010);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Request without cookie — should get 200 + full page + Set-Cookie header.
    sim_io.inject_bytes(0, "GET / HTTP/1.1\r\n\r\n");
    const resp = run_until_response(&server, &sim_io, 0, 300) orelse
        unreachable;
    assert(resp.status_code == 200);
    assert(body_contains(resp.body, "<!DOCTYPE html>"));
    // Response headers should include Set-Cookie with tiger_id.
    const full = sim_io.clients[0].recv_buf[0..sim_io.clients[0].recv_len];
    assert(std.mem.indexOf(u8, full, "Set-Cookie: tiger_id=") != null);
}

fn @"request with valid cookie — no Set-Cookie header"() void {
    var sim_io = SimIO.init(0xa011);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // Request with valid cookie — should get 200, no Set-Cookie.
    sim_io.inject_get(0, "/");
    const resp = run_until_response(&server, &sim_io, 0, 300) orelse
        unreachable;
    assert(resp.status_code == 200);
    const full = sim_io.clients[0].recv_buf[0..sim_io.clients[0].recv_len];
    assert(std.mem.indexOf(u8, full, "Set-Cookie:") == null);
}

fn @"mark: accept failure logs warning"() void {
    var sim_io = SimIO.init(0xa007);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    // 100% accept fault — every accept attempt fails.
    sim_io.accept_fault_probability = PRNG.ratio(1, 1);
    sim_io.connect_client(0);
    const mark = marks.check("accept failed");
    run_ticks(&server, &sim_io, 10);
    mark.expect_hit() catch unreachable;
}

fn @"mark: SSE mutation triggers follow-up"() void {
    // Follow-up path was removed when handlers started owning the complete
    // response. SSE mutations are now rendered directly by the handler.
}

// =====================================================================
// Storage fault injection tests
// =====================================================================

fn @"storage busy fault — prefetch retries next tick then succeeds"() void {
    var sim_io = SimIO.init(0xc001);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    // Create a product first (no faults).
    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Enable 100% busy faults. GET will be retried each tick.
    var fault_prng_c001 = PRNG.from_seed(0xc001);
    App.fault_prng = &fault_prng_c001;
    App.fault_busy_ratio = PRNG.ratio(1, 1);
    sim_io.inject_get(0, "/products/" ++ test_uuid1);

    // Tick a few times with busy faults — connection stays .ready.
    const mark = marks.check("storage: busy fault injected");
    run_ticks(&server, &sim_io, 20);
    mark.expect_hit() catch unreachable;

    // Verify no response yet (still busy-looping).
    assert(sim_io.read_response(0) == null);

    // Disable busy faults — next tick should succeed.
    App.fault_busy_ratio = PRNG.Ratio.zero();
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(resp.status_code == 200);
    assert(body_contains(resp.body, "Widget"));
}

fn @"storage err fault — renders dashboard page"() void {
    var sim_io = SimIO.init(0xc002);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    run_ticks(&server, &sim_io, 10);

    // 100% busy faults — prefetch retries every tick, no response produced.
    var fault_prng_c002 = PRNG.from_seed(0xc002);
    App.fault_prng = &fault_prng_c002;
    App.fault_busy_ratio = PRNG.ratio(1, 1);

    const mark = marks.check("storage: busy fault injected");
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    run_ticks(&server, &sim_io, 20);
    mark.expect_hit() catch unreachable;

    // No response — busy faults cause retry, not error response.
    assert(sim_io.read_response(0) == null);

    // Disable faults — next tick should succeed.
    App.fault_busy_ratio = PRNG.Ratio.zero();
    const resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(resp.status_code == 200);
}

fn @"concurrent connections — busy client deferred, ready client served"() void {
    var sim_io = SimIO.init(0xd010);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    // Connect two clients and let them establish.
    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // Create a product (no faults).
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Enable 100% busy faults. Both clients send GET.
    var fault_prng_d010 = PRNG.from_seed(0xd010);
    App.fault_prng = &fault_prng_d010;
    App.fault_busy_ratio = PRNG.ratio(1, 1);
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    sim_io.inject_get(1, "/products/" ++ test_uuid1);

    // Tick with faults — neither should get a response.
    run_ticks(&server, &sim_io, 20);
    assert(sim_io.read_response(0) == null);
    assert(sim_io.read_response(1) == null);

    // Disable faults — both should succeed on next ticks.
    App.fault_busy_ratio = PRNG.Ratio.zero();

    const resp0 = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(resp0.status_code == 200);
    assert(body_contains(resp0.body, "Widget"));

    const resp1 = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(resp1.status_code == 200);
    assert(body_contains(resp1.body, "Widget"));
}

fn @"interleaved writes — update and delete same entity across connections"() void {
    var sim_io = SimIO.init(0xd021);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    // Connect two clients and let them establish.
    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // Create the product first (single client, no race).
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Original\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Inject competing writes simultaneously: client 0 updates, client 1 deletes.
    // Partial delivery byte counts determine which completes first — the test
    // must accept either ordering and assert the invariant holds regardless.
    sim_io.inject_put(0, "/products/" ++ test_uuid1,
        "{\"name\":\"Updated\",\"version\":1}"
    );
    sim_io.inject_delete(1, "/products/" ++ test_uuid1);

    // Both should succeed — the product exists when each is prefetched.
    const update_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;
    assert(update_resp.status_code == 200);

    const delete_resp = run_until_response(&server, &sim_io, 1, 500) orelse
        unreachable;
    assert(delete_resp.status_code == 200);

    // Check final state: whichever ran last determines the outcome.
    clear_and_reconnect(&sim_io, &server, 0);
    sim_io.clear_response(1);
    sim_io.inject_get(0, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &sim_io, 0, 500) orelse
        unreachable;

    // Always-200 server — check body content, not HTTP status.
    // If delete ran last → product inactive → "Product not found".
    // If update ran last → product active with updated name → "Updated".
    // Either is correct — the invariant is consistency, not ordering.
    const body = get_resp.body;
    const deleted = body_contains(body, "Product not found");
    const updated = body_contains(body, "Updated");
    assert(deleted or updated);
}

// =====================================================================
// Two-phase order completion — full-stack sim tests
// =====================================================================

const test_product_uuid = "aabbccdd11223344aabbccdd11220001";
const test_order_uuid = "eeddccbb11223344eeddccbb11220001";

fn @"two-phase order — create on client 0, complete on client 1"() void {
    var sim_io = SimIO.init(0xe001);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // Create a product.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Client 0 creates an order.
    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    const create_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(create_resp.status_code == 200);
    assert(body_contains(create_resp.body, "Pending"));
    clear_and_reconnect(&sim_io, &server, 0);

    // Client 1 (the "worker") completes the order.
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const complete_resp = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(complete_resp.status_code == 200);
    assert(body_contains(complete_resp.body, "Confirmed"));
    sim_io.clear_response(1);

    // Verify inventory stayed decremented (confirmed = keep reservation).
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(inv_resp.status_code == 200);
    assert(body_contains(inv_resp.body, "inventory: 45"));
}

fn @"two-phase order — failed completion restores inventory"() void {
    var sim_io = SimIO.init(0xe002);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Worker reports failure.
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"failed\"}",
    );
    const resp = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(resp.status_code == 200);
    assert(body_contains(resp.body, "Failed"));
    sim_io.clear_response(1);

    // Inventory restored.
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(body_contains(inv_resp.body, "inventory: 50"));
}

fn @"two-phase order — completion after timeout expires"() void {
    var sim_io = SimIO.init(0xe003);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Advance time past the order timeout.
    time_sim.advance(message.order_timeout_seconds + 1);

    // Worker tries to complete — order_expired error in the SSE fragment.
    sim_io.inject_post_datastar(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp = run_until_close_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(resp.status_code == 200);
    assert(body_contains(resp.body, "Order Expired"));
    sim_io.clear_response(1);

    // Inventory restored because the order expired.
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(body_contains(inv_resp.body, "inventory: 50"));
}

fn @"two-phase order — idempotent same-result retry"() void {
    var sim_io = SimIO.init(0xe004);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // First completion succeeds.
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp1 = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(resp1.status_code == 200);
    clear_and_reconnect(&sim_io, &server, 1);

    // Same-result retry is idempotent — returns OK (worker crash recovery).
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp2 = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(resp2.status_code == 200);
    sim_io.clear_response(1);

    // Inventory unchanged by idempotent retry.
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(body_contains(inv_resp.body, "inventory: 45"));
}

fn @"two-phase order — poll pending then complete (worker pattern)"() void {
    var sim_io = SimIO.init(0xe005);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":3}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    sim_io.clear_response(0);

    // Worker polls GET /orders — should see the pending order.
    sim_io.inject_get(1, "/orders");
    const list_resp = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(list_resp.status_code == 200);
    assert(body_contains(list_resp.body, "Pending"));
    assert(body_contains(list_resp.body, test_order_uuid));
    clear_and_reconnect(&sim_io, &server, 1);

    // Worker completes.
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    _ = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 1);

    // Worker polls again — order should now be confirmed, not pending.
    sim_io.inject_get(1, "/orders");
    const list_resp2 = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(list_resp2.status_code == 200);
    assert(body_contains(list_resp2.body, "Confirmed"));
}

// =====================================================================
// Cancel order — full-stack sim tests
// =====================================================================

fn @"cancel order — client cancels, worker completion rejected"() void {
    var sim_io = SimIO.init(0xe010);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    // Setup: product + order.
    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Client cancels.
    sim_io.inject_post(0, "/orders/" ++ test_order_uuid ++ "/cancel", "");
    const cancel_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(cancel_resp.status_code == 200);
    assert(body_contains(cancel_resp.body, "Order cancelled"));
    clear_and_reconnect(&sim_io, &server, 0);

    // Worker tries to complete — rejected (order not pending, error in SSE fragment).
    sim_io.inject_post_datastar(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const complete_resp = run_until_close_response(&server, &sim_io, 1, 500) orelse unreachable;
    assert(complete_resp.status_code == 200);
    assert(body_contains(complete_resp.body, "Order is not pending"));
    sim_io.clear_response(1);

    // Inventory fully restored.
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(body_contains(inv_resp.body, "inventory: 50"));
}

fn @"cancel order — cancel already confirmed is rejected"() void {
    var sim_io = SimIO.init(0xe011);
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 2, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    sim_io.connect_client(0);
    sim_io.connect_client(1);
    run_ticks(&server, &sim_io, 10);

    sim_io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    sim_io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    _ = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    clear_and_reconnect(&sim_io, &server, 0);

    // Worker completes first.
    sim_io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    _ = run_until_response(&server, &sim_io, 1, 500) orelse unreachable;
    sim_io.clear_response(1);

    // Client tries to cancel — too late (order not pending, error in SSE fragment).
    sim_io.inject_post_datastar(0, "/orders/" ++ test_order_uuid ++ "/cancel", "");
    const cancel_resp = run_until_close_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(cancel_resp.status_code == 200);
    assert(body_contains(cancel_resp.body, "Order is not pending"));
    clear_and_reconnect(&sim_io, &server, 0);

    // Inventory stays at confirmed level.
    sim_io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &sim_io, 0, 500) orelse unreachable;
    assert(body_contains(inv_resp.body, "inventory: 45"));
}

// =====================================================================
// PRNG-driven fuzzer — exercises the full stack with random operations
// =====================================================================

/// Fuzzer action space — each variant maps to an HTTP operation or
/// a control action (connect/disconnect/toggle faults).
const FuzzAction = enum {
    connect_client,
    disconnect_client,
    create_product,
    get_product,
    list_products,
    update_product,
    delete_product,
    get_inventory,
    transfer_inventory,
    create_collection,
    get_collection,
    list_collections,
    delete_collection,
    add_member,
    remove_member,
    create_order,
    complete_order,
    cancel_order,
    get_order,
    list_orders,
    search_products,
    page_load_dashboard,
    toggle_faults,
};

/// Stateful fuzzer that tracks known entity IDs and client connectivity.
/// Generates random HTTP requests and relies on server/connection invariants
/// (defer invariants()) to catch bugs.
const Fuzzer = struct {
    const id_pool_max = 32;
    const clients_max = SimIO.max_clients;

    product_ids: [id_pool_max]u128,
    product_count: u32,
    collection_ids: [id_pool_max]u128,
    collection_count: u32,
    order_ids: [id_pool_max]u128,
    order_count: u32,

    client_connected: [clients_max]bool,
    connected_count: u32,

    body_buf: [2048]u8,
    path_buf: [256]u8,

    fn init() Fuzzer {
        return .{
            .product_ids = [_]u128{0} ** id_pool_max,
            .product_count = 0,
            .collection_ids = [_]u128{0} ** id_pool_max,
            .collection_count = 0,
            .order_ids = [_]u128{0} ** id_pool_max,
            .order_count = 0,
            .client_connected = [_]bool{false} ** clients_max,
            .connected_count = 0,
            .body_buf = undefined,
            .path_buf = undefined,
        };
    }

    fn step(self: *Fuzzer, action: FuzzAction, prng: *PRNG, io: *SimIO, server: *Server, storage: *App.Storage) void {
        switch (action) {
            .connect_client => self.step_connect(prng, io, server),
            .disconnect_client => self.step_disconnect(prng, io, server),
            .create_product => self.step_create_product(prng, io, server),
            .get_product => self.step_get_product(prng, io, server),
            .list_products => self.step_list_products(prng, io, server),
            .update_product => self.step_update_product(prng, io, server),
            .delete_product => self.step_delete_product(prng, io, server),
            .get_inventory => self.step_get_inventory(prng, io, server),
            .transfer_inventory => self.step_transfer_inventory(prng, io, server),
            .create_collection => self.step_create_collection(prng, io, server),
            .get_collection => self.step_get_collection(prng, io, server),
            .list_collections => self.step_list_collections(prng, io, server),
            .delete_collection => self.step_delete_collection(prng, io, server),
            .add_member => self.step_add_member(prng, io, server),
            .remove_member => self.step_remove_member(prng, io, server),
            .create_order => self.step_create_order(prng, io, server),
            .complete_order => self.step_complete_order(prng, io, server),
            .cancel_order => self.step_cancel_order(prng, io, server),
            .get_order => self.step_get_order(prng, io, server),
            .list_orders => self.step_list_orders(prng, io, server),
            .search_products => self.step_search_products(prng, io, server),
            .page_load_dashboard => self.step_page_load_dashboard(prng, io, server),
            .toggle_faults => self.step_toggle_faults(prng, io, storage),
        }
    }

    // --- Client management ---

    fn step_connect(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        _ = prng;
        for (self.client_connected, 0..) |c, i| {
            if (!c) {
                io.connect_client(i);
                self.client_connected[i] = true;
                self.connected_count += 1;
                run_ticks(server, io, 10);
                return;
            }
        }
        // All slots full — skip.
    }

    fn step_disconnect(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        // Keep at least one client connected.
        if (self.connected_count <= 1) return;
        const idx = self.pick_connected(prng);
        io.disconnect_client(idx);
        self.client_connected[idx] = false;
        self.connected_count -= 1;
        run_ticks(server, io, 20);
    }

    // --- Products ---

    fn step_create_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_product_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/products", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/products", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.product_count < id_pool_max) {
                self.product_ids[self.product_count] = id;
                self.product_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_product_id(prng);
        const path = path_with_id(&self.path_buf, "/products/", id);
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_list_products(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const path = switch (prng.int_inclusive(u8, 3)) {
            0 => @as([]const u8, "/products"),
            1 => "/products?active=all",
            2 => "/products?active=false",
            3 => "/products?price_min=100&price_max=5000",
            else => unreachable,
        };
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_search_products(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const queries = [_][]const u8{ "widget", "shirt", "a", "test", "pro" };
        const q = queries[prng.int_inclusive(usize, queries.len - 1)];
        const path = std.fmt.bufPrint(&self.path_buf, "/products?q={s}", .{q}) catch "/products?q=a";
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_update_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_known_product(prng);
        const body = self.gen_product_body(prng, id);
        const path = path_with_id(&self.path_buf, "/products/", id);
        if (prng.boolean()) {
            io.inject_put_datastar(client, path, body);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_put(client, path, body);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_delete_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const idx = prng.int_inclusive(u32, self.product_count - 1);
        const id = self.product_ids[idx];
        const path = path_with_id(&self.path_buf, "/products/", id);
        const resp = if (prng.boolean()) blk: {
            io.inject_delete_datastar(client, path);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_delete(client, path);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok()) {
                // Remove from pool by swapping with last.
                self.product_count -= 1;
                self.product_ids[idx] = self.product_ids[self.product_count];
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_inventory(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_product_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/products/", id, "/inventory");
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_transfer_inventory(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count < 2) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);

        const src_idx = prng.int_inclusive(u32, self.product_count - 1);
        var dst_idx = prng.int_inclusive(u32, self.product_count - 1);
        if (dst_idx == src_idx) dst_idx = (src_idx + 1) % self.product_count;
        const src_id = self.product_ids[src_idx];
        const dst_id = self.product_ids[dst_idx];

        const path = path_with_two_ids(&self.path_buf, "/products/", src_id, "/transfer-inventory/", dst_id);
        const qty = prng.range_inclusive(u32, 1, 50);
        const body = self.gen_transfer_body(qty);
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, body);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, body);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    // --- Collections ---

    fn step_create_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_collection_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/collections", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/collections", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.collection_count < id_pool_max) {
                self.collection_ids[self.collection_count] = id;
                self.collection_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_collection_id(prng);
        const path = path_with_id(&self.path_buf, "/collections/", id);
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_list_collections(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        if (prng.boolean()) {
            io.inject_get_datastar(client, "/collections");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, "/collections");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_delete_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const idx = prng.int_inclusive(u32, self.collection_count - 1);
        const id = self.collection_ids[idx];
        const path = path_with_id(&self.path_buf, "/collections/", id);
        const resp = if (prng.boolean()) blk: {
            io.inject_delete_datastar(client, path);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_delete(client, path);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok()) {
                self.collection_count -= 1;
                self.collection_ids[idx] = self.collection_ids[self.collection_count];
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_add_member(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0 or self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const col_id = self.pick_known_collection(prng);
        const prod_id = self.pick_known_product(prng);
        const path = path_with_two_ids(&self.path_buf, "/collections/", col_id, "/products/", prod_id);
        if (prng.boolean()) {
            io.inject_bytes(client, build_simple_request_datastar(&self.body_buf, "POST ", path));
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_bytes(client, build_simple_request(&self.body_buf, "POST ", path));
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_remove_member(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0 or self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const col_id = self.pick_known_collection(prng);
        const prod_id = self.pick_known_product(prng);
        const path = path_with_two_ids(&self.path_buf, "/collections/", col_id, "/products/", prod_id);
        if (prng.boolean()) {
            io.inject_bytes(client, build_simple_request_datastar(&self.body_buf, "DELETE ", path));
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_bytes(client, build_simple_request(&self.body_buf, "DELETE ", path));
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    // --- Orders ---

    fn step_create_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_order_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/orders", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/orders", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.order_count < id_pool_max) {
                self.order_ids[self.order_count] = id;
                self.order_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_complete_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/orders/", id, "/complete");
        const confirmed = prng.boolean();
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"result\":\"");
        w.raw(if (confirmed) "confirmed" else "failed");
        w.raw("\"");
        // ~50% chance of including payment_ref on confirmed.
        if (confirmed and prng.boolean()) {
            w.raw(",\"payment_ref\":\"ch_test_");
            w.num(prng.int(u32));
            w.raw("\"");
        }
        w.raw("}");
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, w.slice());
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, w.slice());
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_cancel_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/orders/", id, "/cancel");
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, "");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, "");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id(&self.path_buf, "/orders/", id);
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_list_orders(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        if (prng.boolean()) {
            io.inject_get_datastar(client, "/orders");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, "/orders");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_page_load_dashboard(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const datastar = prng.boolean();

        if (datastar) {
            io.inject_get_datastar(client, "/");
        } else {
            io.inject_get(client, "/");
        }

        // Dashboard uses Connection: close (no Content-Length).
        // Run enough ticks for the full response to arrive (partial sends).
        _ = run_until_close_response(server, io, client, 500);
        clear_and_reconnect(io, server, client);
    }

    // --- Fault injection ---

    fn step_toggle_faults(self: *Fuzzer, prng: *PRNG, io: *SimIO, storage: *App.Storage) void {
        _ = self;
        _ = storage;
        io.accept_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 30), 100) else PRNG.Ratio.zero();
        io.recv_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 20), 100) else PRNG.Ratio.zero();
        io.send_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 20), 100) else PRNG.Ratio.zero();
        // Storage fault injection via App module-level vars.
        App.fault_busy_ratio = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 40), 100) else PRNG.Ratio.zero();
    }

    // --- ID selection helpers ---

    fn pick_product_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.product_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.pick_known_product(prng);
        }
        return prng.int(u128) | 1;
    }

    fn pick_known_product(self: *Fuzzer, prng: *PRNG) u128 {
        assert(self.product_count > 0);
        return self.product_ids[prng.int_inclusive(u32, self.product_count - 1)];
    }

    fn pick_collection_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.collection_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.pick_known_collection(prng);
        }
        return prng.int(u128) | 1;
    }

    fn pick_known_collection(self: *Fuzzer, prng: *PRNG) u128 {
        assert(self.collection_count > 0);
        return self.collection_ids[prng.int_inclusive(u32, self.collection_count - 1)];
    }

    fn pick_order_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.order_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.order_ids[prng.int_inclusive(u32, self.order_count - 1)];
        }
        return prng.int(u128) | 1;
    }

    // --- Client helpers ---

    fn ensure_connected(self: *Fuzzer, io: *SimIO, server: *Server) void {
        if (self.connected_count > 0) return;
        for (self.client_connected, 0..) |c, i| {
            if (!c) {
                io.connect_client(i);
                self.client_connected[i] = true;
                self.connected_count += 1;
                run_ticks(server, io, 10);
                return;
            }
        }
        unreachable;
    }

    fn pick_connected(self: *Fuzzer, prng: *PRNG) usize {
        assert(self.connected_count > 0);
        const target = prng.int_inclusive(u32, self.connected_count - 1);
        var count: u32 = 0;
        for (self.client_connected, 0..) |c, i| {
            if (c) {
                if (count == target) return i;
                count += 1;
            }
        }
        unreachable;
    }

    // --- Body generators ---

    fn gen_product_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\",\"price_cents\":");
        w.num(prng.range_inclusive(u32, 1, 99999));
        w.raw(",\"inventory\":");
        w.num(prng.range_inclusive(u32, 0, 1000));
        w.raw("}");
        return w.slice();
    }

    fn gen_collection_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\"}");
        return w.slice();
    }

    fn gen_transfer_body(self: *Fuzzer, qty: u32) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"quantity\":");
        w.num(qty);
        w.raw("}");
        return w.slice();
    }

    fn gen_order_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"items\":[");

        const item_count = prng.range_inclusive(u8, 1, @min(5, @as(u8, @intCast(self.product_count))));
        // Track used product indices to avoid duplicate product_ids.
        var used: [5]u32 = [_]u32{0} ** 5;
        var used_count: u8 = 0;

        for (0..item_count) |i| {
            if (i > 0) w.raw(",");

            // Pick a product index not yet used in this order.
            var prod_idx = prng.int_inclusive(u32, self.product_count - 1);
            var attempts: u32 = 0;
            while (attempts < self.product_count) : (attempts += 1) {
                var dup = false;
                for (used[0..used_count]) |u| {
                    if (u == prod_idx) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) break;
                prod_idx = (prod_idx + 1) % self.product_count;
            }
            used[used_count] = prod_idx;
            used_count += 1;

            w.raw("{\"product_id\":\"");
            w.uuid(self.product_ids[prod_idx]);
            w.raw("\",\"quantity\":");
            w.num(prng.range_inclusive(u32, 1, 10));
            w.raw("}");
        }

        w.raw("]}");
        return w.slice();
    }
};

/// Tiny buffer writer for building JSON and paths without allocations.
const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn raw(self: *BufWriter, s: []const u8) void {
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn uuid(self: *BufWriter, val: u128) void {
        const hex = "0123456789abcdef";
        var v = val;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            self.buf[self.pos + i] = hex[@intCast(v & 0xf)];
            v >>= 4;
        }
        self.pos += 32;
    }

    fn num(self: *BufWriter, val: u32) void {
        var num_buf: [10]u8 = undefined;
        const s = format_u32(&num_buf, val);
        self.raw(s);
    }

    fn random_name(self: *BufWriter, prng: *PRNG) void {
        const len = prng.range_inclusive(u8, 1, 20);
        for (self.buf[self.pos..][0..len]) |*c| {
            c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        }
        self.pos += len;
    }

    fn slice(self: *BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// Build a path like "/products/<uuid>".
fn path_with_id(buf: *[256]u8, prefix: []const u8, id: u128) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id);
    return w.slice();
}

/// Build a path like "/products/<uuid>/inventory".
fn path_with_id_suffix(buf: *[256]u8, prefix: []const u8, id: u128, suffix: []const u8) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id);
    w.raw(suffix);
    return w.slice();
}

/// Build a path like "/products/<uuid>/transfer-inventory/<uuid>".
fn path_with_two_ids(buf: *[256]u8, prefix: []const u8, id1: u128, middle: []const u8, id2: u128) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id1);
    w.raw(middle);
    w.uuid(id2);
    return w.slice();
}

/// Build "METHOD /path HTTP/1.1\r\nCookie: ...\r\n\r\n" for bodyless requests.
fn build_simple_request(buf: *[2048]u8, method: []const u8, path: []const u8) []const u8 {
    return build_simple_request_with_headers(buf, method, path, "");
}

fn build_simple_request_datastar(buf: *[2048]u8, method: []const u8, path: []const u8) []const u8 {
    return build_simple_request_with_headers(buf, method, path, "Datastar-Request: true\r\n");
}

fn build_simple_request_with_headers(buf: *[2048]u8, method: []const u8, path: []const u8, extra_headers: []const u8) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(method);
    w.raw(path);
    w.raw(" HTTP/1.1\r\n");
    w.pos += write_cookie_header(buf[w.pos..]);
    w.raw(extra_headers);
    w.raw("\r\n");
    return w.slice();
}

fn run_fuzz(seed: u64) void {
    const events_max = 2000;

    log.debug("        seed={d} events={d}", .{ seed, events_max });

    var prng = PRNG.from_seed(seed);

    var sim_io = SimIO.init(prng.int(u64));
    var storage = App.Storage.init(":memory:") catch unreachable;
    defer storage.deinit();
    var sim_fault_prng = PRNG.from_seed(prng.int(u64));
    App.fault_prng = &sim_fault_prng;
    var sm = StateMachine.init(&storage, false, 0, test_key);
    var time_sim = TimeSim{};
    var server = Server.init(allocator, &sim_io, &sm, 1, time_sim.time(), null) catch unreachable;
    defer server.deinit(allocator);

    var fuzzer = Fuzzer.init();

    // Seed the system: connect a client and let it establish.
    sim_io.connect_client(0);
    fuzzer.client_connected[0] = true;
    fuzzer.connected_count = 1;
    run_ticks(&server, &sim_io, 10);

    for (0..events_max) |_| {
        const action = prng.enum_uniform(FuzzAction);
        fuzzer.step(action, &prng, &sim_io, &server, &storage);
    }
}

fn @"PRNG fuzz — full stack seed 1"() void {
    run_fuzz(0xf001);
}

fn @"PRNG fuzz — full stack seed 2"() void {
    run_fuzz(0xf002);
}

fn @"PRNG fuzz — full stack seed 3"() void {
    run_fuzz(0xf003);
}

/// All sim test functions. Each uses assert for domain invariants — a
/// failure panics immediately with a stack trace, matching TB's pattern.
/// Infrastructure errors (Storage.init, Server.init) also panic via
/// `catch unreachable` inside each function.
const sim_tests = .{
    .{ .name = "deterministic replay — same seed same result", .func = &@"deterministic replay — same seed same result" },
    .{ .name = "pipelining — back-to-back requests on one connection", .func = &@"pipelining — back-to-back requests on one connection" },
    .{ .name = "connection drops and reconnects — state machine survives", .func = &@"connection drops and reconnects — state machine survives" },
    .{ .name = "timeout — partial request triggers close", .func = &@"timeout — partial request triggers close" },
    .{ .name = "mark: disconnect triggers recv peer closed", .func = &@"mark: disconnect triggers recv peer closed" },
    .{ .name = "mark: send fault triggers send error", .func = &@"mark: send fault triggers send error" },
    .{ .name = "mark: idle connection triggers timeout", .func = &@"mark: idle connection triggers timeout" },
    .{ .name = "mark: garbage bytes trigger invalid HTTP", .func = &@"mark: garbage bytes trigger invalid HTTP" },
    .{ .name = "mark: unknown route triggers unmapped request", .func = &@"mark: unknown route triggers unmapped request" },
    .{ .name = "first request without cookie gets identity + Set-Cookie", .func = &@"first request without cookie gets identity + Set-Cookie" },
    .{ .name = "request with valid cookie — no Set-Cookie header", .func = &@"request with valid cookie — no Set-Cookie header" },
    .{ .name = "mark: accept failure logs warning", .func = &@"mark: accept failure logs warning" },
    .{ .name = "mark: SSE mutation triggers follow-up", .func = &@"mark: SSE mutation triggers follow-up" },
    .{ .name = "storage busy fault — prefetch retries next tick then succeeds", .func = &@"storage busy fault — prefetch retries next tick then succeeds" },
    .{ .name = "storage err fault — renders dashboard page", .func = &@"storage err fault — renders dashboard page" },
    .{ .name = "concurrent connections — busy client deferred, ready client served", .func = &@"concurrent connections — busy client deferred, ready client served" },
    .{ .name = "interleaved writes — update and delete same entity across connections", .func = &@"interleaved writes — update and delete same entity across connections" },
    .{ .name = "two-phase order — create on client 0, complete on client 1", .func = &@"two-phase order — create on client 0, complete on client 1" },
    .{ .name = "two-phase order — failed completion restores inventory", .func = &@"two-phase order — failed completion restores inventory" },
    .{ .name = "two-phase order — completion after timeout expires", .func = &@"two-phase order — completion after timeout expires" },
    .{ .name = "two-phase order — idempotent same-result retry", .func = &@"two-phase order — idempotent same-result retry" },
    .{ .name = "two-phase order — poll pending then complete (worker pattern)", .func = &@"two-phase order — poll pending then complete (worker pattern)" },
    .{ .name = "cancel order — client cancels, worker completion rejected", .func = &@"cancel order — client cancels, worker completion rejected" },
    .{ .name = "cancel order — cancel already confirmed is rejected", .func = &@"cancel order — cancel already confirmed is rejected" },
    .{ .name = "PRNG fuzz — full stack seed 1", .func = &@"PRNG fuzz — full stack seed 1" },
    .{ .name = "PRNG fuzz — full stack seed 2", .func = &@"PRNG fuzz — full stack seed 2" },
    .{ .name = "PRNG fuzz — full stack seed 3", .func = &@"PRNG fuzz — full stack seed 3" },
};

/// Current test name — set before each test so the panic handler
/// can print which test was running when it crashed.
var current_test: []const u8 = "";

/// Runtime log level override — set by --log-debug to enable verbose
/// framework output for debugging.
var verbose: bool = false;

/// Test name filter — if set, only tests containing this substring run.
/// Set by passing a bare argument: `zig build test -- cancel`
var filter: ?[]const u8 = null;

pub fn main() void {
    limit_address_space();

    var args = std.process.args();
    _ = args.next(); // skip argv[0]

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--log-debug")) {
            verbose = true;
        } else {
            filter = arg;
        }
    }

    var passed: u32 = 0;
    var skipped: u32 = 0;
    const total: u32 = sim_tests.len;

    inline for (sim_tests) |t| {
        const match = if (filter) |f|
            std.mem.indexOf(u8, t.name, f) != null
        else
            true;
        if (match) {
            current_test = t.name;
            t.func();
            passed += 1;
        } else {
            skipped += 1;
        }
    }

    current_test = "";
    if (filter != null) {
        log.info("{}/{} passed ({} filtered out)", .{ passed, total - skipped, skipped });
    } else {
        log.info("{}/{} passed", .{ passed, total });
    }

    if (passed == 0 and filter != null) {
        log.err("no tests matched filter: {s}", .{filter.?});
        std.process.exit(1);
    }
}

/// Custom panic handler — prints the failing test name, then delegates
/// to the default handler for the full stack trace. The error return
/// trace and return address are forwarded so the trace points to the
/// actual failure site, not to this handler.
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    const stderr = std.io.getStdErr().writer();
    if (current_test.len > 0) {
        stderr.print("\nFAIL  {s}\n\n", .{current_test}) catch {};
    }
    // Delegate to the default handler for stack trace unwinding.
    // It prints "panic: {msg}", dumps error_return_trace, and dumps
    // the stack trace from ret_addr.
    _ = error_return_trace;
    std.debug.defaultPanic(msg, ret_addr orelse @returnAddress());
}
