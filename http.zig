const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

/// Maximum HTTP header size. Requests with headers exceeding this are rejected.
pub const max_header_size = 8192;

/// Maximum total recv buffer: HTTP headers + body.
pub const recv_buf_max = max_header_size + message.value_max;

/// Maximum send buffer: HTTP response headers + body.
/// Accounts for CORS headers (~100 bytes) and X-Checksum header (~22 bytes).
pub const send_buf_max = 400 + message.value_max;

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
    },
};

pub const Method = enum {
    get,
    put,
    post,
    delete,
    options,

    // HEAD is identical to GET but the response body is suppressed. The
    // server runs a normal get, encodes headers with the real Content-Length,
    // but skips the body. Useful for health checks, CDN cache validation,
    // and load-balancer probes. Not necessary for this server — the ecommerce
    // frontend only uses GET/PUT/POST/DELETE, and health checks can use GET.
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
        .get, .delete, .options => {
            if (content_length != 0) return .invalid;
        },
        .put, .post => {
            if (content_length == 0) return .invalid;
            if (content_length > message.value_max) return .invalid;
        },
    }

    // Check if full body has arrived.
    const body_start = header_end + 4; // past \r\n\r\n
    const total_len = body_start + content_length;
    if (buf.len < total_len) return .incomplete;

    const body = if (content_length > 0) buf[body_start..total_len] else &[_]u8{};

    return .{ .complete = .{
        .method = method,
        .path = raw_path,
        .body = body,
        .total_len = @intCast(total_len),
        .keep_alive = keep_alive,
    } };
}

/// Translate a parsed HTTP request into a binary message.Request.
/// URL-decodes the path into path_buf. Returns null if the request
/// doesn't map to a valid KV operation.
pub fn translate(
    method: Method,
    raw_path: []const u8,
    body: []const u8,
    path_buf: *[message.key_max]u8,
) ?message.Request {
    // Strip leading /.
    const path = if (raw_path.len > 0 and raw_path[0] == '/') raw_path[1..] else raw_path;

    // Strip query string — everything after ? is ignored for the key.
    const path_without_query = if (std.mem.indexOf(u8, path, "?")) |q| path[0..q] else path;

    // URL-decode.
    const key = url_decode(path_buf, path_without_query) orelse return null;
    if (key.len == 0 or key.len > message.key_max) return null;

    const operation: message.Operation = switch (method) {
        .get => .get,
        .put, .post => .put,
        .delete => .delete,
        .options => return null, // Handled as preflight in connection layer.
    };

    // Validate operation/value constraints.
    switch (operation) {
        .put => if (body.len == 0 or body.len > message.value_max) return null,
        .get, .delete => if (body.len != 0) return null,
    }

    return .{
        .header = .{
            .operation = operation,
            .key_len = @intCast(key.len),
            .value_len = @intCast(body.len),
        },
        .key = key,
        .value = body,
    };
}

/// Encode a binary message.Response as an HTTP response into buf.
/// Returns the slice of buf that was written.
pub fn encode_response(buf: []u8, status: message.Status, value: []const u8) []const u8 {
    assert(value.len <= message.value_max);
    assert(buf.len >= send_buf_max);

    const status_line = switch (status) {
        .ok => "HTTP/1.1 200 OK\r\n",
        .not_found => "HTTP/1.1 404 Not Found\r\n",
        .err => "HTTP/1.1 500 Internal Server Error\r\n",
    };

    var pos: usize = 0;

    // Status line.
    @memcpy(buf[pos..][0..status_line.len], status_line);
    pos += status_line.len;

    // Content-Length header.
    const cl_prefix = "Content-Length: ";
    @memcpy(buf[pos..][0..cl_prefix.len], cl_prefix);
    pos += cl_prefix.len;

    // Write content length as decimal.
    var cl_buf: [10]u8 = undefined;
    const cl_str = format_u32(&cl_buf, @intCast(value.len));
    @memcpy(buf[pos..][0..cl_str.len], cl_str);
    pos += cl_str.len;

    // X-Checksum: CRC32 of body for corruption detection.
    const checksum_header = "\r\nX-Checksum: ";
    @memcpy(buf[pos..][0..checksum_header.len], checksum_header);
    pos += checksum_header.len;

    var hex_buf: [8]u8 = undefined;
    crc32_hex(&hex_buf, checksum(value));
    @memcpy(buf[pos..][0..8], &hex_buf);
    pos += 8;

    const headers_end = "\r\nContent-Type: application/octet-stream" ++
        "\r\nConnection: keep-alive" ++
        cors_headers ++
        "\r\n\r\n";
    @memcpy(buf[pos..][0..headers_end.len], headers_end);
    pos += headers_end.len;

    // Body.
    if (value.len > 0) {
        @memcpy(buf[pos..][0..value.len], value);
        pos += value.len;
    }

    assert(pos <= buf.len);
    return buf[0..pos];
}

/// Encode a 204 No Content response for OPTIONS preflight requests with CORS headers.
pub fn encode_options_response(buf: []u8) []const u8 {
    const response = "HTTP/1.1 204 No Content" ++
        "\r\nConnection: keep-alive" ++
        cors_headers ++
        "\r\nAccess-Control-Max-Age: 86400" ++
        "\r\n\r\n";
    assert(buf.len >= response.len);
    @memcpy(buf[0..response.len], response);
    return buf[0..response.len];
}

/// Compute CRC32 checksum of data.
pub fn checksum(data: []const u8) u32 {
    return std.hash.crc.Crc32.hash(data);
}

/// Format a u32 as 8-char lowercase hex into buf.
fn crc32_hex(buf: *[8]u8, value: u32) void {
    const hex_chars = "0123456789abcdef";
    inline for (0..8) |i| {
        buf[7 - i] = hex_chars[@intCast((value >> @intCast(i * 4)) & 0xf)];
    }
}

/// Decode a percent-encoded URL path. Returns the decoded slice of dest,
/// or null if the encoding is invalid or dest is too small.
pub fn url_decode(dest: []u8, src: []const u8) ?[]const u8 {
    var di: usize = 0;
    var si: usize = 0;
    while (si < src.len) {
        if (di >= dest.len) return null;
        if (src[si] == '%') {
            if (si + 2 >= src.len) return null;
            const hi = hex_digit(src[si + 1]) orelse return null;
            const lo = hex_digit(src[si + 2]) orelse return null;
            dest[di] = (@as(u8, hi) << 4) | lo;
            si += 3;
        } else if (src[si] == '+') {
            dest[di] = ' ';
            si += 1;
        } else {
            dest[di] = src[si];
            si += 1;
        }
        di += 1;
    }
    return dest[0..di];
}

const cors_headers = "\r\nAccess-Control-Allow-Origin: *" ++
    "\r\nAccess-Control-Allow-Methods: GET, PUT, POST, DELETE" ++
    "\r\nAccess-Control-Allow-Headers: Content-Type";

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
    if (std.mem.eql(u8, s, "OPTIONS")) return .options;
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

fn hex_digit(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
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

test "translate GET to message" {
    var path_buf: [message.key_max]u8 = undefined;
    const req = translate(.get, "/hello", "", &path_buf);
    try std.testing.expect(req != null);
    try std.testing.expectEqual(req.?.header.operation, .get);
    try std.testing.expectEqualSlices(u8, req.?.key, "hello");
    try std.testing.expectEqual(req.?.value.len, 0);
}

test "translate PUT to message" {
    var path_buf: [message.key_max]u8 = undefined;
    const req = translate(.put, "/key", "value", &path_buf);
    try std.testing.expect(req != null);
    try std.testing.expectEqual(req.?.header.operation, .put);
    try std.testing.expectEqualSlices(u8, req.?.key, "key");
    try std.testing.expectEqualSlices(u8, req.?.value, "value");
}

test "translate strips query string" {
    var path_buf: [message.key_max]u8 = undefined;
    const req = translate(.get, "/products?category=shoes&page=2", "", &path_buf);
    try std.testing.expect(req != null);
    try std.testing.expectEqualSlices(u8, req.?.key, "products");
}

test "translate rejects empty path" {
    var path_buf: [message.key_max]u8 = undefined;
    const req = translate(.get, "/", "", &path_buf);
    try std.testing.expect(req == null);
}

test "url_decode basic" {
    var buf: [256]u8 = undefined;
    const decoded = url_decode(&buf, "hello%20world").?;
    try std.testing.expectEqualSlices(u8, decoded, "hello world");
}

test "url_decode plus as space" {
    var buf: [256]u8 = undefined;
    const decoded = url_decode(&buf, "hello+world").?;
    try std.testing.expectEqualSlices(u8, decoded, "hello world");
}

test "url_decode hex" {
    var buf: [256]u8 = undefined;
    const decoded = url_decode(&buf, "%2Fpath%2Fto%2Fkey").?;
    try std.testing.expectEqualSlices(u8, decoded, "/path/to/key");
}

test "url_decode invalid hex" {
    var buf: [256]u8 = undefined;
    try std.testing.expect(url_decode(&buf, "%ZZ") == null);
}

test "encode_response 200 with body" {
    var buf: [send_buf_max]u8 = undefined;
    const resp = encode_response(&buf, .ok, "hello");
    // Should start with HTTP/1.1 200 OK
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    // Should contain Content-Length: 5
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 5\r\n") != null);
    // Should end with the body
    try std.testing.expect(std.mem.endsWith(u8, resp, "hello"));
}

test "encode_response 404 empty body" {
    var buf: [send_buf_max]u8 = undefined;
    const resp = encode_response(&buf, .not_found, "");
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 0\r\n") != null);
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
    // Feed pure random bytes into parse_request. It must always return
    // .incomplete, .invalid, or a valid .complete — never panic or
    // access out-of-bounds memory.
    const iterations = 10_000;

    var prng: u64 = 0xdeadbeef;

    for (0..iterations) |_| {
        var buf: [max_header_size + message.value_max]u8 = undefined;
        const len: usize = @intCast(splitmix64(&prng) % buf.len);
        for (0..len) |i| {
            buf[i] = @intCast(splitmix64(&prng) & 0xff);
        }

        const result = parse_request(buf[0..len]);
        // Must be one of the three variants — if we get here without
        // panic/segfault, the parser handled it safely.
        switch (result) {
            .incomplete, .invalid => {},
            .complete => |c| {
                // Sanity: total_len must not exceed input length.
                try std.testing.expect(c.total_len <= len);
            },
        }
    }
}

test "fuzz — parse_request with structured mutations" {
    // Generate valid-ish HTTP requests and then mutate random bytes.
    // Exercises parser edge cases around almost-valid input.
    const methods = [_][]const u8{ "GET", "PUT", "POST", "DELETE", "OPTIONS" };
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
    // Take valid requests and parse every prefix. The parser must
    // return .incomplete for short prefixes and .complete at the end.
    const requests = [_][]const u8{
        "GET /hello HTTP/1.1\r\n\r\n",
        "PUT /key HTTP/1.1\r\nContent-Length: 5\r\n\r\nworld",
        "DELETE /x HTTP/1.0\r\n\r\n",
        "GET /path HTTP/1.1\r\nConnection: close\r\n\r\n",
        "POST /data HTTP/1.0\r\nConnection: keep-alive\r\nContent-Length: 3\r\n\r\nabc",
    };

    for (requests) |req| {
        // Every proper prefix must be .incomplete.
        for (0..req.len - 1) |len| {
            const result = parse_request(req[0..len]);
            try std.testing.expect(result != .complete);
        }
        // Full request must be .complete.
        const result = parse_request(req);
        try std.testing.expect(result == .complete);
        try std.testing.expectEqual(result.complete.total_len, @as(u32, @intCast(req.len)));
    }
}
