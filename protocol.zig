//! Sidecar wire protocol — self-describing binary rows over unix socket.
//!
//! Three round trips per HTTP request:
//!   RT1: route_request → route_prefetch_response
//!   RT2: prefetch_results → handle_render_response
//!   RT3: render_results → html_response
//!
//! The wire carries rows, not domain structs. One generic row reader per
//! language. SQL is the schema contract. No per-type serde.
//!
//! Frame format: [u32 big-endian payload_length][u8 message_tag][payload]

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");

// =====================================================================
// Constants
// =====================================================================

/// Maximum frame payload size. Derived from worst-case content:
/// prefetch results with list_max rows of max row size.
/// Exact value comptime-derivable once row format is stable.
pub const frame_max = 256 * 1024;

/// Maximum number of write SQL statements from a single handle() call.
pub const writes_max = message.writes_max;

/// Maximum SQL string length in a single query/write.
pub const sql_max = 4096;

/// Maximum number of queries in a prefetch or render declaration.
pub const queries_max = 32;

/// Maximum column name length.
pub const column_name_max = 128;

/// Maximum columns per row set.
pub const columns_max = 32;

/// Maximum text/blob value length in a single cell.
pub const cell_value_max = 4096;

/// Maximum params per SQL query/write.
pub const params_max = 16;

comptime {
    assert(writes_max > 0);
    assert(writes_max == message.writes_max);
    assert(sql_max > 0);
    assert(queries_max > 0);
    assert(columns_max > 0);
    assert(params_max > 0);
    assert(frame_max > 0);
    assert(frame_max <= 1024 * 1024); // stay under 1MB
}

// =====================================================================
// Type tags — match SQLite's type affinity
// =====================================================================

pub const TypeTag = enum(u8) {
    integer = 0x01, // i64, little-endian 8 bytes
    float = 0x02, // f64, little-endian 8 bytes
    text = 0x03, // u16 len + bytes
    blob = 0x04, // u16 len + bytes
    null = 0x05, // 0 bytes
};

// =====================================================================
// Message tags — identify each frame in the 3-RT exchange
// =====================================================================

pub const MessageTag = enum(u8) {
    route_request = 0x01,
    route_prefetch_response = 0x02,
    prefetch_results = 0x03,
    handle_render_response = 0x04,
    render_results = 0x05,
    html_response = 0x06,
};

/// Query mode — single row or array.
pub const QueryMode = enum(u8) {
    one = 0x00, // row_count is 0 (null) or 1
    all = 0x01, // row_count is 0..N
};

// =====================================================================
// Row format — serialize / deserialize
// =====================================================================

/// Column descriptor — type tag + name.
pub const Column = struct {
    type_tag: TypeTag,
    name: []const u8, // slice into the frame buffer

    comptime {
        assert(column_name_max <= std.math.maxInt(u16));
    }
};

/// A typed value in a row.
pub const Value = union(TypeTag) {
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
    null: void,
};

/// Write a row set header (columns) into buf at pos.
/// Returns the new position, or null if buffer too small.
pub fn write_row_set_header(buf: []u8, columns: []const Column) ?usize {
    var pos: usize = 0;

    // Column count.
    if (pos + 2 > buf.len) return null;
    assert(columns.len <= columns_max);
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(columns.len), .big);
    pos += 2;

    // Column descriptors.
    for (columns) |col| {
        assert(col.name.len <= column_name_max);
        if (pos + 1 + 2 + col.name.len > buf.len) return null;
        buf[pos] = @intFromEnum(col.type_tag);
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(col.name.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..col.name.len], col.name);
        pos += col.name.len;
    }

    return pos;
}

/// Write the row count at the given position.
/// Returns the new position, or null if buffer too small.
pub fn write_row_count(buf: []u8, pos: usize, count: u32) ?usize {
    if (pos + 4 > buf.len) return null;
    std.mem.writeInt(u32, buf[pos..][0..4], count, .big);
    return pos + 4;
}

/// Write a single typed value into buf at pos.
/// Returns the new position, or null if buffer too small.
pub fn write_value(buf: []u8, pos_in: usize, value: Value) ?usize {
    var pos = pos_in;
    switch (value) {
        .integer => |v| {
            if (pos + 8 > buf.len) return null;
            std.mem.writeInt(i64, buf[pos..][0..8], v, .little);
            pos += 8;
        },
        .float => |v| {
            if (pos + 8 > buf.len) return null;
            std.mem.writeInt(u64, buf[pos..][0..8], @bitCast(v), .little);
            pos += 8;
        },
        .text => |v| {
            assert(v.len <= cell_value_max);
            if (pos + 2 + v.len > buf.len) return null;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(v.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..v.len], v);
            pos += v.len;
        },
        .blob => |v| {
            assert(v.len <= cell_value_max);
            if (pos + 2 + v.len > buf.len) return null;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(v.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..v.len], v);
            pos += v.len;
        },
        .null => {},
    }
    return pos;
}

/// Read a row set header from buf at pos. Columns are slices into buf.
/// Returns columns and new position, or null on malformed input.
pub fn read_row_set_header(buf: []const u8, pos_in: usize) ?struct { columns: [columns_max]Column, count: u16, pos: usize } {
    var pos = pos_in;
    if (pos + 2 > buf.len) return null;
    const col_count = std.mem.readInt(u16, buf[pos..][0..2], .big);
    pos += 2;
    if (col_count > columns_max) return null;

    var columns: [columns_max]Column = undefined;
    for (0..col_count) |i| {
        if (pos + 1 + 2 > buf.len) return null;
        const tag_byte = buf[pos];
        pos += 1;
        const tag = std.meta.intToEnum(TypeTag, tag_byte) catch return null;
        const name_len = std.mem.readInt(u16, buf[pos..][0..2], .big);
        pos += 2;
        if (name_len > column_name_max) return null;
        if (pos + name_len > buf.len) return null;
        columns[i] = .{ .type_tag = tag, .name = buf[pos..][0..name_len] };
        pos += name_len;
    }

    return .{ .columns = columns, .count = col_count, .pos = pos };
}

/// Read the row count at the given position.
pub fn read_row_count(buf: []const u8, pos: usize) ?struct { count: u32, pos: usize } {
    if (pos + 4 > buf.len) return null;
    const count = std.mem.readInt(u32, buf[pos..][0..4], .big);
    return .{ .count = count, .pos = pos + 4 };
}

/// Read a single typed value from buf at pos.
/// The type_tag tells us how to interpret the bytes.
pub fn read_value(buf: []const u8, pos_in: usize, type_tag: TypeTag) ?struct { value: Value, pos: usize } {
    var pos = pos_in;
    switch (type_tag) {
        .integer => {
            if (pos + 8 > buf.len) return null;
            const v = std.mem.readInt(i64, buf[pos..][0..8], .little);
            pos += 8;
            return .{ .value = .{ .integer = v }, .pos = pos };
        },
        .float => {
            if (pos + 8 > buf.len) return null;
            const v: f64 = @bitCast(std.mem.readInt(u64, buf[pos..][0..8], .little));
            pos += 8;
            return .{ .value = .{ .float = v }, .pos = pos };
        },
        .text => {
            if (pos + 2 > buf.len) return null;
            const len = std.mem.readInt(u16, buf[pos..][0..2], .big);
            pos += 2;
            if (len > cell_value_max) return null;
            if (pos + len > buf.len) return null;
            const v = buf[pos..][0..len];
            pos += len;
            return .{ .value = .{ .text = v }, .pos = pos };
        },
        .blob => {
            if (pos + 2 > buf.len) return null;
            const len = std.mem.readInt(u16, buf[pos..][0..2], .big);
            pos += 2;
            if (len > cell_value_max) return null;
            if (pos + len > buf.len) return null;
            const v = buf[pos..][0..len];
            pos += len;
            return .{ .value = .{ .blob = v }, .pos = pos };
        },
        .null => {
            return .{ .value = .{ .null = {} }, .pos = pos };
        },
    }
}

// =====================================================================
// Frame IO — length-prefixed binary frames over unix socket
// =====================================================================

/// Read a length-prefixed frame from fd into buf.
/// Returns the payload slice, or null on EOF/error.
pub fn read_frame(fd: std.posix.fd_t, buf: []u8) ?[]const u8 {
    assert(buf.len >= frame_max + 4);

    var header: [4]u8 = undefined;
    if (!recv_exact(fd, &header)) return null;

    const len = std.mem.readInt(u32, &header, .big);
    if (len == 0) return "";
    if (len > frame_max) return null;

    if (!recv_exact(fd, buf[0..len])) return null;
    return buf[0..len];
}

/// Write a length-prefixed frame to fd. Returns false on error.
pub fn write_frame(fd: std.posix.fd_t, payload: []const u8) bool {
    assert(payload.len <= frame_max);

    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .big);

    if (!send_exact(fd, &header)) return false;
    if (payload.len > 0) {
        if (!send_exact(fd, payload)) return false;
    }
    return true;
}

fn recv_exact(fd: std.posix.fd_t, buf: []u8) bool {
    var recvd: usize = 0;
    while (recvd < buf.len) {
        const n = std.posix.recv(fd, buf[recvd..], 0) catch return false;
        if (n == 0) return false;
        recvd += n;
    }
    return true;
}

fn send_exact(fd: std.posix.fd_t, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = std.posix.send(fd, bytes[sent..], std.posix.MSG.NOSIGNAL) catch return false;
        if (n == 0) return false;
        sent += n;
    }
    return true;
}

// =====================================================================
// Tests — fixed-input unit tests
// =====================================================================

test "row set header round trip" {
    var buf: [1024]u8 = undefined;
    const columns = [_]Column{
        .{ .type_tag = .integer, .name = "id" },
        .{ .type_tag = .text, .name = "name" },
        .{ .type_tag = .null, .name = "description" },
    };

    const write_pos = write_row_set_header(&buf, &columns) orelse unreachable;
    const result = read_row_set_header(&buf, 0) orelse unreachable;

    try std.testing.expectEqual(@as(u16, 3), result.count);
    try std.testing.expectEqual(write_pos, result.pos);
    try std.testing.expectEqualStrings("id", result.columns[0].name);
    try std.testing.expectEqual(TypeTag.integer, result.columns[0].type_tag);
    try std.testing.expectEqualStrings("name", result.columns[1].name);
    try std.testing.expectEqual(TypeTag.text, result.columns[1].type_tag);
    try std.testing.expectEqualStrings("description", result.columns[2].name);
    try std.testing.expectEqual(TypeTag.null, result.columns[2].type_tag);
}

test "value round trip — integer" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .integer = -42 }) orelse unreachable;
    const result = read_value(&buf, 0, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, -42), result.value.integer);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — float" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .float = 3.14 }) orelse unreachable;
    const result = read_value(&buf, 0, .float) orelse unreachable;
    try std.testing.expectEqual(@as(f64, 3.14), result.value.float);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — text" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .text = "hello" }) orelse unreachable;
    const result = read_value(&buf, 0, .text) orelse unreachable;
    try std.testing.expectEqualStrings("hello", result.value.text);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — blob" {
    var buf: [64]u8 = undefined;
    const data = &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const pos = write_value(&buf, 0, .{ .blob = data }) orelse unreachable;
    const result = read_value(&buf, 0, .blob) orelse unreachable;
    try std.testing.expectEqualSlices(u8, data, result.value.blob);
    try std.testing.expectEqual(pos, result.pos);
}

test "value round trip — null" {
    var buf: [64]u8 = undefined;
    const pos = write_value(&buf, 0, .{ .null = {} }) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), pos); // null is zero bytes
    const result = read_value(&buf, 0, .null) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), result.pos);
}

test "full row set round trip" {
    var buf: [4096]u8 = undefined;
    const columns = [_]Column{
        .{ .type_tag = .integer, .name = "id" },
        .{ .type_tag = .text, .name = "name" },
        .{ .type_tag = .integer, .name = "price" },
    };

    // Write header + row count + 2 rows.
    var pos = write_row_set_header(&buf, &columns) orelse unreachable;
    pos = write_row_count(&buf, pos, 2) orelse unreachable;

    // Row 1: id=1, name="Widget", price=999
    pos = write_value(&buf, pos, .{ .integer = 1 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "Widget" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = 999 }) orelse unreachable;

    // Row 2: id=2, name="Gadget", price=1999
    pos = write_value(&buf, pos, .{ .integer = 2 }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .text = "Gadget" }) orelse unreachable;
    pos = write_value(&buf, pos, .{ .integer = 1999 }) orelse unreachable;

    // Read back.
    const hdr = read_row_set_header(&buf, 0) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), hdr.count);

    const rc = read_row_count(&buf, hdr.pos) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 2), rc.count);

    var rpos = rc.pos;
    // Row 1
    const r1c1 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), r1c1.value.integer);
    rpos = r1c1.pos;

    const r1c2 = read_value(&buf, rpos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("Widget", r1c2.value.text);
    rpos = r1c2.pos;

    const r1c3 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 999), r1c3.value.integer);
    rpos = r1c3.pos;

    // Row 2
    const r2c1 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), r2c1.value.integer);
    rpos = r2c1.pos;

    const r2c2 = read_value(&buf, rpos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("Gadget", r2c2.value.text);
    rpos = r2c2.pos;

    const r2c3 = read_value(&buf, rpos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1999), r2c3.value.integer);
}

test "read rejects truncated header" {
    var buf = [_]u8{0x00}; // 1 byte, need at least 2
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read rejects invalid type tag" {
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 1, .big); // 1 column
    buf[2] = 0xFF; // invalid type tag
    std.mem.writeInt(u16, buf[3..5], 2, .big); // name len 2
    buf[5] = 'a';
    buf[6] = 'b';
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read rejects column count over max" {
    var buf: [64]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], columns_max + 1, .big);
    try std.testing.expect(read_row_set_header(&buf, 0) == null);
}

test "read_value rejects truncated text" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 100, .big); // claims 100 bytes
    // but buffer only has 4 bytes total
    try std.testing.expect(read_value(&buf, 0, .text) == null);
}

test "frame round trip" {
    const pair = test_socketpair();
    defer std.posix.close(pair[1]);

    const payload = "test payload bytes";
    try std.testing.expect(write_frame(pair[0], payload));

    var buf: [frame_max + 4]u8 = undefined;
    const result = read_frame(pair[1], &buf);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(payload, result.?);
    std.posix.close(pair[0]);
}

fn test_socketpair() [2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    assert(rc == 0);
    return fds;
}
