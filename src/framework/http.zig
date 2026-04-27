const std = @import("std");
const assert = std.debug.assert;
const auth = @import("auth.zig");

/// Maximum HTTP header size. Requests with headers exceeding this are rejected.
pub const max_header_size = 8192;

/// Maximum incoming request body size.
pub const body_max = 4096;

/// Maximum total recv buffer: HTTP headers + body.
pub const recv_buf_max = max_header_size + body_max;

/// Maximum send buffer: HTTP response headers + body.
/// Sized for paginated list responses (list_max=18 worst-case product cards).
/// Benchmarked: 256KB→64KB = +38% throughput, -60% memory at 128 connections.
/// 32KB was 9% faster but halves list_max to 9 — not worth the tradeoff.
/// See docs/internal/decision-send-buffer-size.md.
pub const send_buf_max = 64 * 1024;

pub const ParseResult = union(enum) {
    /// Not enough bytes to parse a complete request.
    incomplete,
    /// Malformed HTTP — connection should be closed.
    invalid,
    /// A complete HTTP request was parsed.
    complete: struct {
        method: Method,
        /// Raw path from the request line (points into buf). Includes leading /.
        path: []const u8,
        /// Body bytes (points into buf). Empty for GET/DELETE.
        body: []const u8,
        /// Total bytes consumed from the buffer.
        total_len: u32,
        /// Whether the client wants to keep the connection alive.
        /// HTTP/1.1 defaults to true, HTTP/1.0 defaults to false.
        keep_alive: bool,
        /// Identity cookie value, or null if absent.
        /// Points into buf — valid only while buf is live.
        identity_cookie: ?[]const u8,
        /// Whether the client sent Datastar-Request: true.
        is_datastar_request: bool,
    },
};

pub const Method = enum {
    get,
    put,
    post,
    delete,
};

/// Parse an HTTP/1.1 request from a buffer. The buffer may contain a partial
/// request (returns .incomplete) or a malformed one (returns .invalid).
///
/// Only extracts what we need: method, path, Content-Length, and body.
/// All other headers are ignored.
pub fn parse_request(buf: []const u8) ParseResult {
    // Find end of headers.
    const header_end = find_header_end(buf) orelse {
        // No \r\n\r\n found yet.
        if (buf.len >= max_header_size) return .invalid;
        return .incomplete;
    };

    // Include the trailing \r\n before the blank line so header lines
    // are properly terminated for parsing.
    const headers = buf[0 .. header_end + 2];

    // Parse request line: "METHOD /path HTTP/1.1\r\n"
    const request_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return .invalid;
    const request_line = headers[0..request_line_end];

    // Extract method.
    const method_end = std.mem.indexOf(u8, request_line, " ") orelse return .invalid;
    const method = parse_method(request_line[0..method_end]) orelse return .invalid;

    // Extract path (between first and second space).
    const after_method = request_line[method_end + 1 ..];
    const path_end = std.mem.indexOf(u8, after_method, " ") orelse return .invalid;
    const raw_path = after_method[0..path_end];
    if (raw_path.len == 0) return .invalid;

    // Parse HTTP version from the remainder of the request line.
    const version_str = after_method[path_end + 1 ..];
    const is_http10 = std.mem.eql(u8, version_str, "HTTP/1.0");

    // Determine keep_alive based on HTTP version and Connection header.
    const keep_alive = blk: {
        const conn_value = find_header_value(headers, "Connection");
        if (conn_value) |val| {
            if (ascii_eql_ignore_case(val, "close")) break :blk false;
            if (ascii_eql_ignore_case(val, "keep-alive")) break :blk true;
        }
        // Default: HTTP/1.1 keeps alive, HTTP/1.0 does not.
        break :blk !is_http10;
    };

    // Parse Content-Length from headers.
    const content_length = find_content_length(headers) orelse 0;

    // Validate method/body constraints.
    switch (method) {
        .get, .delete => {
            if (content_length != 0) return .invalid;
        },
        .put => {
            if (content_length == 0) return .invalid;
            if (content_length > body_max) return .invalid;
        },
        .post => {
            // POST may have no body (e.g., action endpoints with IDs in URL).
            if (content_length > body_max) return .invalid;
        },
    }

    // Check if full body has arrived.
    const body_start = header_end + 4; // past \r\n\r\n
    const total_len = body_start + content_length;
    if (buf.len < total_len) return .incomplete;

    const body = if (content_length > 0) buf[body_start..total_len] else &[_]u8{};

    // Extract identity cookie value (if present).
    const identity_cookie = blk: {
        const cookie_value = find_header_value(headers, "Cookie") orelse break :blk null;
        const needle = auth.cookie_name ++ "=";
        const needle_pos = std.mem.indexOf(u8, cookie_value, needle) orelse break :blk null;
        const val_start = needle_pos + needle.len;
        const remaining = cookie_value[val_start..];
        // Value extends to ';' or end of string.
        const val_end = std.mem.indexOf(u8, remaining, ";") orelse remaining.len;
        // Trim trailing whitespace.
        var end = val_end;
        while (end > 0 and remaining[end - 1] == ' ') end -= 1;
        if (end == 0) break :blk null;
        break :blk remaining[0..end];
    };

    // Detect Datastar-Request: true header.
    const is_datastar_request = blk: {
        const val = find_header_value(headers, "Datastar-Request") orelse break :blk false;
        break :blk ascii_eql_ignore_case(val, "true");
    };

    return .{ .complete = .{
        .method = method,
        .path = raw_path,
        .body = body,
        .total_len = @intCast(total_len),
        .keep_alive = keep_alive,
        .identity_cookie = identity_cookie,
        .is_datastar_request = is_datastar_request,
    } };
}

// --- Internal helpers ---

fn find_header_end(buf: []const u8) ?usize {
    if (buf.len < 4) return null;
    for (0..buf.len - 3) |i| {
        if (buf[i] == '\r' and buf[i + 1] == '\n' and buf[i + 2] == '\r' and buf[i + 3] == '\n') {
            return i;
        }
    }
    return null;
}

fn parse_method(s: []const u8) ?Method {
    if (std.mem.eql(u8, s, "GET")) return .get;
    if (std.mem.eql(u8, s, "PUT")) return .put;
    if (std.mem.eql(u8, s, "POST")) return .post;
    if (std.mem.eql(u8, s, "DELETE")) return .delete;
    return null;
}

/// Find a header's value by name (case-insensitive).
/// Returns the trimmed value or null if the header is not present.
fn find_header_value(headers: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = std.mem.indexOf(u8, headers[pos..], "\r\n") orelse break;
        const line = headers[pos..][0..line_end];
        pos += line_end + 2;

        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        const hdr_name = line[0..colon];

        if (hdr_name.len != name.len) continue;
        if (!ascii_eql_ignore_case(hdr_name, name)) continue;

        // Trim leading whitespace from value.
        var val = line[colon + 1 ..];
        while (val.len > 0 and val[0] == ' ') val = val[1..];
        return val;
    }
    return null;
}

fn find_content_length(headers: []const u8) ?u32 {
    const val = find_header_value(headers, "Content-Length") orelse return null;
    return std.fmt.parseInt(u32, val, 10) catch return null;
}

fn ascii_eql_ignore_case(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
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

// =====================================================================
// Tests
// =====================================================================

test "parse complete GET request" {
    const req = "GET /hello HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    const r = result.complete;
    try std.testing.expectEqual(r.method, .get);
    try std.testing.expectEqualSlices(u8, r.path, "/hello");
    try std.testing.expectEqual(r.body.len, 0);
    try std.testing.expectEqual(r.total_len, @as(u32, @intCast(req.len)));
}

test "parse complete PUT request with body" {
    const req = "PUT /key HTTP/1.1\r\nContent-Length: 5\r\n\r\nworld";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    const r = result.complete;
    try std.testing.expectEqual(r.method, .put);
    try std.testing.expectEqualSlices(u8, r.path, "/key");
    try std.testing.expectEqualSlices(u8, r.body, "world");
}

test "parse complete POST request" {
    const req = "POST /items HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqual(result.complete.method, .post);
    try std.testing.expectEqualSlices(u8, result.complete.body, "abc");
}

test "parse DELETE request" {
    const req = "DELETE /key HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqual(result.complete.method, .delete);
}

test "incomplete — no header end" {
    const result = parse_request("GET /hello HTTP/1.1\r\n");
    try std.testing.expect(result == .incomplete);
}

test "incomplete — body not fully received" {
    const result = parse_request("PUT /key HTTP/1.1\r\nContent-Length: 10\r\n\r\nhell");
    try std.testing.expect(result == .incomplete);
}

test "invalid — unknown method" {
    const result = parse_request("PATCH /key HTTP/1.1\r\n\r\n");
    try std.testing.expect(result == .invalid);
}

test "invalid — GET with Content-Length" {
    const result = parse_request("GET /key HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello");
    try std.testing.expect(result == .invalid);
}

test "invalid — PUT without Content-Length" {
    const result = parse_request("PUT /key HTTP/1.1\r\n\r\n");
    try std.testing.expect(result == .invalid);
}

test "invalid — headers too large" {
    // Build a request with headers > max_header_size.
    var big_header: [max_header_size + 100]u8 = undefined;
    @memset(&big_header, 'X');
    big_header[0] = 'G';
    big_header[1] = 'E';
    big_header[2] = 'T';
    big_header[3] = ' ';
    big_header[4] = '/';
    big_header[5] = ' ';
    const result = parse_request(&big_header);
    try std.testing.expect(result == .invalid);
}

test "case-insensitive Content-Length" {
    const req = "PUT /key HTTP/1.1\r\ncontent-length: 3\r\n\r\nabc";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.body, "abc");
}

test "format_u32" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 0), "0");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 5), "5");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 42), "42");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 65536), "65536");
}

test "parse request with extra headers ignored" {
    const req = "GET /key HTTP/1.1\r\nHost: localhost\r\nAccept: */*\r\nUser-Agent: curl\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqual(result.complete.method, .get);
    try std.testing.expectEqualSlices(u8, result.complete.path, "/key");
}

test "parse request with path containing multiple segments" {
    const req = "GET /api/v1/products/123 HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.path, "/api/v1/products/123");
}

test "HTTP/1.1 defaults to keep-alive" {
    const req = "GET /hello HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.keep_alive == true);
}

test "HTTP/1.0 defaults to close" {
    const req = "GET /hello HTTP/1.0\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.keep_alive == false);
}

test "HTTP/1.0 with Connection: keep-alive" {
    const req = "GET /hello HTTP/1.0\r\nConnection: keep-alive\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.keep_alive == true);
}

test "HTTP/1.1 with Connection: close" {
    const req = "GET /hello HTTP/1.1\r\nConnection: close\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.keep_alive == false);
}

test "Connection header case-insensitive" {
    const req = "GET /hello HTTP/1.1\r\nconnection: Close\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.keep_alive == false);
}

test "Datastar-Request header parsed" {
    const req = "GET / HTTP/1.1\r\nDatastar-Request: true\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.is_datastar_request == true);
}

test "Datastar-Request absent defaults to false" {
    const req = "GET / HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.is_datastar_request == false);
}

test "identity_cookie parsed from Cookie header" {
    const req = "GET / HTTP/1.1\r\nCookie: tiger_id=abc123\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.identity_cookie.?, "abc123");
}

test "identity_cookie null when no Cookie header" {
    const req = "GET / HTTP/1.1\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.identity_cookie == null);
}

test "identity_cookie extracted among multiple cookies" {
    const req = "GET / HTTP/1.1\r\nCookie: session=xyz; tiger_id=deadbeef; other=123\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.identity_cookie.?, "deadbeef");
}

test "identity_cookie null when Cookie header lacks tiger_id" {
    const req = "GET / HTTP/1.1\r\nCookie: session=xyz; other=123\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.identity_cookie == null);
}

test "identity_cookie null when value is empty" {
    const req = "GET / HTTP/1.1\r\nCookie: tiger_id=\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expect(result.complete.identity_cookie == null);
}

test "identity_cookie trims trailing whitespace" {
    const req = "GET / HTTP/1.1\r\nCookie: tiger_id=abc123   \r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.identity_cookie.?, "abc123");
}

test "identity_cookie at end with semicolon" {
    const req = "GET / HTTP/1.1\r\nCookie: session=xyz; tiger_id=deadbeef;\r\n\r\n";
    const result = parse_request(req);
    try std.testing.expect(result == .complete);
    try std.testing.expectEqualSlices(u8, result.complete.identity_cookie.?, "deadbeef");
}

// =====================================================================
// Fuzz tests
// =====================================================================

/// SplitMix64 PRNG — matches sim.zig.
fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test "fuzz — parse_request never crashes on random bytes" {
    const iterations = 10_000;

    var prng: u64 = 0xdeadbeef;

    for (0..iterations) |_| {
        var buf: [recv_buf_max]u8 = undefined;
        const len: usize = @intCast(splitmix64(&prng) % buf.len);
        for (0..len) |i| {
            buf[i] = @intCast(splitmix64(&prng) & 0xff);
        }

        const result = parse_request(buf[0..len]);
        switch (result) {
            .incomplete, .invalid => {},
            .complete => |c| {
                try std.testing.expect(c.total_len <= len);
            },
        }
    }
}

test "fuzz — parse_request with structured mutations" {
    const methods = [_][]const u8{ "GET", "PUT", "POST", "DELETE" };
    const versions = [_][]const u8{ "HTTP/1.0", "HTTP/1.1" };
    const iterations = 5_000;

    var prng: u64 = 0xcafebabe;

    for (0..iterations) |_| {
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;

        // Method.
        const method = methods[@intCast(splitmix64(&prng) % methods.len)];
        @memcpy(buf[pos..][0..method.len], method);
        pos += method.len;
        buf[pos] = ' ';
        pos += 1;

        // Path.
        buf[pos] = '/';
        pos += 1;
        const path_len: usize = @intCast(splitmix64(&prng) % 32);
        for (0..path_len) |_| {
            buf[pos] = @intCast(0x20 + splitmix64(&prng) % 0x5f);
            pos += 1;
        }
        buf[pos] = ' ';
        pos += 1;

        // Version.
        const version = versions[@intCast(splitmix64(&prng) % versions.len)];
        @memcpy(buf[pos..][0..version.len], version);
        pos += version.len;

        // CRLF.
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // Maybe add a body for PUT/POST.
        const body_len: usize = if (std.mem.eql(u8, method, "PUT") or std.mem.eql(u8, method, "POST"))
            @intCast(1 + splitmix64(&prng) % 64)
        else
            0;

        if (body_len > 0) {
            const cl = "Content-Length: ";
            @memcpy(buf[pos..][0..cl.len], cl);
            pos += cl.len;
            var cl_buf: [10]u8 = undefined;
            const cl_str = format_u32(&cl_buf, @intCast(body_len));
            @memcpy(buf[pos..][0..cl_str.len], cl_str);
            pos += cl_str.len;
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        // Maybe add a Cookie header (~30% of requests).
        if (splitmix64(&prng) % 10 < 3) {
            const cookie_prefix = "Cookie: " ++ auth.cookie_name ++ "=";
            @memcpy(buf[pos..][0..cookie_prefix.len], cookie_prefix);
            pos += cookie_prefix.len;
            const cookie_val_len: usize = @intCast(splitmix64(&prng) % 128);
            for (0..cookie_val_len) |_| {
                buf[pos] = @intCast(0x20 + splitmix64(&prng) % 0x5f);
                pos += 1;
            }
            buf[pos] = '\r';
            buf[pos + 1] = '\n';
            pos += 2;
        }

        // End of headers.
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;

        // Body bytes.
        for (0..body_len) |_| {
            buf[pos] = @intCast(splitmix64(&prng) & 0xff);
            pos += 1;
        }

        // Mutate 0-3 random positions.
        const mutations: usize = @intCast(splitmix64(&prng) % 4);
        for (0..mutations) |_| {
            const idx: usize = @intCast(splitmix64(&prng) % pos);
            buf[idx] = @intCast(splitmix64(&prng) & 0xff);
        }

        const result = parse_request(buf[0..pos]);
        switch (result) {
            .incomplete, .invalid => {},
            .complete => |c| {
                try std.testing.expect(c.total_len <= pos);
            },
        }
    }
}

test "fuzz — parse_request at every truncation point" {
    const requests = [_][]const u8{
        "GET /hello HTTP/1.1\r\n\r\n",
        "PUT /key HTTP/1.1\r\nContent-Length: 5\r\n\r\nworld",
        "DELETE /x HTTP/1.0\r\n\r\n",
        "GET /path HTTP/1.1\r\nConnection: close\r\n\r\n",
        "POST /data HTTP/1.0\r\nConnection: keep-alive\r\nContent-Length: 3\r\n\r\nabc",
        "GET / HTTP/1.1\r\nCookie: tiger_id=aabbccdd11223344\r\n\r\n",
        "GET / HTTP/1.1\r\nCookie: session=xyz; tiger_id=aabbccdd\r\n\r\n",
    };

    for (requests) |req| {
        for (0..req.len - 1) |len| {
            const result = parse_request(req[0..len]);
            try std.testing.expect(result != .complete);
        }
        const result = parse_request(req);
        try std.testing.expect(result == .complete);
        try std.testing.expectEqual(result.complete.total_len, @as(u32, @intCast(req.len)));
    }
}
