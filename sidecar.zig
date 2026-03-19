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

        if (resp.found == 0) return null;
        assert(resp.found == 1);

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

    // --- IO helpers ---

    fn send_all(self: *SidecarClient, bytes: []const u8) bool {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const n = std.posix.send(self.fd, bytes[sent..], std.posix.MSG.NOSIGNAL) catch {
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
            const n = std.posix.recv(self.fd, buf[recvd..], 0) catch {
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
