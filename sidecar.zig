//! Unix socket client for the sidecar protocol.
//!
//! Provides the same interface as the Zig-native App functions
//! (translate, execute_render) but delegates to an external process
//! over a unix socket. Blocking IO — called synchronously within
//! the server's request processing tick.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const SM = state_machine.StateMachineType(state_machine.MemoryStorage);
const http = @import("tiger_framework").http;

const log = std.log.scoped(.sidecar);

pub const SidecarClient = struct {
    fd: std.posix.fd_t = -1,
    path: []const u8,

    /// Connect to the sidecar unix socket. Returns false on failure.
    pub fn connect(self: *SidecarClient) bool {
        assert(self.fd == -1);
        assert(self.path.len > 0);

        const fd = std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0) catch |err| {
            log.warn("socket: {}", .{err});
            return false;
        };

        var addr: std.posix.sockaddr.un = .{ .path = undefined };
        assert(self.path.len < addr.path.len);
        @memcpy(addr.path[0..self.path.len], self.path);
        addr.path[self.path.len] = 0;

        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un)) catch |err| {
            log.warn("connect: {}", .{err});
            std.posix.close(fd);
            return false;
        };

        // Pure handlers should complete in microseconds. A 5-second timeout
        // catches frozen sidecars (infinite loops, GC pauses) without blocking
        // the single thread forever.
        const timeout: std.posix.timeval = .{ .sec = 5, .usec = 0 };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt RCVTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };
        std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch |err| {
            log.warn("setsockopt SNDTIMEO: {}", .{err});
            std.posix.close(fd);
            return false;
        };

        self.fd = fd;
        log.info("connected to {s}", .{self.path});
        return true;
    }

    /// Close the connection.
    pub fn close(self: *SidecarClient) void {
        if (self.fd != -1) {
            std.posix.close(self.fd);
            self.fd = -1;
        }
    }

    /// Translate an HTTP request into a typed Message via the sidecar.
    /// Returns null if the sidecar reports unmapped (found=0) or on error.
    pub fn translate(
        self: *SidecarClient,
        method: http.Method,
        path: []const u8,
        body: []const u8,
    ) ?message.Message {
        if (self.fd == -1) self.try_reconnect();
        if (self.fd == -1) return null;

        assert(path.len <= protocol.path_max);
        assert(body.len <= protocol.json_body_max);

        var req = std.mem.zeroes(protocol.TranslateRequest);
        req.tag = .translate;
        req.method = map_method(method);
        req.path_len = @intCast(path.len);
        req.body_len = @intCast(body.len);
        @memcpy(req.path[0..path.len], path);
        @memcpy(req.body[0..body.len], body);

        if (!self.send_all(std.mem.asBytes(&req))) {
            self.handle_disconnect();
            return null;
        }

        var resp: protocol.TranslateResponse = undefined;
        if (!self.recv_all(std.mem.asBytes(&resp))) {
            self.handle_disconnect();
            return null;
        }

        if (resp.found != 1) return null;

        // Validate the operation is a known enum value — catches
        // corrupted responses before the value propagates.
        _ = std.meta.intToEnum(message.Operation, @intFromEnum(resp.operation)) catch {
            log.warn("invalid operation in translate response: {d}", .{@intFromEnum(resp.operation)});
            self.handle_disconnect();
            return null;
        };

        var msg = std.mem.zeroes(message.Message);
        msg.operation = resp.operation;
        msg.id = resp.id;
        @memcpy(&msg.body, &resp.body);
        return msg;
    }

    /// Execute + render via the sidecar. Sends the prefetch cache and
    /// receives status, writes, and HTML into `resp_buf`. Returns false
    /// on socket error. The caller provides the response buffer because
    /// ExecuteRenderResponse is ~200KB — too large for the stack.
    pub fn execute_render(
        self: *SidecarClient,
        operation: message.Operation,
        id: u128,
        body: *const [message.body_max]u8,
        cache: *const protocol.PrefetchCache,
        is_sse: bool,
        resp_buf: *protocol.ExecuteRenderResponse,
    ) bool {
        if (self.fd == -1) self.try_reconnect();
        if (self.fd == -1) return false;

        var req = std.mem.zeroes(protocol.ExecuteRenderRequest);
        req.tag = .execute_render;
        req.operation = operation;
        req.id = id;
        req.is_sse = @intFromBool(is_sse);
        @memcpy(&req.body, body);
        req.cache = cache.*;

        if (!self.send_all(std.mem.asBytes(&req))) {
            self.handle_disconnect();
            return false;
        }

        if (!self.recv_all(std.mem.asBytes(resp_buf))) {
            self.handle_disconnect();
            return false;
        }

        // Validate response fields at the boundary.
        // These are untrusted sidecar values — validate, don't assert.
        _ = std.meta.intToEnum(message.Status, @intFromEnum(resp_buf.status)) catch {
            log.warn("invalid status in execute_render response: {d}", .{@intFromEnum(resp_buf.status)});
            self.handle_disconnect();
            return false;
        };
        if (resp_buf.writes_len > SM.writes_max) {
            log.warn("invalid writes_len in execute_render response: {d}", .{resp_buf.writes_len});
            self.handle_disconnect();
            return false;
        }
        if (resp_buf.html_len > protocol.html_max) {
            log.warn("invalid html_len in execute_render response: {d}", .{resp_buf.html_len});
            self.handle_disconnect();
            return false;
        }

        return true;
    }

    // --- IO helpers ---

    fn send_all(self: *SidecarClient, bytes: []const u8) bool {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = std.posix.send(self.fd, bytes[sent..], std.posix.MSG.NOSIGNAL) catch |err| {
                if (err == error.WouldBlock) {
                    log.err("sidecar send timed out — handler is not pure or sidecar is frozen", .{});
                }
                return false;
            };
            if (n == 0) return false;
            sent += n;
        }
        return true;
    }

    fn recv_all(self: *SidecarClient, buf: []u8) bool {
        var recvd: usize = 0;
        while (recvd < buf.len) {
            const n = std.posix.recv(self.fd, buf[recvd..], 0) catch |err| {
                if (err == error.WouldBlock) {
                    log.err("sidecar recv timed out — handler is not pure or sidecar is frozen", .{});
                }
                return false;
            };
            if (n == 0) return false; // peer closed
            recvd += n;
        }
        return true;
    }

    fn handle_disconnect(self: *SidecarClient) void {
        log.warn("sidecar disconnected", .{});
        self.close();
    }

    /// Attempt to reconnect after a disconnect. Called lazily on the next
    /// request — no background polling, no retry loops. If the sidecar
    /// restarted, this picks it up. If not, the request falls through to
    /// native rendering (execute_render) or unmapped (translate).
    fn try_reconnect(self: *SidecarClient) void {
        assert(self.fd == -1);
        if (self.connect()) {
            log.info("sidecar reconnected", .{});
        }
    }
};

fn map_method(method: http.Method) protocol.Method {
    return switch (method) {
        .get => .get,
        .post => .post,
        .put => .put,
        .delete => .delete,
    };
}

// =====================================================================
// Tests
// =====================================================================

test "translate round trip via socketpair" {
    const pair = test_socketpair();
    // Client owns pair[0] — close via client.close(), not defer.

    const thread = try std.Thread.spawn(.{}, mock_translate_echo, .{pair[1]});

    var client = SidecarClient{ .path = "/unused", .fd = pair[0] };
    const result = client.translate(.get, "/products/abc123", "");

    thread.join();
    client.close();

    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.operation, .get_product);
    try std.testing.expectEqual(result.?.id, 0xaabbccdd11223344aabbccdd11223344);
}

test "translate returns null for unmapped" {
    const pair = test_socketpair();

    const thread = try std.Thread.spawn(.{}, mock_translate_not_found, .{pair[1]});

    var client = SidecarClient{ .path = "/unused", .fd = pair[0] };
    const result = client.translate(.get, "/nonexistent", "");

    thread.join();
    client.close();

    try std.testing.expect(result == null);
}

test "translate returns null on disconnect" {
    const pair = test_socketpair();
    // Client owns pair[0] — handle_disconnect closes it on failure.

    std.posix.close(pair[1]);

    var client = SidecarClient{ .path = "/unused", .fd = pair[0] };
    const result = client.translate(.get, "/products", "");

    try std.testing.expect(result == null);
    try std.testing.expectEqual(client.fd, -1);
}

test "execute_render round trip via socketpair" {
    const pair = test_socketpair();

    const thread = try std.Thread.spawn(.{}, mock_execute_render, .{pair[1]});

    var client = SidecarClient{ .path = "/unused", .fd = pair[0] };
    var cache = std.mem.zeroes(protocol.PrefetchCache);
    cache.has_product = 1;
    cache.product = std.mem.zeroes(message.Product);
    cache.product.id = 0xaabbccdd11223344aabbccdd11223344;

    var body = std.mem.zeroes([message.body_max]u8);

    // Heap-allocate — ExecuteRenderResponse is ~200KB, too large for the stack.
    const resp_buf = try std.testing.allocator.create(protocol.ExecuteRenderResponse);
    defer std.testing.allocator.destroy(resp_buf);

    const ok = client.execute_render(.get_product, cache.product.id, &body, &cache, false, resp_buf);

    thread.join();
    client.close();

    try std.testing.expect(ok);
    try std.testing.expectEqual(resp_buf.status, .ok);
    try std.testing.expectEqual(resp_buf.writes_len, 0);
    try std.testing.expect(resp_buf.html_len > 0);
    try std.testing.expect(resp_buf.html_len <= protocol.html_max);
    const html = resp_buf.html[0..resp_buf.html_len];
    try std.testing.expect(std.mem.startsWith(u8, html, "<div"));
}

test "reconnect after disconnect — succeeds when sidecar restarts" {
    // Start a mock listener on a temp unix socket.
    const sock_path = "/tmp/tiger-sidecar-test.sock";
    std.fs.cwd().deleteFile(sock_path) catch {};

    const listener = try listen_unix(sock_path);
    defer std.posix.close(listener);
    defer std.fs.cwd().deleteFile(sock_path) catch {};

    var client = SidecarClient{ .path = sock_path };

    // First connection.
    try std.testing.expect(client.connect());
    const accepted1 = try std.posix.accept(listener, null, null, 0);

    // Simulate sidecar crash — close the accepted connection.
    std.posix.close(accepted1);

    // Client's next translate fails (peer closed), triggers disconnect.
    const result1 = client.translate(.get, "/products", "");
    try std.testing.expect(result1 == null);
    try std.testing.expectEqual(client.fd, -1);

    // Next translate triggers reconnect — listener is still up, so connect succeeds.
    // Spawn a mock thread to accept and respond.
    const thread = try std.Thread.spawn(.{}, mock_accept_and_respond, .{listener});
    const result2 = client.translate(.get, "/products/abc123", "");
    thread.join();

    try std.testing.expect(result2 != null);
    try std.testing.expectEqual(result2.?.operation, .get_product);
    try std.testing.expect(client.fd != -1);
    client.close();
}

test "reconnect after disconnect — fails when sidecar is down" {
    var client = SidecarClient{ .path = "/tmp/tiger-sidecar-nonexistent.sock" };
    // Simulate a previous connection that disconnected.
    // fd is -1 (no previous fd to leak), path points to nonexistent socket.
    try std.testing.expectEqual(client.fd, -1);

    // translate should try reconnect, fail, return null.
    const result = client.translate(.get, "/products", "");
    try std.testing.expect(result == null);
    try std.testing.expectEqual(client.fd, -1);
}

test "multiple disconnect-reconnect cycles" {
    const sock_path = "/tmp/tiger-sidecar-cycle.sock";
    std.fs.cwd().deleteFile(sock_path) catch {};

    const listener = try listen_unix(sock_path);
    defer std.posix.close(listener);
    defer std.fs.cwd().deleteFile(sock_path) catch {};

    var client = SidecarClient{ .path = sock_path };

    for (0..3) |_| {
        // Connect.
        try std.testing.expect(client.connect());
        const accepted = try std.posix.accept(listener, null, null, 0);

        // Crash — close server side.
        std.posix.close(accepted);

        // Client detects disconnect.
        const result = client.translate(.get, "/products", "");
        try std.testing.expect(result == null);
        try std.testing.expectEqual(client.fd, -1);
    }

    // Final reconnect with a real response.
    const thread = try std.Thread.spawn(.{}, mock_accept_and_respond, .{listener});
    const result = client.translate(.get, "/products/abc123", "");
    thread.join();

    try std.testing.expect(result != null);
    try std.testing.expectEqual(result.?.operation, .get_product);
    client.close();
}

fn mock_accept_and_respond(listener: std.posix.fd_t) void {
    const fd = std.posix.accept(listener, null, null, 0) catch return;
    defer std.posix.close(fd);

    var req_bytes: [@sizeOf(protocol.TranslateRequest)]u8 = undefined;
    recv_test(fd, &req_bytes);

    var resp = std.mem.zeroes(protocol.TranslateResponse);
    resp.found = 1;
    resp.operation = .get_product;
    resp.id = 0x11223344;
    send_test(fd, std.mem.asBytes(&resp));
}

fn listen_unix(path: []const u8) !std.posix.fd_t {
    const fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    var addr: std.posix.sockaddr.un = .{ .path = undefined };
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.un));
    try std.posix.listen(fd, 5);
    return fd;
}

// --- Mock sidecar threads ---

fn mock_translate_echo(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    var req_bytes: [@sizeOf(protocol.TranslateRequest)]u8 = undefined;
    recv_test(fd, &req_bytes);

    const req: *const protocol.TranslateRequest = @ptrCast(@alignCast(&req_bytes));
    // Assert the full request — tag, method, path, body.
    assert(req.tag == .translate);
    assert(req.method == .get);
    assert(req.path_len == 16);
    assert(std.mem.eql(u8, req.path[0..req.path_len], "/products/abc123"));
    assert(req.body_len == 0);

    var resp = std.mem.zeroes(protocol.TranslateResponse);
    resp.found = 1;
    resp.operation = .get_product;
    resp.id = 0xaabbccdd11223344aabbccdd11223344;
    send_test(fd, std.mem.asBytes(&resp));
}

fn mock_translate_not_found(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    var req_bytes: [@sizeOf(protocol.TranslateRequest)]u8 = undefined;
    recv_test(fd, &req_bytes);

    const req: *const protocol.TranslateRequest = @ptrCast(@alignCast(&req_bytes));
    assert(req.tag == .translate);
    assert(req.method == .get);
    assert(req.path_len == 12);
    assert(std.mem.eql(u8, req.path[0..req.path_len], "/nonexistent"));
    assert(req.body_len == 0);

    var resp = std.mem.zeroes(protocol.TranslateResponse);
    resp.found = 0;
    send_test(fd, std.mem.asBytes(&resp));
}

fn mock_execute_render(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    // Heap-allocate — request (~66KB) and response (~200KB) are too large for thread stack.
    const req_bytes = std.testing.allocator.alignedAlloc(
        u8,
        @alignOf(protocol.ExecuteRenderRequest),
        @sizeOf(protocol.ExecuteRenderRequest),
    ) catch unreachable;
    defer std.testing.allocator.free(req_bytes);
    recv_test(fd, req_bytes);

    const req: *const protocol.ExecuteRenderRequest = @ptrCast(@alignCast(req_bytes.ptr));
    assert(req.tag == .execute_render);
    assert(req.operation == .get_product);
    assert(req.is_sse == 0);
    assert(req.cache.has_product == 1);
    assert(req.cache.product.id == 0xaabbccdd11223344aabbccdd11223344);

    const resp = std.testing.allocator.create(protocol.ExecuteRenderResponse) catch unreachable;
    defer std.testing.allocator.destroy(resp);
    resp.* = std.mem.zeroes(protocol.ExecuteRenderResponse);
    resp.status = .ok;
    resp.writes_len = 0;
    const html = "<div>Product Detail</div>";
    @memcpy(resp.html[0..html.len], html);
    resp.html_len = html.len;

    send_test(fd, std.mem.asBytes(resp));
}

fn test_socketpair() [2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    assert(rc == 0);
    return fds;
}

fn send_test(fd: std.posix.fd_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += std.posix.write(fd, bytes[sent..]) catch unreachable;
    }
}

fn recv_test(fd: std.posix.fd_t, buf: []u8) void {
    var recvd: usize = 0;
    while (recvd < buf.len) {
        const n = std.posix.read(fd, buf[recvd..]) catch unreachable;
        assert(n > 0);
        recvd += n;
    }
}
