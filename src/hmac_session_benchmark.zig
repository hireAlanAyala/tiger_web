//! HMAC-SHA256 session-cookie verify primitive benchmark.
//!
//! **Port:** `cp` of TigerBeetle's `src/vsr/checksum_benchmark.zig`,
//! trimmed. Diff against TB's file is the audit trail.
//!
//! **Edits vs TB's original:**
//!
//!   - Import paths rewritten for our layout (principled).
//!   - Kernel: `checksum(blob)` → `auth.verify_cookie(cookie, key)`
//!     (principled — our domain).
//!   - `cache_line_size` + arena + `alignedAlloc` removed (principled
//!     — cookie is stack-allocated, fixed length).
//!   - `blob_size` parameter removed (principled — cookie is
//!     fixed-length by auth protocol, `auth.cookie_value_max = 97`).
//!   - `KiB`/`MiB` removed (same reason).
//!   - Counter `u128` → `u64` sum (principled).
//!   - Report format per DR-2.
//!   - Pair-assertions added (flaw fix — TIGER_STYLE golden rule):
//!     positive round-trip recovers `user_id` + `kind`; negative
//!     tampered cookie (flipped bit in HMAC tail) returns `null`.
//!     The negative check is the security property — if verify
//!     ever accepts tampered cookies, throughput is irrelevant.
//!   - `bench.assert_budget` call (flaw fix — documented in
//!     `framework/bench.zig`).
//!
//! **External commitment:** cookie wire format (97 bytes) is
//! user-visible. Changing it invalidates every active session.
//!
//! **Actionability:** if ns/call rises >20%, check `HmacSha256`
//! stdlib changes or cookie format growth. If the positive
//! pair-assertion fires, cookie schema drifted — every session
//! invalidates. If the *negative* pair-assertion fires, verify is
//! accepting tampered input — security regression, not performance.
//! If ns/call drops sharply without a known optimization, verify
//! a step wasn't removed (e.g., `timingSafeEql` replaced with a
//! non-constant-time compare).
//!
//! **Budget:** `docs/internal/benchmark-budgets.md#hmac_session_benchmarkzig`
//! holds the 3-run calibration. Phase F regenerates on `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;

const auth = @import("framework/auth.zig");

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const repetitions = 35;

// Budget — see docs/internal/benchmark-budgets.md.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 30_000 };

// Fixed test key. Not a secret.
const bench_key: *const [auth.key_length]u8 = "tiger-web-bench-hmac-key-0123456";

test "benchmark: hmac_session" {
    var bench: Bench = .init();
    defer bench.deinit();

    var prng = stdx.PRNG.from_seed(bench.seed);
    const user_id: u128 = prng.int(u128) | 1; // non-zero per verify_cookie contract

    var cookie_buffer: [auth.cookie_value_max]u8 = undefined;
    const cookie = auth.sign_cookie(&cookie_buffer, user_id, .authenticated, bench_key);
    assert(cookie.len == auth.cookie_value_max);

    // Pair-assertion — positive: sign → verify round-trip.
    {
        const round_trip = auth.verify_cookie(cookie, bench_key) orelse
            std.debug.panic("hmac_session: sign/verify round-trip returned null", .{});
        assert(round_trip.user_id == user_id);
        assert(round_trip.kind == .authenticated);
    }

    // Pair-assertion — negative: tampered cookie (1-bit flip in HMAC
    // tail) must return null.
    {
        var tampered: [auth.cookie_value_max]u8 = cookie_buffer;
        tampered[60] ^= 0x01;
        if (auth.verify_cookie(&tampered, bench_key) != null) {
            std.debug.panic("hmac_session: tampered cookie accepted", .{});
        }
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var verify_counter_sum: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        const result = auth.verify_cookie(cookie, bench_key);
        duration.* = bench.stop();
        if (result) |r| verify_counter_sum +%= @truncate(r.user_id);
    }

    const result = bench.estimate(&duration_samples);

    bench.report("verify_counter {x:0>16}", .{verify_counter_sum});
    bench.report("hmac_session = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_ns_smoke_max, "hmac_session");
}
