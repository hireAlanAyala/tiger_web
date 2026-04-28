//! Aegis128L-based checksum, following TigerBeetle's vsr/checksum.zig.
//!
//! Specialized from AEAD → MAC → checksum by using a zero key and zero nonce.
//! Hardware-accelerated via AES-NI (vaesenc/vaesdec instructions).
//!
//! Used by the WAL to detect bitrot and hash-chain entries.

const std = @import("std");

const Aegis128LMac_128 = std.crypto.auth.aegis.Aegis128LMac_128;

var seed_once = std.once(seed_init);
var seed_state: Aegis128LMac_128 = undefined;

fn seed_init() void {
    const key: [16]u8 = @splat(0);
    seed_state = Aegis128LMac_128.init(&key);
}

pub fn checksum(source: []const u8) u128 {
    var stream = ChecksumStream.init();
    stream.add(source);
    return stream.finish();
}

pub const ChecksumStream = struct {
    state: Aegis128LMac_128,

    pub fn init() ChecksumStream {
        seed_once.call();
        return ChecksumStream{ .state = seed_state };
    }

    pub fn add(stream: *ChecksumStream, bytes: []const u8) void {
        stream.state.update(bytes);
    }

    pub fn finish(stream: *ChecksumStream) u128 {
        var result: [16]u8 = undefined;
        stream.state.final(&result);
        stream.* = undefined;
        return @bitCast(result);
    }
};

// =====================================================================
// Tests
// =====================================================================

test "checksum deterministic" {
    const a = checksum("hello");
    const b = checksum("hello");
    try std.testing.expectEqual(a, b);
}

test "checksum distinct" {
    const a = checksum("hello");
    const b = checksum("world");
    try std.testing.expect(a != b);
}

test "checksum empty" {
    const c = checksum("");
    try std.testing.expect(c != 0);
}

test "checksum single bit flip" {
    var buf = [_]u8{0} ** 64;
    const base = checksum(&buf);
    buf[0] = 1;
    const flipped = checksum(&buf);
    try std.testing.expect(base != flipped);
}

// Change detector — if the checksum function changes (different key,
// different Aegis variant, endianness), this test catches it.
// Matches TigerBeetle's "checksum stability" pattern.
test "checksum stability" {
    try std.testing.expectEqual(checksum(""), 0x635037DBB2B81E9BF114D2092A5AA1AD);
    try std.testing.expectEqual(checksum(&([_]u8{0} ** 16)), 0x9CB583709438F5BE0C1866DE93AD9818);
    try std.testing.expectEqual(checksum("hello"), 0x945F96D02A647D7281BA51BB5EC83553);
}
