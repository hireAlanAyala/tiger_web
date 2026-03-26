const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx/stdx.zig");
const auth = @import("auth.zig");

/// HTTP response location in the send buffer.
pub const Response = struct {
    /// Byte offset into send_buf where the response starts.
    offset: u32,
    /// Total response length (headers + body).
    len: u32,
    /// Whether the connection can be reused.
    keep_alive: bool,
};

/// Reserve space for HTTP headers so we can backfill Content-Length.
/// "HTTP/1.1 200 OK\r\n" (18) +
/// "Content-Type: text/html; charset=utf-8\r\n" (40) +
/// "Content-Length: NNNNN\r\n" (23 max for 5-digit) +
/// "Cache-Control: no-cache\r\n" (25) +
/// "Connection: keep-alive\r\n" (24) +
/// "Set-Cookie: tiger_id=...;...\r\n" (152 max) +
/// "\r\n" (2) = 284.  Round up for safety.
pub const header_reserve: u32 = 384;

/// Write HTTP headers right-aligned into the reserved space before the body.
/// Always 200 OK — see decisions/always-200.md.
pub fn backfill_headers(send_buf: []u8, body_len: usize, set_cookie_header: ?[]const u8) Response {
    // Build headers into a stack buffer.
    var hdr_buf: [header_reserve]u8 = undefined;
    var pos: usize = 0;

    const status_line = "HTTP/1.1 200 OK\r\n";
    @memcpy(hdr_buf[pos..][0..status_line.len], status_line);
    pos += status_line.len;

    const content_type = "Content-Type: text/html; charset=utf-8\r\n";
    @memcpy(hdr_buf[pos..][0..content_type.len], content_type);
    pos += content_type.len;

    const cl_prefix = "Content-Length: ";
    @memcpy(hdr_buf[pos..][0..cl_prefix.len], cl_prefix);
    pos += cl_prefix.len;

    var cl_buf: [10]u8 = undefined;
    const cl_str = stdx.format_u32(&cl_buf, @intCast(body_len));
    @memcpy(hdr_buf[pos..][0..cl_str.len], cl_str);
    pos += cl_str.len;

    const conn_cache = "\r\nConnection: keep-alive\r\n" ++
        "Cache-Control: no-cache\r\n";
    @memcpy(hdr_buf[pos..][0..conn_cache.len], conn_cache);
    pos += conn_cache.len;

    if (set_cookie_header) |cookie_hdr| {
        assert(cookie_hdr.len > 0);
        assert(cookie_hdr.len <= header_reserve);
        @memcpy(hdr_buf[pos..][0..cookie_hdr.len], cookie_hdr);
        pos += cookie_hdr.len;
    }

    const crlf = "\r\n";
    @memcpy(hdr_buf[pos..][0..crlf.len], crlf);
    pos += crlf.len;

    assert(pos <= header_reserve);

    // Copy headers right-aligned so they abut the body.
    const start = header_reserve - pos;
    @memcpy(send_buf[start..][0..pos], hdr_buf[0..pos]);

    return .{
        .offset = @intCast(start),
        .len = @intCast(pos + body_len),
        .keep_alive = true,
    };
}

/// Formatted Set-Cookie header value.
pub const CookieHeader = struct {
    buf: [auth.set_cookie_header_max]u8,
    len: u8,

    pub fn slice(self: *const CookieHeader) []const u8 {
        return self.buf[0..self.len];
    }
};

/// Format Set-Cookie header from auth session action.
/// Returns zero-length if no cookie action is needed.
pub fn format_cookie_header(
    session_action: anytype,
    user_id: u128,
    is_authenticated: bool,
    is_new_visitor: bool,
    secret_key: *const [auth.key_length]u8,
) CookieHeader {
    var result = CookieHeader{ .buf = undefined, .len = 0 };

    switch (session_action) {
        .set_authenticated => {
            assert(user_id != 0);
            var hdr_buf: [auth.set_cookie_header_max]u8 = undefined;
            const hdr = auth.format_set_cookie_header(&hdr_buf, user_id, .authenticated, secret_key);
            @memcpy(result.buf[0..hdr.len], hdr);
            result.len = @intCast(hdr.len);
        },
        .clear => {
            assert(user_id != 0);
            const kind: auth.CookieKind = if (is_authenticated) .authenticated else .anonymous;
            var hdr_buf: [auth.clear_cookie_header_max]u8 = undefined;
            const hdr = auth.format_clear_cookie_header(&hdr_buf, user_id, kind, secret_key);
            @memcpy(result.buf[0..hdr.len], hdr);
            result.len = @intCast(hdr.len);
        },
        .none => {
            if (is_new_visitor) {
                assert(user_id != 0);
                var hdr_buf: [auth.set_cookie_header_max]u8 = undefined;
                const hdr = auth.format_set_cookie_header(&hdr_buf, user_id, .anonymous, secret_key);
                @memcpy(result.buf[0..hdr.len], hdr);
                result.len = @intCast(hdr.len);
            }
        },
    }

    return result;
}
