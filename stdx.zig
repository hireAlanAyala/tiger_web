const std = @import("std");
const assert = std.debug.assert;

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
