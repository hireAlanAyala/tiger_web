const std = @import("std");
const assert = std.debug.assert;

/// `maybe` is the dual of `assert`: it signals that a condition is sometimes
/// true and sometimes false, and that's fine. Pure documentation — compiles
/// to a tautology. See TigerBeetle's stdx.maybe().
pub fn maybe(ok: bool) void {
    assert(ok or !ok);
}

/// Maximum key size in bytes.
pub const key_max = 256;

/// Maximum value size in bytes.
pub const value_max = 64 * 1024;

/// Size of request and response headers.
pub const header_size = 8;

/// Maximum total message size (header + key + value).
pub const message_max = header_size + key_max + value_max;

pub const Operation = enum(u8) {
    get = 1,
    put = 2,
    delete = 3,

    fn valid(byte: u8) bool {
        return byte >= 1 and byte <= 3;
    }
};

pub const Status = enum(u8) {
    ok = 1,
    not_found = 2,
    err = 3,
};

pub const RequestHeader = extern struct {
    operation: Operation,
    _reserved: u8 = 0,
    key_len: u16,
    value_len: u32,

    comptime {
        assert(@sizeOf(RequestHeader) == header_size);
    }

    pub fn body_len(self: RequestHeader) u32 {
        return @as(u32, self.key_len) + self.value_len;
    }

    pub fn total_len(self: RequestHeader) u32 {
        return header_size + self.body_len();
    }
};

pub const ResponseHeader = extern struct {
    status: Status,
    _reserved: [3]u8 = .{ 0, 0, 0 },
    value_len: u32,

    comptime {
        assert(@sizeOf(ResponseHeader) == header_size);
    }

    pub fn total_len(self: ResponseHeader) u32 {
        return header_size + self.value_len;
    }
};

pub const Request = struct {
    header: RequestHeader,
    key: []const u8,
    value: []const u8,
};

pub const Response = struct {
    header: ResponseHeader,
    value: []const u8,
};

/// Decode a request from a buffer. Returns null if the buffer is too small
/// or the message is malformed.
pub fn decode_request(buf: []const u8) ?Request {
    if (buf.len < header_size) return null;

    const header: RequestHeader = @bitCast(buf[0..header_size].*);

    // Validate operation.
    if (!Operation.valid(@intFromEnum(header.operation))) return null;

    // Validate key length.
    if (header.key_len == 0) return null;
    if (header.key_len > key_max) return null;

    // Validate value length.
    if (header.value_len > value_max) return null;

    // Put must have a value; get and delete must not.
    switch (header.operation) {
        .put => if (header.value_len == 0) return null,
        .get, .delete => if (header.value_len != 0) return null,
    }

    const total = header.total_len();
    if (buf.len < total) return null;

    const key_start = header_size;
    const key_end = key_start + header.key_len;
    const value_end = key_end + header.value_len;

    return .{
        .header = header,
        .key = buf[key_start..key_end],
        .value = buf[key_end..value_end],
    };
}

/// Encode a request into a buffer. Returns the slice of buf that was written.
pub fn encode_request(buf: []u8, operation: Operation, key: []const u8, value: []const u8) []const u8 {
    assert(key.len > 0);
    assert(key.len <= key_max);
    assert(value.len <= value_max);

    switch (operation) {
        .put => assert(value.len > 0),
        .get, .delete => assert(value.len == 0),
    }

    const header = RequestHeader{
        .operation = operation,
        .key_len = @intCast(key.len),
        .value_len = @intCast(value.len),
    };

    const total = header.total_len();
    assert(buf.len >= total);

    buf[0..header_size].* = @bitCast(header);
    @memcpy(buf[header_size..][0..key.len], key);
    if (value.len > 0) {
        @memcpy(buf[header_size + key.len ..][0..value.len], value);
    }

    return buf[0..total];
}

/// Encode a response into a buffer. Returns the slice of buf that was written.
pub fn encode_response(buf: []u8, status: Status, value: []const u8) []const u8 {
    assert(value.len <= value_max);

    const header = ResponseHeader{
        .status = status,
        .value_len = @intCast(value.len),
    };

    const total = header.total_len();
    assert(buf.len >= total);

    buf[0..header_size].* = @bitCast(header);
    if (value.len > 0) {
        @memcpy(buf[header_size..][0..value.len], value);
    }

    return buf[0..total];
}

/// Decode a response from a buffer. Returns null if the buffer is too small.
pub fn decode_response(buf: []const u8) ?Response {
    if (buf.len < header_size) return null;

    const header: ResponseHeader = @bitCast(buf[0..header_size].*);

    if (header.value_len > value_max) return null;

    const total = header.total_len();
    if (buf.len < total) return null;

    return .{
        .header = header,
        .value = buf[header_size..][0..header.value_len],
    };
}

test "encode decode request roundtrip" {
    var buf: [message_max]u8 = undefined;

    // Put
    const encoded_put = encode_request(&buf, .put, "hello", "world");
    const decoded_put = decode_request(encoded_put).?;
    try std.testing.expectEqual(decoded_put.header.operation, .put);
    try std.testing.expectEqualSlices(u8, decoded_put.key, "hello");
    try std.testing.expectEqualSlices(u8, decoded_put.value, "world");

    // Get
    const encoded_get = encode_request(&buf, .get, "hello", "");
    const decoded_get = decode_request(encoded_get).?;
    try std.testing.expectEqual(decoded_get.header.operation, .get);
    try std.testing.expectEqualSlices(u8, decoded_get.key, "hello");
    try std.testing.expectEqual(decoded_get.value.len, 0);

    // Delete
    const encoded_del = encode_request(&buf, .delete, "hello", "");
    const decoded_del = decode_request(encoded_del).?;
    try std.testing.expectEqual(decoded_del.header.operation, .delete);
}

test "encode decode response roundtrip" {
    var buf: [message_max]u8 = undefined;

    const encoded = encode_response(&buf, .ok, "world");
    const decoded = decode_response(encoded).?;
    try std.testing.expectEqual(decoded.header.status, .ok);
    try std.testing.expectEqualSlices(u8, decoded.value, "world");
}

test "decode rejects malformed requests" {
    // Too short.
    try std.testing.expectEqual(decode_request(""), null);
    try std.testing.expectEqual(decode_request("short"), null);

    // Invalid operation.
    var buf: [header_size]u8 = .{0} ** header_size;
    buf[0] = 0; // invalid operation
    try std.testing.expectEqual(decode_request(&buf), null);

    // Zero key length.
    buf[0] = 1; // get
    buf[2] = 0;
    buf[3] = 0; // key_len = 0
    try std.testing.expectEqual(decode_request(&buf), null);
}
