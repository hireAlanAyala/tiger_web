//! HMAC-SHA256 session-cookie verify primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (the cp-template for every primitive bench in phase C).
//!
//! **Survival:** ~25/43 lines of the template carry over (~60%). The
//! bench harness (Bench init/deinit, PRNG-seeded input, sample loop,
//! estimate, hash-of-run print) is verbatim; kernel call, input
//! shape, and parameter are substituted.
//!
//! Substitutions relative to the template:
//!
//!   - Kernel: `checksum(blob)` → `auth.verify_cookie(cookie, key)`
//!     (full path: length check, separator decode, hex decode user_id
//!     + MAC, HMAC-SHA256 recompute, constant-time compare).
//!   - Input: PRNG-filled aligned blob → fixed 97-byte cookie
//!     produced by `auth.sign_cookie`. `cookie_value_max` is a
//!     protocol constant; varying it is not meaningful.
//!   - Parameter: `bench.parameter("blob_size", KiB, MiB)` removed —
//!     the cookie is fixed-length by the auth protocol, so there's
//!     nothing to parameterize. Plan phase-C.3 asked for "realistic
//!     cookie sizes" (plural) but our cookies are not variable-length.
//!     Plan text rolled forward from TB's template verbatim; our
//!     domain has one size.
//!   - Counter: `u128` checksum accumulator → `u64` verify-success
//!     counter.
//!   - Report format: `"{} for whole blob"` → `"hmac_session = {d} ns"`
//!     (DR-2 — `scripts/devhub.zig`'s `get_measurement` parser).
//!
//! Additions beyond the template (all principled):
//!
//!   - Pair-assertion at test start: the signed cookie must round-trip
//!     through `verify_cookie` and yield the same `user_id`. A
//!     divergence in `sign_cookie`/`verify_cookie` (field order, HMAC
//!     input shape, hex encoding) invalidates every active session
//!     cookie — we want that caught here, not in production under
//!     login traffic.
//!   - `bench.assert_budget` call (same principled divergence
//!     documented in `framework/bench.zig`).
//!
//! **External commitment:** the cookie wire format (97 bytes:
//! 32-hex user_id + separator + 64-hex HMAC) is user-visible. Every
//! active session was signed against this format; changing it
//! invalidates every session and forces re-login. This bench protects
//! the verification-cost property of that commitment — if
//! per-request auth cost blows up, every request slows down.
//!
//! **Actionability:** if ns/call rises >20%, check whether
//! `HmacSha256` stdlib changed, or whether the cookie format grew
//! (e.g., a new field added to the HMAC input). If the pair assertion
//! itself fires, the cookie schema drifted — session invalidation is
//! a user-visible breaking change. If ns/call drops sharply, verify
//! a step wasn't removed (e.g., `timingSafeEql` replaced with a
//! non-constant-time compare); that would be a security regression
//! masquerading as a performance win.
//!
//! **Budget calibration:** 20 µs for one verify call. HMAC-SHA256 on
//! 17-byte input is sub-µs; hex parse of 96 chars is a few hundred
//! ns; expected total ~1–2 µs. 10× headroom gives 20 µs for slow CI.
//! Re-calibrate on ubuntu-22.04 in phase F.

const std = @import("std");
const assert = std.debug.assert;

const auth = @import("framework/auth.zig");

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const repetitions = 35;

const budget_smoke: stdx.Duration = .{ .ns = 20_000 }; // 20 µs per verify

// Fixed test key — only the cookie shape matters for the throughput
// measurement. Not a secret.
const bench_key: *const [auth.key_length]u8 = "tiger-web-bench-hmac-key-0123456";

test "benchmark: hmac_session" {
    var bench: Bench = .init();
    defer bench.deinit();

    var prng = stdx.PRNG.from_seed(bench.seed);
    const user_id: u128 = prng.int(u128) | 1; // non-zero

    var cookie_buf: [auth.cookie_value_max]u8 = undefined;
    const cookie = auth.sign_cookie(&cookie_buf, user_id, .authenticated, bench_key);
    assert(cookie.len == auth.cookie_value_max);

    // Pair-assertion: the signed cookie must round-trip. If this
    // fires, sign_cookie/verify_cookie have drifted — no throughput
    // number from below is meaningful.
    const round_trip = auth.verify_cookie(cookie, bench_key) orelse
        std.debug.panic("hmac_session: sign/verify round-trip failed", .{});
    if (round_trip.user_id != user_id) {
        std.debug.panic(
            "hmac_session: user_id mismatch: got {x}, want {x}",
            .{ round_trip.user_id, user_id },
        );
    }
    if (round_trip.kind != .authenticated) {
        std.debug.panic("hmac_session: kind mismatch after round-trip", .{});
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var verify_counter: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        const result = auth.verify_cookie(cookie, bench_key);
        duration.* = bench.stop();
        if (result) |r| verify_counter +%= @truncate(r.user_id);
    }

    const result = bench.estimate(&duration_samples);

    // See "benchmark: API tutorial" for why the hash-of-run is printed.
    bench.report("verify_counter {x:0>16}", .{verify_counter});
    bench.report("hmac_session = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_smoke, "hmac_session");
}
