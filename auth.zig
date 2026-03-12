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

pub const key_length = HmacSha256.key_length;

/// Fixed-size cache of recently verified tokens. Owned by the server,
/// passed explicitly — no globals. Avoids repeated HMAC-SHA256 for the
/// same token across requests within a tick or across ticks.
pub const TokenCache = struct {
    const cache_size = 256;

    comptime {
        assert(cache_size > 0);
        assert(std.math.isPowerOfTwo(cache_size));
    }

    const Entry = struct {
        sig_hash: u64 = 0,
        sig_bytes: [HmacSha256.mac_length]u8 = [_]u8{0} ** HmacSha256.mac_length,
        sub: u128 = 0,
        exp: u64 = 0,
    };

    entries: [cache_size]Entry = [_]Entry{.{}} ** cache_size,
    next: u8 = 0,

    /// Verify with cache. On hit, skips the HMAC and returns the cached subject.
    /// On miss, falls through to full verify and inserts into the ring.
    pub fn verify_cached(cache: *TokenCache, token: []const u8, now: i64, key: *const [key_length]u8) ?u128 {
        const hash = std.hash.Wyhash.hash(0, token);

        // Decode the signature from the token for exact comparison.
        const sig_bytes = extract_sig(token) orelse return verify(token, now, key);

        // Scan the ring for a matching entry.
        for (&cache.entries) |*entry| {
            if (entry.sig_hash != hash) continue;
            // Hash matched — compare full signature to rule out collisions.
            if (!std.mem.eql(u8, &entry.sig_bytes, &sig_bytes)) continue;

            // Cache hit — check expiry.
            if (now >= entry.exp) {
                entry.* = .{};
                break;
            }
            return entry.sub;
        }

        // Cache miss — full verify.
        const sub = verify(token, now, key) orelse return null;

        // Insert at next ring position, overwriting the oldest entry.
        cache.entries[cache.next] = .{
            .sig_hash = hash,
            .sig_bytes = sig_bytes,
            .sub = sub,
            .exp = parse_exp_from_token(token) orelse return sub,
        };
        cache.next +%= 1;

        return sub;
    }

    /// Extract and decode the base64url signature from a JWT.
    fn extract_sig(token: []const u8) ?[HmacSha256.mac_length]u8 {
        // Find the last '.'.
        const last_dot = std.mem.lastIndexOf(u8, token, ".") orelse return null;
        const sig_b64 = token[last_dot + 1 ..];
        if (sig_b64.len != sig_encoded_len) return null;

        var sig: [HmacSha256.mac_length]u8 = undefined;
        base64url.Decoder.decode(&sig, sig_b64) catch return null;
        return sig;
    }
};

/// Extract the exp claim from a token without full verification.
/// Used by the cache to store expiry after verify has already validated.
fn parse_exp_from_token(token: []const u8) ?u64 {
    const dot1 = std.mem.indexOf(u8, token, ".") orelse return null;
    const rest = token[dot1 + 1 ..];
    const dot2 = std.mem.indexOf(u8, rest, ".") orelse return null;
    const payload_b64 = rest[0..dot2];

    const payload_decoded_len = base64url.Decoder.calcSizeForSlice(payload_b64) catch return null;
    var payload_buf: [256]u8 = undefined;
    if (payload_decoded_len > payload_buf.len) return null;
    base64url.Decoder.decode(payload_buf[0..payload_decoded_len], payload_b64) catch return null;

    return parse_int_claim(u64, payload_buf[0..payload_decoded_len], "\"exp\":");
}

/// Verify a JWT bearer token. Returns the subject (user ID) if valid, null otherwise.
/// Pure function — no IO, no side effects. Caller provides wall-clock time.
pub fn verify(token: []const u8, now: i64, key: *const [key_length]u8) ?u128 {
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
    HmacSha256.create(&expected_sig, signed_data, key);

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
pub fn sign(buf: *[token_max]u8, sub: u128, exp: i64, key: *const [key_length]u8) []const u8 {
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
    HmacSha256.create(&sig, signed_data, key);

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

const test_key: *const [key_length]u8 = "tiger-web-test-key-0123456789ab!";

test "sign and verify round-trip" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000, test_key);
    const sub = verify(token, 1_700_000_000, test_key);
    try std.testing.expectEqual(sub.?, 42);
}

test "verify rejects expired token" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_000_000, test_key);
    // now == exp → expired (now >= exp)
    try std.testing.expect(verify(token, 1_700_000_000, test_key) == null);
    // now > exp → expired
    try std.testing.expect(verify(token, 1_700_100_000, test_key) == null);
}

test "verify rejects tampered token" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000, test_key);
    // Copy to mutable buffer and tamper with one byte in the payload.
    var tampered: [token_max]u8 = undefined;
    @memcpy(tampered[0..token.len], token);
    // Find a byte in the payload section and flip it.
    const dot1 = std.mem.indexOf(u8, token, ".").?;
    tampered[dot1 + 2] ^= 0x01;
    try std.testing.expect(verify(tampered[0..token.len], 1_700_000_000, test_key) == null);
}

test "verify rejects empty and garbage" {
    try std.testing.expect(verify("", 1_700_000_000, test_key) == null);
    try std.testing.expect(verify("not.a.jwt", 1_700_000_000, test_key) == null);
    try std.testing.expect(verify("a.b.c", 1_700_000_000, test_key) == null);
    try std.testing.expect(verify("....", 1_700_000_000, test_key) == null);
}

test "verify rejects truncated signature" {
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000, test_key);
    // Truncate the last byte.
    try std.testing.expect(verify(token[0 .. token.len - 1], 1_700_000_000, test_key) == null);
}

test "sign produces consistent tokens for same input" {
    var buf1: [token_max]u8 = undefined;
    var buf2: [token_max]u8 = undefined;
    const t1 = sign(&buf1, 99, 1_700_200_000, test_key);
    const t2 = sign(&buf2, 99, 1_700_200_000, test_key);
    try std.testing.expectEqualSlices(u8, t1, t2);
}

test "large user ID round-trip" {
    var buf: [token_max]u8 = undefined;
    const big_id: u128 = 340_282_366_920_938_463_463_374_607_431_768_211_455; // u128 max
    const token = sign(&buf, big_id, 1_700_100_000, test_key);
    const sub = verify(token, 1_700_000_000, test_key);
    try std.testing.expectEqual(sub.?, big_id);
}

test "token cache: hit avoids re-verify" {
    var cache: TokenCache = .{};
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000, test_key);

    // First call — cache miss, full verify.
    const sub1 = cache.verify_cached(token, 1_700_000_000, test_key);
    try std.testing.expectEqual(sub1.?, 42);

    // Second call — cache hit, same result.
    const sub2 = cache.verify_cached(token, 1_700_000_000, test_key);
    try std.testing.expectEqual(sub2.?, 42);
}

test "token cache: expired token evicted on hit" {
    var cache: TokenCache = .{};
    var buf: [token_max]u8 = undefined;
    const token = sign(&buf, 42, 1_700_100_000, test_key);

    // Verify while valid — populates cache.
    const sub1 = cache.verify_cached(token, 1_700_000_000, test_key);
    try std.testing.expectEqual(sub1.?, 42);

    // Now expired — cache hit should detect expiry and reject.
    try std.testing.expect(cache.verify_cached(token, 1_700_200_000, test_key) == null);
}

test "token cache: different tokens cached independently" {
    var cache: TokenCache = .{};
    var buf1: [token_max]u8 = undefined;
    var buf2: [token_max]u8 = undefined;
    const t1 = sign(&buf1, 42, 1_700_100_000, test_key);
    const t2 = sign(&buf2, 99, 1_700_100_000, test_key);

    try std.testing.expectEqual(cache.verify_cached(t1, 1_700_000_000, test_key).?, 42);
    try std.testing.expectEqual(cache.verify_cached(t2, 1_700_000_000, test_key).?, 99);
    // Both still cached.
    try std.testing.expectEqual(cache.verify_cached(t1, 1_700_000_000, test_key).?, 42);
    try std.testing.expectEqual(cache.verify_cached(t2, 1_700_000_000, test_key).?, 99);
}

test "token cache: invalid token not cached" {
    var cache: TokenCache = .{};
    try std.testing.expect(cache.verify_cached("garbage", 1_700_000_000, test_key) == null);
    // Cache should still be empty — next slot not advanced.
    try std.testing.expectEqual(cache.next, 0);
}

test "token cache: hash collision does not return wrong user" {
    var cache: TokenCache = .{};
    var buf1: [token_max]u8 = undefined;
    var buf2: [token_max]u8 = undefined;
    const t1 = sign(&buf1, 42, 1_700_100_000, test_key);
    const t2 = sign(&buf2, 99, 1_700_100_000, test_key);

    // Populate cache with user 42's token.
    try std.testing.expectEqual(cache.verify_cached(t1, 1_700_000_000, test_key).?, 42);

    // Forge a collision: overwrite the cached hash with t2's hash,
    // but keep t1's signature bytes. A lookup for t2 should NOT
    // return user 42 because the signature bytes won't match.
    const t2_hash = std.hash.Wyhash.hash(0, t2);
    cache.entries[0].sig_hash = t2_hash;

    // Lookup t2 — hash matches the forged entry, but sig_bytes differ.
    // Should fall through to full verify and return 99.
    try std.testing.expectEqual(cache.verify_cached(t2, 1_700_000_000, test_key).?, 99);
}

test "token cache: ring wraps and overwrites oldest" {
    var cache: TokenCache = .{};
    var buf: [token_max]u8 = undefined;

    // Fill the entire cache.
    for (0..TokenCache.cache_size) |i| {
        const id: u128 = @intCast(i + 1);
        const token = sign(&buf, id, 1_700_100_000, test_key);
        try std.testing.expectEqual(cache.verify_cached(token, 1_700_000_000, test_key).?, id);
    }
    try std.testing.expectEqual(cache.next, 0); // wrapped

    // Insert one more — should overwrite slot 0.
    const new_token = sign(&buf, 999, 1_700_100_000, test_key);
    try std.testing.expectEqual(cache.verify_cached(new_token, 1_700_000_000, test_key).?, 999);
    try std.testing.expectEqual(cache.next, 1);
}
