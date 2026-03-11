const std = @import("std");
const assert = std.debug.assert;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const base64url = std.base64.url_safe_no_pad;

/// Maximum encoded JWT length.
/// Header (~36) + "." + payload (~80) + "." + signature (~43) = ~162.
pub const token_max = 256;

/// HMAC-SHA256 produces 32 bytes; base64url encodes to 43 characters.
const sig_encoded_len = base64url.Encoder.calcSize(HmacSha256.mac_length);

/// Fixed base64url-encoded header: {"alg":"HS256","typ":"JWT"}
const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// Server secret key. In production, load from config or environment.
/// 32 bytes — matches HMAC-SHA256 recommended key length.
const secret_key = "tiger-web-secret-key-change-me!!";

comptime {
    assert(secret_key.len == HmacSha256.key_length);
}

/// Verify a JWT bearer token. Returns the subject (user ID) if valid, null otherwise.
/// Pure function — no IO, no side effects. Caller provides wall-clock time.
pub fn verify(token: []const u8, now: i64) ?u128 {
    if (token.len == 0) return null;
    if (token.len > token_max) return null;

    // Find the two '.' separators.
    const dot1 = std.mem.indexOf(u8, token, ".") orelse return null;
    const rest = token[dot1 + 1 ..];
    const dot2 = std.mem.indexOf(u8, rest, ".") orelse return null;

    const payload_b64 = rest[0..dot2];
    const sig_b64 = rest[dot2 + 1 ..];
    const signed_data = token[0 .. dot1 + 1 + dot2];

    // Verify signature — recompute HMAC and compare.
    var expected_sig: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&expected_sig, signed_data, secret_key);

    if (sig_b64.len != sig_encoded_len) return null;
    var actual_sig: [HmacSha256.mac_length]u8 = undefined;
    base64url.Decoder.decode(&actual_sig, sig_b64) catch return null;

    if (!std.crypto.utils.timingSafeEql([HmacSha256.mac_length]u8, expected_sig, actual_sig)) {
        return null;
    }

    // Decode payload.
    const payload_decoded_len = base64url.Decoder.calcSizeForSlice(payload_b64) catch return null;
    var payload_buf: [256]u8 = undefined;
    if (payload_decoded_len > payload_buf.len) return null;
    base64url.Decoder.decode(payload_buf[0..payload_decoded_len], payload_b64) catch return null;
    const payload = payload_buf[0..payload_decoded_len];

    // Parse claims.
    const exp = parse_int_claim(u64, payload, "\"exp\":") orelse return null;
    if (now >= exp) return null;

    const sub = parse_int_claim(u128, payload, "\"sub\":") orelse return null;
    if (sub == 0) return null;

    return sub;
}

/// Create a signed JWT for the given user ID and expiry time.
/// Returns the token as a slice into the provided buffer.
pub fn sign(buf: *[token_max]u8, sub: u128, exp: i64) []const u8 {
    assert(sub > 0);
    assert(exp > 0);
    var pos: usize = 0;

    // Header.
    @memcpy(buf[pos..][0..header_b64.len], header_b64);
    pos += header_b64.len;
    buf[pos] = '.';
    pos += 1;

    // Build payload JSON: {"sub":<id>,"exp":<timestamp>}
    var payload_buf: [128]u8 = undefined;
    var payload_pos: usize = 0;
    const prefix = "{\"sub\":";
    @memcpy(payload_buf[payload_pos..][0..prefix.len], prefix);
    payload_pos += prefix.len;
    payload_pos += format_u128(&payload_buf, payload_pos, sub);
    const mid = ",\"exp\":";
    @memcpy(payload_buf[payload_pos..][0..mid.len], mid);
    payload_pos += mid.len;
    payload_pos += format_i64(&payload_buf, payload_pos, exp);
    payload_buf[payload_pos] = '}';
    payload_pos += 1;

    // Base64url encode payload.
    const payload_b64_len = base64url.Encoder.calcSize(payload_pos);
    const payload_b64 = base64url.Encoder.encode(buf[pos..][0..payload_b64_len], payload_buf[0..payload_pos]);
    pos += payload_b64.len;

    // Sign header.payload.
    const signed_data = buf[0..pos];
    var sig: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&sig, signed_data, secret_key);

    buf[pos] = '.';
    pos += 1;

    // Base64url encode signature.
    const sig_b64 = base64url.Encoder.encode(buf[pos..][0..sig_encoded_len], &sig);
    pos += sig_b64.len;

    return buf[0..pos];
}

/// Parse an integer value from a JSON claim like `"exp":1700003600`.
/// Minimal hand-rolled parser — no std.fmt, no allocations.
fn parse_int_claim(comptime T: type, payload: []const u8, key: []const u8) ?T {
    const key_pos = std.mem.indexOf(u8, payload, key) orelse return null;
    const val_start = key_pos + key.len;
    if (val_start >= payload.len) return null;

    var val: T = 0;
    var i = val_start;
    if (i >= payload.len or payload[i] < '0' or payload[i] > '9') return null;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') : (i += 1) {
        val = val *% 10 +% (payload[i] - '0');
    }
    return val;
}

/// Format a u128 as decimal into buf at the given offset. Returns bytes written.
fn format_u128(buf: []u8, offset: usize, val: u128) usize {
    if (val == 0) {
        buf[offset] = '0';
        return 1;
    }
    var tmp: [40]u8 = undefined; // u128 max is 39 digits
    var tmp_pos: usize = 40;
    var v = val;
    while (v > 0) {
        tmp_pos -= 1;
        tmp[tmp_pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    const len = 40 - tmp_pos;
    @memcpy(buf[offset..][0..len], tmp[tmp_pos..40]);
    return len;
}

/// Format an i64 as decimal into buf at the given offset. Returns bytes written.
fn format_i64(buf: []u8, offset: usize, val: i64) usize {
    assert(val > 0);
    var tmp: [20]u8 = undefined;
    var tmp_pos: usize = 20;
    var v: u64 = @intCast(val);
    while (v > 0) {
        tmp_pos -= 1;
        tmp[tmp_pos] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    const len = 20 - tmp_pos;
    @memcpy(buf[offset..][0..len], tmp[tmp_pos..20]);
    return len;
}

// =====================================================================
// Tests
// =====================================================================

test "sign and verify round-trip" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000);
    const sub = verify(token, 1_700_000_000);
    try std.testing.expectEqual(sub.?, 42);
}

test "verify rejects expired token" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_000_000);
    // now == exp → expired (now >= exp)
    try std.testing.expect(verify(token, 1_700_000_000) == null);
    // now > exp → expired
    try std.testing.expect(verify(token, 1_700_100_000) == null);
}

test "verify rejects tampered token" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000);
    // Copy to mutable buffer and tamper with one byte in the payload.
    var tampered: [token_max]u8 = undefined;
    @memcpy(tampered[0..token.len], token);
    // Find a byte in the payload section and flip it.
    const dot1 = std.mem.indexOf(u8, token, ".").?;
    tampered[dot1 + 2] ^= 0x01;
    try std.testing.expect(verify(tampered[0..token.len], 1_700_000_000) == null);
}

test "verify rejects empty and garbage" {
    try std.testing.expect(verify("", 1_700_000_000) == null);
    try std.testing.expect(verify("not.a.jwt", 1_700_000_000) == null);
    try std.testing.expect(verify("a.b.c", 1_700_000_000) == null);
    try std.testing.expect(verify("....", 1_700_000_000) == null);
}

test "verify rejects truncated signature" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000);
    // Truncate the last byte.
    try std.testing.expect(verify(token[0 .. token.len - 1], 1_700_000_000) == null);
}

test "sign produces consistent tokens for same input" {
    var buf1: [token_max]u8 = undefined;
    var buf2: [token_max]u8 = undefined;
    const t1 = sign(&buf1, 99, 1_700_200_000);
    const t2 = sign(&buf2, 99, 1_700_200_000);
    try std.testing.expectEqualSlices(u8, t1, t2);
}

test "large user ID round-trip" {
    var buf: [token_max]u8 = undefined;
    const big_id: u128 = 340_282_366_920_938_463_463_374_607_431_768_211_455; // u128 max
    const token = sign(&buf, big_id, 1_700_100_000);
    const sub = verify(token, 1_700_000_000);
    try std.testing.expectEqual(sub.?, big_id);
}
