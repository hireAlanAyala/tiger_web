const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const key_length = HmacSha256.key_length;

// --- Cookie-based identity ---

/// Cookie name used for anonymous identity.
pub const cookie_name = "tiger_id";

/// Cookie value: 32-hex user_id + "." + 64-hex HMAC = 97 bytes.
pub const cookie_value_max = 32 + 1 + 64;

/// Full Set-Cookie header line including CRLF.
pub const set_cookie_header_max = "Set-Cookie: ".len + cookie_name.len + "=".len +
    cookie_value_max + "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n".len;

comptime {
    assert(cookie_value_max == 97);
    assert(set_cookie_header_max == 170);
}

/// Sign a cookie value: "<32-hex-user_id>.<64-hex-hmac>".
/// Returns a slice into buf.
pub fn sign_cookie(buf: *[cookie_value_max]u8, user_id: u128, key: *const [key_length]u8) []const u8 {
    assert(user_id != 0);

    // Write user_id as 32 lowercase hex chars.
    var uid_bytes: [16]u8 = @bitCast(@byteSwap(user_id));
    write_hex(buf[0..32], &uid_bytes);

    buf[32] = '.';

    // HMAC-SHA256 over the raw user_id bytes (not the hex string).
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, &uid_bytes, key);
    write_hex(buf[33..97], &mac);

    return buf[0..cookie_value_max];
}

/// Verify a cookie value. Returns the user_id if valid, null otherwise.
pub fn verify_cookie(value: []const u8, key: *const [key_length]u8) ?u128 {
    if (value.len != cookie_value_max) return null;
    if (value[32] != '.') return null;

    // Parse the hex user_id.
    const uid_bytes = parse_hex(16, value[0..32]) orelse return null;
    const user_id: u128 = @byteSwap(@as(u128, @bitCast(uid_bytes)));
    if (user_id == 0) return null;

    // Parse the hex HMAC.
    const claimed_mac = parse_hex(HmacSha256.mac_length, value[33..97]) orelse return null;

    // Recompute HMAC and compare.
    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, &uid_bytes, key);

    if (!std.crypto.utils.timingSafeEql([HmacSha256.mac_length]u8, expected_mac, claimed_mac)) {
        return null;
    }

    return user_id;
}

/// Format the full "Set-Cookie: tiger_id=<value>; Path=/; HttpOnly; SameSite=Lax\r\n" header.
/// Returns a slice into buf.
pub fn format_set_cookie_header(buf: *[set_cookie_header_max]u8, user_id: u128, key: *const [key_length]u8) []const u8 {
    var pos: usize = 0;

    const prefix = "Set-Cookie: " ++ cookie_name ++ "=";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var cookie_buf: [cookie_value_max]u8 = undefined;
    const cookie_val = sign_cookie(&cookie_buf, user_id, key);
    @memcpy(buf[pos..][0..cookie_val.len], cookie_val);
    pos += cookie_val.len;

    const suffix = "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n";
    @memcpy(buf[pos..][0..suffix.len], suffix);
    pos += suffix.len;

    assert(pos == set_cookie_header_max);
    return buf[0..pos];
}

// --- Hex helpers ---

/// Write bytes as lowercase hex into an output buffer.
fn write_hex(out: []u8, bytes: []const u8) void {
    assert(out.len == bytes.len * 2);
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
}

/// Parse a hex string into a fixed-size byte array. Returns null on invalid hex.
fn parse_hex(comptime N: usize, input: *const [N * 2]u8) ?[N]u8 {
    var result: [N]u8 = undefined;
    for (0..N) |i| {
        const hi = hex_digit(input[i * 2]) orelse return null;
        const lo = hex_digit(input[i * 2 + 1]) orelse return null;
        result[i] = (hi << 4) | lo;
    }
    return result;
}

fn hex_digit(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// =====================================================================
// Tests
// =====================================================================

const test_key: *const [key_length]u8 = "tiger-web-test-key-0123456789ab!";

test "sign_cookie and verify_cookie round-trip" {
    var buf: [cookie_value_max]u8 = undefined;
    const val = sign_cookie(&buf, 42, test_key);
    try std.testing.expectEqual(val.len, cookie_value_max);
    const uid = verify_cookie(val, test_key);
    try std.testing.expectEqual(uid.?, 42);
}

test "verify_cookie rejects tampered value" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, test_key);
    // Flip a byte in the HMAC portion.
    buf[50] ^= 0x01;
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects zero user_id" {
    // Manually construct a cookie with user_id=0.
    // sign_cookie asserts != 0, so we build it by hand.
    var buf: [cookie_value_max]u8 = undefined;
    @memset(buf[0..32], '0'); // all-zero hex
    buf[32] = '.';
    // Compute valid HMAC for the zero bytes.
    var uid_bytes: [16]u8 = .{0} ** 16;
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, &uid_bytes, test_key);
    write_hex(buf[33..97], &mac);
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects wrong length" {
    try std.testing.expect(verify_cookie("too-short", test_key) == null);
    try std.testing.expect(verify_cookie("", test_key) == null);
}

test "verify_cookie rejects missing dot" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, test_key);
    buf[32] = 'x'; // replace dot
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects invalid hex" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, test_key);
    buf[0] = 'z'; // invalid hex char
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "large user_id round-trip" {
    var buf: [cookie_value_max]u8 = undefined;
    const big: u128 = std.math.maxInt(u128);
    const val = sign_cookie(&buf, big, test_key);
    const uid = verify_cookie(val, test_key);
    try std.testing.expectEqual(uid.?, big);
}

test "format_set_cookie_header produces valid header" {
    var buf: [set_cookie_header_max]u8 = undefined;
    const hdr = format_set_cookie_header(&buf, 42, test_key);
    try std.testing.expect(std.mem.startsWith(u8, hdr, "Set-Cookie: tiger_id="));
    try std.testing.expect(std.mem.endsWith(u8, hdr, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n"));
    // The cookie value within should verify.
    const prefix = "Set-Cookie: tiger_id=";
    const suffix = "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n";
    const cookie_val = hdr[prefix.len .. hdr.len - suffix.len];
    try std.testing.expectEqual(verify_cookie(cookie_val, test_key).?, 42);
}

test "verify_cookie accepts uppercase hex" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, test_key);
    // Uppercase the user_id hex portion.
    for (buf[0..32]) |*c| {
        if (c.* >= 'a' and c.* <= 'f') c.* = c.* - 32;
    }
    // Uppercase the HMAC hex portion.
    for (buf[33..97]) |*c| {
        if (c.* >= 'a' and c.* <= 'f') c.* = c.* - 32;
    }
    // Must still verify — browsers don't modify cookie values, but
    // a proxy or test tool might normalize case.
    try std.testing.expectEqual(verify_cookie(&buf, test_key).?, 42);
}

test "sign_cookie consistency" {
    var buf1: [cookie_value_max]u8 = undefined;
    var buf2: [cookie_value_max]u8 = undefined;
    const v1 = sign_cookie(&buf1, 99, test_key);
    const v2 = sign_cookie(&buf2, 99, test_key);
    try std.testing.expectEqualSlices(u8, v1, v2);
}
