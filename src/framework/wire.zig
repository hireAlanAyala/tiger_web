//! Wire protocol primitives — shared between ShmBus and WorkerDispatch.
//!
//! Single source of truth for the binary CALL/RESULT/QUERY frame format
//! used over SHM. No app-level imports — safe for standalone framework tests.

const std = @import("std");
const assert = std.debug.assert;

pub const CallTag = enum(u8) {
    call = 0x10,
    result = 0x11,
    query = 0x12,
    query_result = 0x13,
};

pub const ResultFlag = enum(u8) {
    success = 0x00,
    failure = 0x01,
};

/// Minimum CALL header size: tag(1) + request_id(4) + name_len(2).
pub const call_header_size = 7;

/// Minimum RESULT header size: tag(1) + request_id(4) + flag(1).
pub const result_header_size = 6;

/// Minimum QUERY header size: tag(1) + request_id(4) + query_id(2) + sql_len(2).
pub const query_header_size = 9;

/// Build a CALL frame: [tag:0x10][request_id:4 BE][name_len:2 BE][name][args].
/// Returns payload length, or null if it doesn't fit in the buffer.
pub fn build_call(buffer: []u8, request_id: u32, name: []const u8, args: []const u8) ?usize {
    assert(name.len > 0); // A CALL without a name is invalid.
    assert(name.len <= std.math.maxInt(u16)); // Name length must fit in u16.

    const total = call_header_size + name.len + args.len;
    if (total > buffer.len) return null;

    var pos: usize = 0;
    buffer[pos] = @intFromEnum(CallTag.call);
    pos += 1;
    std.mem.writeInt(u32, buffer[pos..][0..4], request_id, .big);
    pos += 4;
    std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(name.len), .big);
    pos += 2;
    @memcpy(buffer[pos..][0..name.len], name);
    pos += name.len;
    if (args.len > 0) {
        @memcpy(buffer[pos..][0..args.len], args);
        pos += args.len;
    }

    // Pair assertion: independently computed total must match tracked position.
    assert(pos == total);
    return pos;
}

/// Parse a RESULT frame: [tag:0x11][request_id:4 BE][flag:1][data...].
/// Returns null for malformed frames (too short, wrong tag, invalid flag).
pub fn parse_result(frame: []const u8) ?struct {
    request_id: u32,
    flag: ResultFlag,
    data: []const u8,
} {
    if (frame.len < result_header_size) return null;
    if (frame[0] != @intFromEnum(CallTag.result)) return null;
    const request_id = std.mem.readInt(u32, frame[1..5], .big);
    const flag = std.meta.intToEnum(ResultFlag, frame[5]) catch return null;

    // Positive-space assertion: after validation, the frame is well-formed.
    assert(frame.len >= result_header_size);
    return .{ .request_id = request_id, .flag = flag, .data = frame[6..] };
}
