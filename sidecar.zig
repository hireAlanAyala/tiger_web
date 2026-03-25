//! Unix socket client for the sidecar JSON protocol.
//!
//! Provides the same interface as the Zig-native App functions
//! (translate, execute_render) but delegates to an external process
//! over a unix socket. Blocking IO — called synchronously within
//! the server's request processing tick.
//!
//! New protocol: JSON length-prefixed frames.
//!   1. Route:   send {tag:"route",...} → receive {found, operation, id}
//!   2. Execute: send {tag:"execute",...} → receive {tag:"prefetch_queries",...}
//!              → execute SQL → send {tag:"prefetch_results",...}
//!              → receive {tag:"result", status, writes, html}

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const http = @import("tiger_framework").http;

const log = std.log.scoped(.sidecar);

pub const SidecarClient = struct {
    fd: std.posix.fd_t = -1,
    path: []const u8,

    // Frame buffers — static arrays, reused per request.
    // Single-threaded: one request at a time.
    send_buf: [protocol.frame_max]u8 = undefined,
    recv_buf: [protocol.frame_max + 4]u8 = undefined,

    comptime {
        // Memory budget: two frame buffers allocated once at startup.
        assert(2 * (protocol.frame_max + 4) < 3 * 1024 * 1024);
    }

    fn send_slice(self: *SidecarClient) []u8 {
        return &self.send_buf;
    }

    fn recv_slice(self: *SidecarClient) []u8 {
        return &self.recv_buf;
    }

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

        // 5-second timeout — catches frozen sidecars.
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
    /// Returns null if the sidecar reports unmapped (found=false) or on error.
    pub fn translate(
        self: *SidecarClient,
        method: http.Method,
        path: []const u8,
        body: []const u8,
    ) ?message.Message {
        if (self.fd == -1) self.try_reconnect();
        if (self.fd == -1) return null;

        // Build route request JSON.
        // {tag:"route", method:"GET", path:"/products/abc", body:"...", params:{}}
        // params populated by framework pre-matching — for now empty, sidecar does its own matching.
        var fbs = std.io.fixedBufferStream(self.send_slice());
        const w = fbs.writer();
        w.print("{{\"tag\":\"route\",\"method\":\"{s}\",\"path\":", .{@tagName(method)}) catch return null;
        writeJsonString(w, path) catch return null;
        w.writeAll(",\"body\":") catch return null;
        writeJsonString(w, body) catch return null;
        w.writeAll(",\"params\":{}}}") catch return null;

        const json = fbs.getWritten();
        if (!protocol.write_frame(self.fd, json)) {
            self.handle_disconnect();
            return null;
        }

        // Read route response.
        const resp_json = protocol.read_frame(self.fd, self.recv_slice()) orelse {
            self.handle_disconnect();
            return null;
        };

        // Parse response — check found field.
        const found_val = extractJsonValue(resp_json, "found") orelse return null;
        if (!std.mem.eql(u8, found_val, "true")) return null;

        // Extract operation.
        const op_str = extractJsonString(resp_json, "operation") orelse {
            log.err("route response missing operation field", .{});
            self.handle_disconnect();
            return null;
        };

        const operation = message.Operation.from_string(op_str) orelse {
            log.err("route handler returned unknown operation: {s}", .{op_str});
            self.handle_disconnect();
            return null;
        };

        // Extract id.
        const id_str = extractJsonString(resp_json, "id") orelse "0" ** 32;
        const id = parseHexUuid(id_str) orelse 0;

        var msg = std.mem.zeroes(message.Message);
        msg.operation = operation;
        msg.id = id;
        // Body from route result stored as JSON in msg body — the sidecar
        // will receive it back in the execute phase. For now, keep the
        // raw body_json in the Message body field by writing it as bytes.
        if (extractJsonValue(resp_json, "body")) |body_json| {
            const copy_len = @min(body_json.len, message.body_max);
            @memcpy(msg.body[0..copy_len], body_json[0..copy_len]);
        }
        return msg;
    }

    /// Execute via the sidecar: prefetch → handle → render.
    /// Pending binary protocol rebuild — see docs/plans/sidecar-protocol.md.
    pub fn execute_render() void {
        @compileError("sidecar execute_render pending binary protocol rebuild");
    }

    fn handle_disconnect(self: *SidecarClient) void {
        assert(self.fd != -1);
        log.warn("sidecar disconnected", .{});
        std.posix.close(self.fd);
        self.fd = -1;
    }

    fn try_reconnect(self: *SidecarClient) void {
        assert(self.fd == -1);
        if (self.connect()) {
            log.info("sidecar reconnected", .{});
        }
    }
};

// ExecuteRenderResult removed — pending binary protocol rebuild.
// See docs/plans/sidecar-protocol.md.

// =====================================================================
// JSON helpers — minimal, no allocator. Parse from recv_buf slices.
// These are boundary code — the sidecar is untrusted.
// =====================================================================

/// Write a JSON string (with escaping) to the writer.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Extract a JSON string value by key. Returns the raw content (escapes preserved).
/// Simple parser — handles flat JSON objects, not nested.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"value"
    var search_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const start = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;
    // Find closing quote (not escaped).
    var i = start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '\\') {
            i += 1; // skip escaped char
            continue;
        }
        if (json[i] == '"') return json[start..i];
    }
    return null;
}

/// Extract a JSON value by key — returns the raw JSON (string, object, array, number, bool).
fn extractJsonValue(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const colon_end = (std.mem.indexOf(u8, json, prefix) orelse return null) + prefix.len;

    // Skip whitespace.
    var i = colon_end;
    while (i < json.len and (json[i] == ' ' or json[i] == '\t')) i += 1;
    if (i >= json.len) return null;

    // Determine value type and find end.
    const c = json[i];
    if (c == '"') {
        // String: find closing quote.
        var j = i + 1;
        while (j < json.len) : (j += 1) {
            if (json[j] == '\\') {
                j += 1;
                continue;
            }
            if (json[j] == '"') return json[i .. j + 1];
        }
        return null;
    } else if (c == '{') {
        return findMatchingBrace(json[i..], '{', '}');
    } else if (c == '[') {
        return findMatchingBrace(json[i..], '[', ']');
    } else {
        // Number, bool, null — find delimiter.
        var j = i;
        while (j < json.len and json[j] != ',' and json[j] != '}' and json[j] != ']') j += 1;
        return json[i..j];
    }
}

fn findMatchingBrace(s: []const u8, open: u8, close_char: u8) ?[]const u8 {
    assert(s[0] == open);
    var depth: usize = 0;
    var in_string = false;
    var escape_next = false;
    for (s, 0..) |c, i| {
        if (escape_next) {
            escape_next = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escape_next = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == open) depth += 1;
        if (c == close_char) {
            depth -= 1;
            if (depth == 0) return s[0 .. i + 1];
        }
    }
    return null;
}

// JsonObjectIterator removed — was only used by deleted execute_render.

fn parseHexUuid(s: []const u8) ?u128 {
    if (s.len != 32) return null;
    var result: u128 = 0;
    for (s) |c| {
        const digit: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return null,
        };
        result = (result << 4) | digit;
    }
    return result;
}

// =====================================================================
// Tests
// =====================================================================

test "extractJsonString" {
    const json = "{\"operation\":\"get_product\",\"id\":\"abcdef\",\"found\":true}";
    try std.testing.expectEqualStrings("get_product", extractJsonString(json, "operation").?);
    try std.testing.expectEqualStrings("abcdef", extractJsonString(json, "id").?);
    try std.testing.expect(extractJsonString(json, "missing") == null);
}

test "extractJsonValue" {
    const json = "{\"found\":true,\"count\":42,\"items\":[1,2,3],\"obj\":{\"a\":1}}";
    try std.testing.expectEqualStrings("true", extractJsonValue(json, "found").?);
    try std.testing.expectEqualStrings("42", extractJsonValue(json, "count").?);
    try std.testing.expectEqualStrings("[1,2,3]", extractJsonValue(json, "items").?);
    try std.testing.expectEqualStrings("{\"a\":1}", extractJsonValue(json, "obj").?);
}

test "parseHexUuid" {
    try std.testing.expectEqual(@as(u128, 0xaabbccdd), parseHexUuid("000000000000000000000000aabbccdd").?);
    try std.testing.expect(parseHexUuid("short") == null);
    try std.testing.expect(parseHexUuid("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz") == null);
}

test "writeJsonString escapes" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try writeJsonString(fbs.writer(), "hello \"world\"\n");
    try std.testing.expectEqualStrings("\"hello \\\"world\\\"\\n\"", fbs.getWritten());
}

test "findMatchingBrace with escaped quotes" {
    // Object containing a string with escaped quotes.
    const json = "{\"name\":\"say \\\"hi\\\"\",\"id\":1}";
    const result = findMatchingBrace(json, '{', '}');
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(json, result.?);
}

test "findMatchingBrace with nested braces in strings" {
    const json = "{\"val\":\"{}\",\"ok\":true}";
    const result = findMatchingBrace(json, '{', '}');
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(json, result.?);
}

test "extractJsonString with escaped value" {
    const json = "{\"name\":\"say \\\"hi\\\"\"}";
    const val = extractJsonString(json, "name");
    try std.testing.expect(val != null);
    // Returns raw content — escapes preserved.
    try std.testing.expectEqualStrings("say \\\"hi\\\"", val.?);
}

test "extractJsonValue nested key collision" {
    // "a" appears in both outer and inner objects.
    const json = "{\"a\":{\"a\":1},\"b\":2}";
    const a_val = extractJsonValue(json, "a");
    try std.testing.expect(a_val != null);
    try std.testing.expectEqualStrings("{\"a\":1}", a_val.?);
    const b_val = extractJsonValue(json, "b");
    try std.testing.expect(b_val != null);
    try std.testing.expectEqualStrings("2", b_val.?);
}

// JsonObjectIterator tests removed — iterator deleted.
