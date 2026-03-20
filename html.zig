const std = @import("std");
const assert = std.debug.assert;

/// Shared HTML rendering utilities for Zig handlers.
///
/// The framework doesn't own HTML generation — it's language-specific.
/// TypeScript handlers use template literals. Zig handlers use this.
/// Each function writes into a caller-provided buffer and returns
/// the number of bytes written.

pub fn raw(buf: []u8, s: []const u8) usize {
    assert(s.len <= buf.len);
    @memcpy(buf[0..s.len], s);
    return s.len;
}

pub fn escaped(buf: []u8, s: []const u8) usize {
    var pos: usize = 0;
    for (s) |c| {
        switch (c) {
            '<' => pos += raw(buf[pos..], "&lt;"),
            '>' => pos += raw(buf[pos..], "&gt;"),
            '&' => pos += raw(buf[pos..], "&amp;"),
            '"' => pos += raw(buf[pos..], "&quot;"),
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

pub fn u32_decimal(buf: []u8, val: u32) usize {
    var tmp: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
    return raw(buf, s);
}

pub fn price(buf: []u8, cents: u32) usize {
    var pos: usize = 0;
    pos += raw(buf[pos..], "$");
    pos += u32_decimal(buf[pos..], cents / 100);
    pos += raw(buf[pos..], ".");
    const frac = cents % 100;
    var frac_buf: [2]u8 = undefined;
    frac_buf[0] = '0' + @as(u8, @intCast(frac / 10));
    frac_buf[1] = '0' + @as(u8, @intCast(frac % 10));
    pos += raw(buf[pos..], &frac_buf);
    return pos;
}

pub fn uuid(buf: []u8, id: u128) usize {
    const hex = "0123456789abcdef";
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, id, .big);
    var pos: usize = 0;
    for (bytes) |b| {
        buf[pos] = hex[b >> 4];
        buf[pos + 1] = hex[b & 0xf];
        pos += 2;
    }
    return pos;
}

// =====================================================================
// Tests
// =====================================================================

test "raw" {
    var buf: [64]u8 = undefined;
    const n = raw(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expect(std.mem.eql(u8, "hello", buf[0..n]));
}

test "escaped" {
    var buf: [64]u8 = undefined;
    const n = escaped(&buf, "<b>\"a&b\"</b>");
    try std.testing.expect(std.mem.eql(u8, "&lt;b&gt;&quot;a&amp;b&quot;&lt;/b&gt;", buf[0..n]));
}

test "escaped no special chars" {
    var buf: [64]u8 = undefined;
    const n = escaped(&buf, "hello world");
    try std.testing.expect(std.mem.eql(u8, "hello world", buf[0..n]));
}

test "u32_decimal" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), u32_decimal(&buf, 0));
    try std.testing.expect(std.mem.eql(u8, "0", buf[0..1]));

    const n = u32_decimal(&buf, 12345);
    try std.testing.expect(std.mem.eql(u8, "12345", buf[0..n]));
}

test "price" {
    var buf: [64]u8 = undefined;
    var n = price(&buf, 999);
    try std.testing.expect(std.mem.eql(u8, "$9.99", buf[0..n]));

    n = price(&buf, 100);
    try std.testing.expect(std.mem.eql(u8, "$1.00", buf[0..n]));

    n = price(&buf, 1);
    try std.testing.expect(std.mem.eql(u8, "$0.01", buf[0..n]));

    n = price(&buf, 0);
    try std.testing.expect(std.mem.eql(u8, "$0.00", buf[0..n]));
}

test "uuid" {
    var buf: [64]u8 = undefined;
    const n = uuid(&buf, 0xaabbccdd11223344aabbccdd11223344);
    try std.testing.expectEqual(@as(usize, 32), n);
    try std.testing.expect(std.mem.eql(u8, "aabbccdd11223344aabbccdd11223344", buf[0..n]));
}

test "uuid zero" {
    var buf: [64]u8 = undefined;
    const n = uuid(&buf, 0);
    try std.testing.expect(std.mem.eql(u8, "00000000000000000000000000000000", buf[0..n]));
}
