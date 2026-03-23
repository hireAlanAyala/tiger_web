const std = @import("std");
const assert = std.debug.assert;

/// `maybe` is the dual of `assert`: it signals that a condition is sometimes
/// true and sometimes false, and that's fine. Pure documentation — compiles
/// to a tautology. See TigerBeetle's stdx.maybe().
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

/// Returns true if T has no implicit padding bytes — every byte in
/// @sizeOf(T) is accounted for by a field. Requires extern or packed
/// layout; auto-layout structs always return false because the compiler
/// may insert arbitrary padding.
///
/// Ported from TigerBeetle's stdx.no_padding.
pub fn no_padding(comptime T: type) bool {
    comptime switch (@typeInfo(T)) {
        .void => return true,
        .int => return @bitSizeOf(T) == 8 * @sizeOf(T),
        .array => |info| return no_padding(info.child),
        .@"struct" => |info| {
            switch (info.layout) {
                .auto => return false,
                .@"extern" => {
                    for (info.fields) |field| {
                        if (!no_padding(field.type)) return false;
                    }

                    var offset: usize = 0;
                    for (info.fields) |field| {
                        const field_offset = @offsetOf(T, field.name);
                        if (offset != field_offset) return false;
                        offset += @sizeOf(field.type);
                    }
                    return offset == @sizeOf(T);
                },
                .@"packed" => return @bitSizeOf(T) == 8 * @sizeOf(T),
            }
        },
        .@"enum" => |info| return no_padding(info.tag_type),
        .pointer => return false,
        .@"union" => return false,
        else => return false,
    };
}

/// Byte-wise equality comparison. Requires T to have unique representation
/// (no padding, no non-deterministic bits) so that byte equality implies
/// value equality.
///
/// Uses word-wise XOR for compiler vectorization, matching TigerBeetle's
/// stdx.equal_bytes.
pub fn equal_bytes(comptime T: type, a: *const T, b: *const T) bool {
    comptime assert(has_unique_representation(T));
    comptime assert(!has_pointers(T));
    comptime assert(@sizeOf(T) * 8 == @bitSizeOf(T));

    const Word = comptime for (.{ u64, u32, u16, u8 }) |Word| {
        if (@alignOf(T) >= @alignOf(Word) and @sizeOf(T) % @sizeOf(Word) == 0) break Word;
    } else unreachable;

    const a_words = std.mem.bytesAsSlice(Word, std.mem.asBytes(a));
    const b_words = std.mem.bytesAsSlice(Word, std.mem.asBytes(b));
    assert(a_words.len == b_words.len);

    var total: Word = 0;
    for (a_words, b_words) |a_word, b_word| {
        total |= a_word ^ b_word;
    }

    return total == 0;
}

fn has_unique_representation(comptime T: type) bool {
    switch (@typeInfo(T)) {
        else => return false,

        .@"enum",
        .error_set,
        .@"fn",
        => return true,

        .bool => return false,

        .int => |info| return @sizeOf(T) * 8 == info.bits,

        .pointer => |info| return info.size != .slice,

        .array => |info| return comptime has_unique_representation(info.child),

        .@"struct" => |info| {
            if (info.backing_integer) |backing_integer| {
                return @sizeOf(T) * 8 == @bitSizeOf(backing_integer);
            }

            var sum_size: usize = 0;
            inline for (info.fields) |field| {
                if (comptime !has_unique_representation(field.type)) return false;
                sum_size += @sizeOf(field.type);
            }

            return @sizeOf(T) == sum_size;
        },

        .vector => |info| return comptime has_unique_representation(info.child) and
            @sizeOf(T) == @sizeOf(info.child) * info.len,
    }
}

/// Checks that a byte slice is zeroed.
/// Uses bitwise OR for compiler vectorization.
/// Ported from TigerBeetle's stdx.zeroed.
pub fn zeroed(bytes: []const u8) bool {
    var byte_bits: u8 = 0;
    for (bytes) |byte| {
        byte_bits |= byte;
    }
    return byte_bits == 0;
}

// --- Shared formatters (no std.fmt in hot paths) ---

/// Format a u32 as a decimal string into a caller-provided buffer.
/// Returns the slice within `buf` containing the formatted digits.
pub fn format_u32(buf: *[10]u8, val: u32) []const u8 {
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
pub fn format_u64(buf: *[20]u8, val: u64) []const u8 {
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

fn has_pointers(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => return true,
        else => return true,

        .bool, .int, .@"enum" => return false,

        .array => |info| return comptime has_pointers(info.child),
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (comptime has_pointers(field.type)) return true;
            }
            return false;
        },
    }
}

/// Fixed-capacity list backed by an array. No allocations.
/// Used as the return type for multi-row queries (query_all).
///
/// Framework-owned, not storage-owned. BoundedList is a query result
/// shape — how the framework returns bounded result sets. Storage
/// backends fill it, handlers consume it. If it lived on Storage,
/// every new backend would have to redefine the same type.
pub fn BoundedList(comptime T: type, comptime max: usize) type {
    return struct {
        items: [max]T = undefined,
        len: usize = 0,

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}
