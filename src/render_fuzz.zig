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

const Counters = struct {
    iterations: u64 = 0,
    datastar_count: u64 = 0,
    fullpage_count: u64 = 0,
    with_cookie: u64 = 0,
};

pub fn main(_: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var send_buf: [http.send_buf_max]u8 = undefined;
    var html_buf: [http.send_buf_max]u8 = undefined;
    var key: [auth.key_length]u8 = undefined;
    var counters: Counters = .{};

    for (0..events_max) |_| {
        iteration(&prng, &send_buf, &html_buf, &key, &counters);
    }

    log.info("Render fuzz done: iterations={d} datastar={d} fullpage={d} cookie={d}", .{
        counters.iterations, counters.datastar_count,
        counters.fullpage_count, counters.with_cookie,
    });
    assert(counters.iterations == events_max);
    // Generator-coverage gate — see codec_fuzz for rationale. At
    // tiny sample sizes a legit run can land entirely on one branch.
    if (events_max >= 100) {
        assert(counters.datastar_count > 0);
        assert(counters.fullpage_count > 0);
    }
}

const Input = struct {
    status: message.Status,
    session_action: message.SessionAction,
    is_datastar: bool,
    is_authenticated: bool,
    is_new_visitor: bool,
    user_id: u128,
    html_len: usize,
};

/// Roll random inputs and fill `key` + `html_buf[0..html_len]` with
/// random bytes. Centralises the constraints (user_id non-zero,
/// html_len within the budget for the chosen response type).
fn generate_input(
    prng: *PRNG,
    key: *[auth.key_length]u8,
    html_buf: []u8,
    send_buf_len: usize,
) Input {
    const is_datastar = prng.range_inclusive(u32, 0, 1) == 1;
    const max_html_len = if (is_datastar)
        send_buf_len - sse.headers_max
    else
        send_buf_len - http_response.header_reserve;
    const html_len = prng.range_inclusive(usize, 0, max_html_len);
    for (html_buf[0..html_len]) |*b| b.* = prng.int(u8);
    for (key) |*b| b.* = prng.int(u8);
    return .{
        .status = random_status(prng),
        .session_action = random_session_action(prng),
        .is_datastar = is_datastar,
        .is_authenticated = prng.range_inclusive(u32, 0, 1) == 1,
        .is_new_visitor = prng.range_inclusive(u32, 0, 1) == 1,
        // user_id == 0 is reserved for "no session"; `format_cookie_header`
        // asserts non-zero. Force low bit so a random u128 never rolls
        // into the assertion's negative space.
        .user_id = (@as(u128, prng.int(u64)) | (@as(u128, prng.int(u64)) << 64)) | 1,
        .html_len = html_len,
    };
}

/// One fuzz iteration: generate random inputs within the budget,
/// dispatch encode_response, run all wire-shape assertions.
fn iteration(
    prng: *PRNG,
    send_buf: *[http.send_buf_max]u8,
    html_buf: *[http.send_buf_max]u8,
    key: *[auth.key_length]u8,
    counters: *Counters,
) void {
    const input = generate_input(prng, key, html_buf, send_buf.len);

    const result = app.encode_response(
        input.status,
        html_buf[0..input.html_len],
        send_buf,
        input.is_datastar,
        input.session_action,
        input.user_id,
        input.is_authenticated,
        input.is_new_visitor,
        key,
    );

    // Status round-trips unchanged.
    assert(result.status == input.status);
    // Response fits within the buffer.
    assert(result.response.len > 0);
    assert(@as(usize, result.response.offset) + result.response.len <= send_buf.len);

    const wire_start: usize = result.response.offset;
    const wire_end: usize = wire_start + result.response.len;
    const wire = send_buf[wire_start..wire_end];

    if (input.is_datastar) {
        assert_datastar_response(wire, result);
        counters.datastar_count += 1;
    } else {
        assert_full_page_response(wire, html_buf[0..input.html_len], result);
        counters.fullpage_count += 1;
    }

    // Cookie pair-assertion: appears iff caller asked for one.
    const has_cookie = std.mem.indexOf(u8, wire, "\r\nSet-Cookie: ") != null;
    const wanted_cookie = input.is_new_visitor or input.session_action != .none;
    if (wanted_cookie) {
        assert(has_cookie);
        counters.with_cookie += 1;
    } else {
        assert(!has_cookie);
    }

    // Header injection — runs on both SSE and full-page paths.
    assert_no_header_injection(wire);

    counters.iterations += 1;
}

/// Datastar/SSE response wire-shape assertions.
fn assert_datastar_response(wire: []const u8, result: app.CommitResult) void {
    // SSE writes from offset 0 (Connection: close, no header reserve).
    assert(result.response.offset == 0);
    assert(!result.response.keep_alive);
    assert(starts_with(wire, "HTTP/1.1 200 OK"));
    // Header terminator must exist — otherwise the client never sees
    // a header block end and assert_no_header_injection silently
    // no-ops (returns early when `\r\n\r\n` isn't found).
    assert(std.mem.indexOf(u8, wire, "\r\n\r\n") != null);
}

/// Full-page response wire-shape assertions.
fn assert_full_page_response(
    wire: []const u8,
    expected_body: []const u8,
    result: app.CommitResult,
) void {
    _ = result;
    assert(starts_with(wire, "HTTP/1.1 200 OK"));
    const term = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse {
        @panic("render_fuzz: full-page response missing \\r\\n\\r\\n header terminator");
    };
    const body = wire[term + 4 ..];
    assert(body.len == expected_body.len);
    // Byte-equality: catches an encoder that writes a same-length-
    // but-wrong sequence (e.g., reads from the wrong html_buf offset).
    assert(std.mem.eql(u8, body, expected_body));
    const cl_value = find_header(wire[0..term], "Content-Length") orelse {
        @panic("render_fuzz: full-page response missing Content-Length");
    };
    const advertised = std.fmt.parseInt(usize, cl_value, 10) catch {
        @panic("render_fuzz: Content-Length value not a valid integer");
    };
    assert(advertised == expected_body.len);
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

/// Assert the response headers can't be injected into.
///
/// Two checks. Both are required; either alone is insufficient.
///
/// 1. **No bare `\r` or `\n` inside a line.** A lone CR or LF (not
///    paired) is invalid per RFC and indicates a value with control
///    bytes that escaped escaping.
///
/// 2. **Every line after the status line has a colon.** This is the
///    one that catches `\r\n` injection: a value containing `\r\n`
///    gets split by the iterator into two pieces, the first ending
///    where the injection started, the second being the trailing
///    suffix of the original value. The suffix has no colon. Status
///    line ("HTTP/1.1 200 OK") has no colon either, which is why this
///    rule starts from line 2.
///
/// Uses `splitSequence` rather than a hand-rolled walker (rounds 1-4
/// shipped a hand-rolled walker that dropped the last fragment because
/// the loop exited on "no more separators" instead of "no more
/// elements"). The library iterator yields all fragments including the
/// trailing one by contract.
fn assert_no_header_injection(wire: []const u8) void {
    const term = std.mem.indexOf(u8, wire, "\r\n\r\n") orelse return;
    const headers = wire[0..term];

    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    var line_index: u32 = 0;
    while (lines.next()) |line| : (line_index += 1) {
        for (line) |b| {
            assert(b != '\r');
            assert(b != '\n');
        }
        if (line_index > 0) {
            assert(std.mem.indexOf(u8, line, ":") != null);
        }
    }
}

/// Find a header value inside the headers blob (everything before the
/// `\r\n\r\n` terminator). Case-sensitive — render emits canonical
/// casing, so a fuzzer that requires the exact spelling is fine.
fn find_header(headers: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOf(u8, line, ":") orelse continue;
        if (!std.mem.eql(u8, line[0..colon], name)) continue;
        var val = line[colon + 1 ..];
        while (val.len > 0 and val[0] == ' ') val = val[1..];
        return val;
    }
    return null;
}
