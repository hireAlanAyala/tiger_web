//! Tiger Web domain-specific additions to stdx.
//!
//! These functions have no equivalent in TigerBeetle's stdx and are specific
//! to the tiger_web application domain (UUID handling, query result shapes).
//! Re-exported via stdx.zig for uniform access.

const std = @import("std");
const assert = std.debug.assert;

// --- UUID handling (32-char lowercase hex, no dashes) ---

/// Parse a 32-char lowercase hex string into a u128.
/// Returns null if the string is not exactly 32 lowercase hex characters.
pub fn parse_uuid(s: []const u8) ?u128 {
    if (s.len != 32) return null;
    var result: u128 = 0;
    for (s) |c| {
        const digit: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        result = (result << 4) | digit;
    }
    return result;
}

/// Write a u128 as 32-char lowercase hex into a caller-provided buffer.
pub fn write_uuid_to_buf(buf: *[32]u8, val: u128) void {
    const hex = "0123456789abcdef";
    var v = val;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@intCast(v & 0xf)];
        v >>= 4;
    }
}

comptime {
    // Roundtrip: parse_uuid and write_uuid_to_buf are inverse functions.
    // If either changes digit order, the build breaks immediately.
    const expected: u128 = 0x0123456789abcdef_0123456789abcdef;
    const parsed = parse_uuid("0123456789abcdef0123456789abcdef");
    assert(parsed != null);
    assert(parsed.? == expected);

    var buf: [32]u8 = undefined;
    write_uuid_to_buf(&buf, expected);
    assert(std.mem.eql(u8, &buf, "0123456789abcdef0123456789abcdef"));
}

// --- No-std formatters (no std.fmt in hot paths) ---

/// Format a u32 as a decimal string into a caller-provided buffer.
/// Returns the slice within `buf` containing the formatted digits.
///
/// Hand-rolled integer-to-decimal loop — no std.fmt in hot paths.
/// stdx.array_print provides the same comptime buffer-size proof but
/// goes through std.fmt.formatInt which handles padding, alignment,
/// fill, sign, and width (none used here). Benchmarked at ~100x slower
/// on ReleaseFast (5 ns/call vs <1 ns/call over 70M iterations).
pub fn format_u32(buf: *[10]u8, val: u32) []const u8 {
    comptime std.debug.assert(std.fmt.count("{d}", .{std.math.maxInt(u32)}) == 10);
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

/// Format a u64 as a decimal string into a caller-provided buffer.
/// See format_u32 for rationale.
pub fn format_u64(buf: *[20]u8, val: u64) []const u8 {
    comptime std.debug.assert(std.fmt.count("{d}", .{std.math.maxInt(u64)}) == 20);
    if (val == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = val;
    var pos: usize = 20;
    while (v > 0) {
        pos -= 1;
        buf[pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    return buf[pos..20];
}

// --- Query result shape ---

/// Fixed-capacity list backed by an array. No allocations.
/// Used as the return type for multi-row queries (query_all).
///
/// Different from stdx.BoundedArrayType: BoundedList is a read-only result
/// shape (no insert/remove/swap). BoundedArrayType is a full mutable
/// dynamic-within-capacity array. Different types, different purposes.
pub fn BoundedList(comptime T: type, comptime max: usize) type {
    return struct {
        items: [max]T = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

// =====================================================================
// Tests
// =====================================================================

test "format_u32 edge cases" {
    var buf: [10]u8 = undefined;
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 0), "0");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 1), "1");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, 999), "999");
    try std.testing.expectEqualSlices(u8, format_u32(&buf, std.math.maxInt(u32)), "4294967295");
}

test "format_u64 edge cases" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualSlices(u8, format_u64(&buf, 0), "0");
    try std.testing.expectEqualSlices(u8, format_u64(&buf, 1), "1");
    try std.testing.expectEqualSlices(u8, format_u64(&buf, std.math.maxInt(u64)), "18446744073709551615");
}

test "parse_uuid" {
    try std.testing.expectEqual(parse_uuid("00000000000000000000000000000000"), 0);
    try std.testing.expectEqual(parse_uuid("00000000000000000000000000000001"), 1);
    try std.testing.expectEqual(parse_uuid("0123456789abcdef0123456789abcdef"), 0x0123456789abcdef0123456789abcdef);
    try std.testing.expectEqual(parse_uuid("ffffffffffffffffffffffffffffffff"), std.math.maxInt(u128));
    try std.testing.expectEqual(parse_uuid(""), null);
    try std.testing.expectEqual(parse_uuid("0"), null);
    try std.testing.expectEqual(parse_uuid("AABBCCDD11223344AABBCCDD11223344"), null); // uppercase
    try std.testing.expectEqual(parse_uuid("0000000000000000000000000000000g"), null); // invalid char
}

test "write_uuid_to_buf" {
    var buf: [32]u8 = undefined;
    write_uuid_to_buf(&buf, 0);
    try std.testing.expectEqualSlices(u8, &buf, "00000000000000000000000000000000");
    write_uuid_to_buf(&buf, 0x0123456789abcdef0123456789abcdef);
    try std.testing.expectEqualSlices(u8, &buf, "0123456789abcdef0123456789abcdef");
    write_uuid_to_buf(&buf, std.math.maxInt(u128));
    try std.testing.expectEqualSlices(u8, &buf, "ffffffffffffffffffffffffffffffff");
}
