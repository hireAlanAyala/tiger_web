const std = @import("std");
const assert = std.debug.assert;

/// SSE response headers — Content-Type: text/event-stream, Connection: close.
/// Optionally includes a Set-Cookie header.
pub fn encode_headers(buf: []u8, set_cookie_header: ?[]const u8) usize {
    var pos: usize = 0;

    const status_line = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: close\r\n";
    @memcpy(buf[pos..][0..status_line.len], status_line);
    pos += status_line.len;

    if (set_cookie_header) |cookie_hdr| {
        assert(cookie_hdr.len > 0);
        @memcpy(buf[pos..][0..cookie_hdr.len], cookie_hdr);
        pos += cookie_hdr.len;
    }

    const crlf = "\r\n";
    @memcpy(buf[pos..][0..crlf.len], crlf);
    pos += crlf.len;

    return pos;
}

/// Write a Datastar patch-elements event into buf.
/// Returns bytes written. Content is the HTML fragment.
pub fn encode_patch_event(buf: []u8, content: []const u8) usize {
    var pos: usize = 0;

    const event_line = "event: datastar-patch-elements\n" ++
        "data: elements ";
    @memcpy(buf[pos..][0..event_line.len], event_line);
    pos += event_line.len;

    @memcpy(buf[pos..][0..content.len], content);
    pos += content.len;

    const end = "\n\n";
    @memcpy(buf[pos..][0..end.len], end);
    pos += end.len;

    return pos;
}

/// Write a Datastar patch-signals event into buf.
/// Returns bytes written. Content is JSON signals.
pub fn encode_signal_event(buf: []u8, content: []const u8) usize {
    var pos: usize = 0;

    const event_line = "event: datastar-patch-signals\n" ++
        "data: signals ";
    @memcpy(buf[pos..][0..event_line.len], event_line);
    pos += event_line.len;

    @memcpy(buf[pos..][0..content.len], content);
    pos += content.len;

    const end = "\n\n";
    @memcpy(buf[pos..][0..end.len], end);
    pos += end.len;

    return pos;
}

/// Encode a handler render result into SSE events in buf.
/// Handles both return forms at comptime:
///   - []const u8 → single patch-elements event
///   - tuple of .{ event_type, content } → one event per element
/// Returns bytes written.
pub fn encode_render_result(buf: []u8, result: anytype) usize {
    const T = @TypeOf(result);

    // String return — single patch event.
    if (T == []const u8) {
        if (result.len == 0) return 0;
        return encode_patch_event(buf, result);
    }

    // Comptime string literal (pointer to array).
    const info = @typeInfo(T);
    if (info == .pointer) {
        const child = @typeInfo(info.pointer.child);
        if (child == .array and child.array.child == u8) {
            const slice: []const u8 = result;
            if (slice.len == 0) return 0;
            return encode_patch_event(buf, slice);
        }
    }

    // Tuple return — iterate fields, each is .{ event_type, content }.
    if (info == .@"struct" and info.@"struct".is_tuple) {
        var pos: usize = 0;
        inline for (std.meta.fields(T)) |field| {
            const element = @field(result, field.name);
            const event_type = comptime to_slice(element.@"0");
            const content = to_slice(element.@"1");

            if (comptime std.mem.eql(u8, event_type, "patch")) {
                pos += encode_patch_event(buf[pos..], content);
            } else if (comptime std.mem.eql(u8, event_type, "signal")) {
                pos += encode_signal_event(buf[pos..], content);
            } else {
                @compileError("unknown render event type: \"" ++ event_type ++ "\". Valid: patch, signal");
            }
        }
        return pos;
    }

    @compileError("render must return []const u8 or a tuple of .{ event_type, content }, got " ++ @typeName(T));
}

/// Coerce string literals to []const u8.
fn to_slice(val: anytype) []const u8 {
    const VT = @TypeOf(val);
    if (VT == []const u8) return val;
    const vi = @typeInfo(VT);
    if (vi == .pointer) {
        const child = @typeInfo(vi.pointer.child);
        if (child == .array and child.array.child == u8) {
            return val;
        }
    }
    @compileError("expected []const u8 or string literal, got " ++ @typeName(VT));
}

/// Overhead per SSE event (framing without content). Useful for buffer sizing.
pub const patch_event_overhead = ("event: datastar-patch-elements\n" ++
    "data: elements " ++
    "\n\n").len;

pub const signal_event_overhead = ("event: datastar-patch-signals\n" ++
    "data: signals " ++
    "\n\n").len;

pub const headers_max = ("HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/event-stream\r\n" ++
    "Cache-Control: no-cache\r\n" ++
    "Connection: close\r\n" ++
    "\r\n").len + 256; // room for Set-Cookie

// =====================================================================
// Tests
// =====================================================================

test "encode_render_result: string" {
    var buf: [4096]u8 = undefined;
    const html: []const u8 = "<div id=\"product\">Widget</div>";
    const len = encode_render_result(&buf, html);
    const output = buf[0..len];
    try std.testing.expect(std.mem.startsWith(u8, output, "event: datastar-patch-elements\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "<div id=\"product\">Widget</div>") != null);
}

test "encode_render_result: string literal" {
    var buf: [4096]u8 = undefined;
    const len = encode_render_result(&buf, "<div>ok</div>");
    const output = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, output, "<div>ok</div>") != null);
}

test "encode_render_result: empty string" {
    var buf: [4096]u8 = undefined;
    const empty: []const u8 = "";
    const len = encode_render_result(&buf, empty);
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "encode_render_result: tuple single patch" {
    var buf: [4096]u8 = undefined;
    const html: []const u8 = "<div>hello</div>";
    const len = encode_render_result(&buf, .{
        .{ "patch", html },
    });
    const output = buf[0..len];
    try std.testing.expect(std.mem.startsWith(u8, output, "event: datastar-patch-elements\n"));
    try std.testing.expect(std.mem.indexOf(u8, output, "<div>hello</div>") != null);
}

test "encode_render_result: tuple mixed events" {
    var buf: [4096]u8 = undefined;
    const html: []const u8 = "<div>products</div>";
    const signals: []const u8 = "{\"count\":5}";
    const len = encode_render_result(&buf, .{
        .{ "patch", html },
        .{ "signal", signals },
    });
    const output = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, output, "datastar-patch-elements") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "datastar-patch-signals") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<div>products</div>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "{\"count\":5}") != null);
}

test "encode_render_result: empty tuple" {
    var buf: [4096]u8 = undefined;
    const len = encode_render_result(&buf, .{});
    try std.testing.expectEqual(@as(usize, 0), len);
}
