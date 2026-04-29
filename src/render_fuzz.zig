//! Render fuzzer — exercises `app.encode_response` over the full
//! cross-product of (Status, SessionAction, identity-flag combinations,
//! is_datastar_request, html size). Sim tests cover the realistic
//! combinations; this hits the cross-product including the boundary
//! shapes a real handler would never produce.
//!
//! Why: render is the encode side of the network boundary. Today the
//! HTML payload has little user-controlled content, so the value is
//! lower than `codec_fuzz` — but as soon as user-controlled strings
//! flow into HTML (seller-edited product names, search-result
//! rendering of user queries), this fuzzer is the test that catches
//! framing/escape regressions before they ship.
//!
//! Invariants asserted:
//!   - Output `Response.offset + len <= send_buf.len` and `len > 0`.
//!   - The status echoed back matches what the caller passed.
//!   - For non-Datastar responses: the `\r\n\r\n` header terminator
//!     appears, and the content-length header value matches the
//!     bytes that actually follow it. (Offset can be non-zero — the
//!     full-page path right-aligns headers into the reserved prefix
//!     so they abut the body, see http_response.backfill_headers.)
//!   - For Datastar responses: offset is zero (SSE writes from the
//!     start of the buffer), `keep_alive == false`, and the wire
//!     begins with the HTTP status line.
//!
//! HTML shapes are bounded to the body budget — generating html
//! larger than the budget is a separate, panicking contract that
//! `sim` already covers (handlers must not over-render).

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const app = @import("app.zig");
const http = @import("framework/http.zig");
const auth = @import("framework/auth.zig");
const sse = @import("framework/sse.zig");
const http_response = @import("framework/http_response.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

const log = std.log.scoped(.fuzz);

pub fn main(_: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var send_buf: [http.send_buf_max]u8 = undefined;
    var html_buf: [http.send_buf_max]u8 = undefined;
    var key: [auth.key_length]u8 = undefined;

    var iterations: u64 = 0;
    var datastar_count: u64 = 0;
    var fullpage_count: u64 = 0;
    var with_cookie: u64 = 0;

    for (0..events_max) |_| {
        // Random everything — Status, SessionAction, identity flags,
        // datastar bit, key, html. Keep html within the body budget so
        // we exercise the encode path rather than the panic contract.
        const status = random_status(&prng);
        const session_action = random_session_action(&prng);
        const is_datastar = prng.range_inclusive(u32, 0, 1) == 1;
        const is_authenticated = prng.range_inclusive(u32, 0, 1) == 1;
        const is_new_visitor = prng.range_inclusive(u32, 0, 1) == 1;
        // user_id == 0 is reserved for "no session" — `format_cookie_header`
        // asserts non-zero whenever it emits a Set-Cookie. Random u128 is
        // astronomically unlikely to roll zero, but a fuzzer that *might*
        // panic on certain seeds is not a fuzzer we trust. Force the low
        // bit so we never roll into the assertion's negative space.
        const user_id: u128 =
            (@as(u128, prng.int(u64)) | (@as(u128, prng.int(u64)) << 64)) | 1;
        for (&key) |*b| b.* = prng.int(u8);

        const max_html_len = if (is_datastar)
            send_buf.len - sse.headers_max
        else
            send_buf.len - http_response.header_reserve;
        const html_len = prng.range_inclusive(usize, 0, max_html_len);
        for (html_buf[0..html_len]) |*b| b.* = prng.int(u8);

        const result = app.encode_response(
            status,
            html_buf[0..html_len],
            &send_buf,
            is_datastar,
            session_action,
            user_id,
            is_authenticated,
            is_new_visitor,
            &key,
        );

        // Status round-trips unchanged.
        assert(result.status == status);

        // Response fits within the buffer.
        assert(result.response.len > 0);
        assert(@as(usize, result.response.offset) + result.response.len <= send_buf.len);

        const wire_start: usize = result.response.offset;
        const wire_end: usize = wire_start + result.response.len;
        const wire = send_buf[wire_start..wire_end];

        if (is_datastar) {
            // SSE writes from offset 0 (Connection: close, no
            // header reservation needed).
            assert(result.response.offset == 0);
            assert(!result.response.keep_alive);
            // Sanity — SSE responses begin with the HTTP status line.
            assert(starts_with(wire, "HTTP/1.1 200 OK"));
            datastar_count += 1;
        } else {
            // Full-page responses must include the header terminator
            // and a Content-Length whose value equals the body bytes
            // that follow it.
            assert(starts_with(wire, "HTTP/1.1 200 OK"));
            const term = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
                @panic("render_fuzz: full-page response missing \\r\\n\\r\\n header terminator");
            };
            const body = wire[term + 4 ..];
            assert(body.len == html_len);
            // Byte-equality: the body region must contain exactly the
            // html we passed in, not just bytes-of-the-right-length.
            // Catches an encoder that writes a same-length-but-wrong
            // sequence into the body (e.g., reads from the wrong
            // offset of html_buf).
            assert(std.mem.eql(u8, body, html_buf[0..html_len]));
            // Content-Length header must agree with the body length.
            const cl_value = find_header(wire[0..term], "Content-Length") orelse {
                @panic("render_fuzz: full-page response missing Content-Length");
            };
            const advertised = std.fmt.parseInt(usize, cl_value, 10) catch {
                @panic("render_fuzz: Content-Length value not a valid integer");
            };
            assert(advertised == html_len);
            fullpage_count += 1;
        }

        // Set-Cookie appears iff we asked for one (new visitor or
        // explicit session change).
        const has_cookie = std.mem.indexOf(u8, wire, "\r\nSet-Cookie: ") != null;
        const wanted_cookie = is_new_visitor or session_action != .none;
        // Pair assertion — the response cookie state matches what the
        // caller asked for.
        if (wanted_cookie) {
            assert(has_cookie);
            with_cookie += 1;
        } else {
            assert(!has_cookie);
        }

        // Header injection — every header value (everything between
        // a `: ` and the next `\r\n`) must be free of `\r\n` so it
        // can't terminate the header block early and smuggle attacker
        // bytes into the body. Class-of-bug TB spends its assertion
        // budget on; one-line cost, catastrophic-bug payoff.
        //
        // Run on both paths unconditionally — the previous version
        // skipped SSE on the rationale "encode_headers composes
        // well-known constants," which is comment-trust. TB
        // (audit 2026-04-29) wouldn't ship that.
        assert_no_header_injection(wire);

        iterations += 1;
    }

    log.info("Render fuzz done: iterations={d} datastar={d} fullpage={d} cookie={d}", .{
        iterations, datastar_count, fullpage_count, with_cookie,
    });
    assert(iterations > 0);
    assert(datastar_count > 0);
    assert(fullpage_count > 0);
}

fn random_status(prng: *PRNG) message.Status {
    const fields = @typeInfo(message.Status).@"enum".fields;
    const idx = prng.range_inclusive(usize, 0, fields.len - 1);
    inline for (fields, 0..) |f, i| {
        if (i == idx) return @enumFromInt(f.value);
    }
    unreachable;
}

fn random_session_action(prng: *PRNG) message.SessionAction {
    const fields = @typeInfo(message.SessionAction).@"enum".fields;
    const idx = prng.range_inclusive(usize, 0, fields.len - 1);
    inline for (fields, 0..) |f, i| {
        if (i == idx) return @enumFromInt(f.value);
    }
    unreachable;
}

fn starts_with(buf: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, buf, prefix);
}

/// Walk every header line and assert no value contains `\r` or `\n`
/// other than the canonical `\r\n` terminator. A bug elsewhere in
/// render that lets attacker bytes flow into a header value (cookie
/// most likely) would otherwise terminate the header block early
/// and inject body content. Asserts on the wire — i.e., the bytes a
/// real client would receive.
fn assert_no_header_injection(wire: []const u8) void {
    const term = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse return;
    const headers = wire[0..term];
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = std.mem.indexOf(u8, headers[pos..], "\r\n") orelse break;
        const line = headers[pos .. pos + line_end];
        pos += line_end + 2;
        // Every line up to `line_end` must be free of CR/LF — they
        // were the delimiters and shouldn't appear inside.
        for (line) |b| {
            assert(b != '\r');
            assert(b != '\n');
        }
    }
}

/// Find a header value inside the headers blob (everything before the
/// `\r\n\r\n` terminator). Case-sensitive — render emits canonical
/// casing, so a fuzzer that requires the exact spelling is fine.
fn find_header(headers: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < headers.len) {
        const line_end = std.mem.indexOf(u8, headers[pos..], "\r\n") orelse return null;
        const line = headers[pos .. pos + line_end];
        pos += line_end + 2;
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        if (!std.mem.eql(u8, line[0..colon], name)) continue;
        var val = line[colon + 1 ..];
        while (val.len > 0 and val[0] == ' ') val = val[1..];
        return val;
    }
    return null;
}
