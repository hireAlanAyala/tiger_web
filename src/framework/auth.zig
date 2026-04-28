const std = @import("std");
const assert = std.debug.assert;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

pub const key_length = HmacSha256.key_length;

// --- Cookie-based identity ---

pub const CookieKind = enum(u8) {
    anonymous = 0,
    authenticated = 1,
};

/// Cookie name used for identity.
pub const cookie_name = "tiger_id";

/// Cookie value: 32-hex user_id + separator + 64-hex HMAC = 97 bytes.
/// Anonymous uses '.' separator, authenticated uses '-'.
pub const cookie_value_max = 32 + 1 + 64;

const cookie_suffix = "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n";
const clear_cookie_suffix = "; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\n";

/// Full Set-Cookie header line including CRLF.
pub const set_cookie_header_max = "Set-Cookie: ".len + cookie_name.len + "=".len +
    cookie_value_max + cookie_suffix.len;

/// Clear-Cookie header: same structure but Max-Age=0.
pub const clear_cookie_header_max = "Set-Cookie: ".len + cookie_name.len + "=".len +
    cookie_value_max + clear_cookie_suffix.len;

comptime {
    assert(cookie_value_max == 97);
    assert(set_cookie_header_max == 170);
}

/// Sign a cookie value: "<32-hex-user_id><sep><64-hex-hmac>".
/// Anonymous uses '.', authenticated uses '-'.
/// Returns a slice into buf.
pub fn sign_cookie(buf: *[cookie_value_max]u8, user_id: u128, kind: CookieKind, key: *const [key_length]u8) []const u8 {
    assert(user_id != 0);

    // Write user_id as 32 lowercase hex chars.
    var uid_bytes: [16]u8 = @bitCast(@byteSwap(user_id));
    write_hex(buf[0..32], &uid_bytes);

    buf[32] = switch (kind) {
        .anonymous => '.',
        .authenticated => '-',
    };

    // HMAC-SHA256 over kind byte + raw user_id bytes.
    var input: [17]u8 = undefined;
    input[0] = @intFromEnum(kind);
    @memcpy(input[1..17], &uid_bytes);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, &input, key);
    write_hex(buf[33..97], &mac);

    return buf[0..cookie_value_max];
}

pub const VerifyResult = struct {
    user_id: u128,
    kind: CookieKind,
};

/// Verify a cookie value. Returns the user_id and kind if valid, null otherwise.
pub fn verify_cookie(value: []const u8, key: *const [key_length]u8) ?VerifyResult {
    if (value.len != cookie_value_max) return null;

    const kind: CookieKind = switch (value[32]) {
        '.' => .anonymous,
        '-' => .authenticated,
        else => return null,
    };

    // Parse the hex user_id.
    const uid_bytes = parse_hex(16, value[0..32]) orelse return null;
    const user_id: u128 = @byteSwap(@as(u128, @bitCast(uid_bytes)));
    if (user_id == 0) return null;

    // Parse the hex HMAC.
    const claimed_mac = parse_hex(HmacSha256.mac_length, value[33..97]) orelse return null;

    // Recompute HMAC with kind byte + uid bytes.
    var input: [17]u8 = undefined;
    input[0] = @intFromEnum(kind);
    @memcpy(input[1..17], &uid_bytes);
    var expected_mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_mac, &input, key);

    if (!std.crypto.utils.timingSafeEql([HmacSha256.mac_length]u8, expected_mac, claimed_mac)) {
        return null;
    }

    return .{ .user_id = user_id, .kind = kind };
}

/// Format the full "Set-Cookie: tiger_id=<value>; Path=/; HttpOnly; SameSite=Lax\r\n" header.
/// Returns a slice into buf.
pub fn format_set_cookie_header(buf: *[set_cookie_header_max]u8, user_id: u128, kind: CookieKind, key: *const [key_length]u8) []const u8 {
    var pos: usize = 0;

    const prefix = "Set-Cookie: " ++ cookie_name ++ "=";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var cookie_buf: [cookie_value_max]u8 = undefined;
    const cookie_val = sign_cookie(&cookie_buf, user_id, kind, key);
    @memcpy(buf[pos..][0..cookie_val.len], cookie_val);
    pos += cookie_val.len;

    @memcpy(buf[pos..][0..cookie_suffix.len], cookie_suffix);
    pos += cookie_suffix.len;

    assert(pos == set_cookie_header_max);
    return buf[0..pos];
}

/// Format a clear-cookie header (Max-Age=0) for logout.
pub fn format_clear_cookie_header(buf: *[clear_cookie_header_max]u8, user_id: u128, kind: CookieKind, key: *const [key_length]u8) []const u8 {
    var pos: usize = 0;

    const prefix = "Set-Cookie: " ++ cookie_name ++ "=";
    @memcpy(buf[pos..][0..prefix.len], prefix);
    pos += prefix.len;

    var cookie_buf: [cookie_value_max]u8 = undefined;
    const cookie_val = sign_cookie(&cookie_buf, user_id, kind, key);
    @memcpy(buf[pos..][0..cookie_val.len], cookie_val);
    pos += cookie_val.len;

    @memcpy(buf[pos..][0..clear_cookie_suffix.len], clear_cookie_suffix);
    pos += clear_cookie_suffix.len;

    assert(pos == clear_cookie_header_max);
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

test "sign_cookie and verify_cookie round-trip anonymous" {
    var buf: [cookie_value_max]u8 = undefined;
    const val = sign_cookie(&buf, 42, .anonymous, test_key);
    try std.testing.expectEqual(val.len, cookie_value_max);
    const result = verify_cookie(val, test_key).?;
    try std.testing.expectEqual(result.user_id, 42);
    try std.testing.expectEqual(result.kind, .anonymous);
    try std.testing.expectEqual(val[32], '.');
}

test "sign_cookie and verify_cookie round-trip authenticated" {
    var buf: [cookie_value_max]u8 = undefined;
    const val = sign_cookie(&buf, 42, .authenticated, test_key);
    const result = verify_cookie(val, test_key).?;
    try std.testing.expectEqual(result.user_id, 42);
    try std.testing.expectEqual(result.kind, .authenticated);
    try std.testing.expectEqual(val[32], '-');
}

test "anonymous and authenticated cookies are not interchangeable" {
    var buf_anon: [cookie_value_max]u8 = undefined;
    var buf_auth: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf_anon, 42, .anonymous, test_key);
    _ = sign_cookie(&buf_auth, 42, .authenticated, test_key);
    // Same user_id but different HMAC — swapping separator breaks verification.
    buf_anon[32] = '-';
    try std.testing.expect(verify_cookie(&buf_anon, test_key) == null);
    buf_auth[32] = '.';
    try std.testing.expect(verify_cookie(&buf_auth, test_key) == null);
}

test "verify_cookie rejects tampered value" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, .anonymous, test_key);
    buf[50] ^= 0x01;
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects zero user_id" {
    var buf: [cookie_value_max]u8 = undefined;
    @memset(buf[0..32], '0');
    buf[32] = '.';
    var input: [17]u8 = undefined;
    input[0] = @intFromEnum(CookieKind.anonymous);
    @memset(input[1..17], 0);
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, &input, test_key);
    write_hex(buf[33..97], &mac);
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects wrong length" {
    try std.testing.expect(verify_cookie("too-short", test_key) == null);
    try std.testing.expect(verify_cookie("", test_key) == null);
}

test "verify_cookie rejects invalid separator" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, .anonymous, test_key);
    buf[32] = 'x';
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "verify_cookie rejects invalid hex" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, .anonymous, test_key);
    buf[0] = 'z';
    try std.testing.expect(verify_cookie(&buf, test_key) == null);
}

test "large user_id round-trip" {
    var buf: [cookie_value_max]u8 = undefined;
    const big: u128 = std.math.maxInt(u128);
    const val = sign_cookie(&buf, big, .anonymous, test_key);
    const result = verify_cookie(val, test_key).?;
    try std.testing.expectEqual(result.user_id, big);
}

test "format_set_cookie_header produces valid header" {
    var buf: [set_cookie_header_max]u8 = undefined;
    const hdr = format_set_cookie_header(&buf, 42, .anonymous, test_key);
    try std.testing.expect(std.mem.startsWith(u8, hdr, "Set-Cookie: tiger_id="));
    try std.testing.expect(std.mem.endsWith(u8, hdr, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n"));
    const prefix = "Set-Cookie: tiger_id=";
    const suffix = "; Path=/; HttpOnly; SameSite=Lax; Max-Age=31536000\r\n";
    const cookie_val = hdr[prefix.len .. hdr.len - suffix.len];
    try std.testing.expectEqual(verify_cookie(cookie_val, test_key).?.user_id, 42);
}

test "format_clear_cookie_header has Max-Age=0" {
    var buf: [clear_cookie_header_max]u8 = undefined;
    const hdr = format_clear_cookie_header(&buf, 42, .authenticated, test_key);
    try std.testing.expect(std.mem.endsWith(u8, hdr, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=0\r\n"));
}

test "verify_cookie accepts uppercase hex" {
    var buf: [cookie_value_max]u8 = undefined;
    _ = sign_cookie(&buf, 42, .anonymous, test_key);
    for (buf[0..32]) |*c| {
        if (c.* >= 'a' and c.* <= 'f') c.* = c.* - 32;
    }
    for (buf[33..97]) |*c| {
        if (c.* >= 'a' and c.* <= 'f') c.* = c.* - 32;
    }
    try std.testing.expectEqual(verify_cookie(&buf, test_key).?.user_id, 42);
}

test "sign_cookie consistency" {
    var buf1: [cookie_value_max]u8 = undefined;
    var buf2: [cookie_value_max]u8 = undefined;
    const v1 = sign_cookie(&buf1, 99, .anonymous, test_key);
    const v2 = sign_cookie(&buf2, 99, .anonymous, test_key);
    try std.testing.expectEqualSlices(u8, v1, v2);
}
