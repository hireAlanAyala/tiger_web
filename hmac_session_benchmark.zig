//! HMAC-SHA256 session-cookie verify primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle,
//! cp'd verbatim and trimmed. Every change from TB's original is named
//! with its bucket — **principled** (TB's answer doesn't fit our
//! domain), **flaw fix** (TB has a known weakness we can cheaply
//! improve), or **tracked follow-up** (temporary state with a known
//! end condition). Anything not listed here is TB's code, unchanged.
//!
//! **Transplanted verbatim from template:**
//!
//!   - `const std = @import("std");` — line 1
//!   - `const stdx = @import("stdx");` — line 6
//!   - `const repetitions = 35;` — line 13
//!   - `Bench.init`/`defer deinit` shape — lines 16–17
//!   - `var prng = stdx.PRNG.from_seed(bench.seed);` — line 25
//!   - `var duration_samples: [repetitions]stdx.Duration = undefined;` — line 29
//!   - Sample-loop shape (`bench.start()` / kernel / `duration.* = bench.stop()`) — lines 32–36
//!   - `bench.estimate(&duration_samples)` — line 38
//!   - `bench.report("<hash>", ...)` pattern — line 41
//!
//! **Deletions (all principled unless noted):**
//!
//!   - `cache_line_size` import (template line 3) — cookie is
//!     stack-allocated; no aligned alloc needed.
//!   - `checksum` import (template line 4) — replaced by `auth`.
//!   - `KiB`/`MiB` imports (template lines 8–9) — cookie length is
//!     fixed by the auth protocol (`auth.cookie_value_max = 97`).
//!   - `blob_size = bench.parameter(...)` (template line 19) — same
//!     reason.
//!   - `arena_instance` + `defer deinit` + `arena =
//!     arena_instance.allocator()` (template lines 21–24) — kernel
//!     takes a `[]const u8` of fixed known size; stack buffer
//!     suffices.
//!   - `const blob = try arena.alignedAlloc(...)` +
//!     `prng.fill(blob)` (template lines 26–27) — replaced by
//!     cookie construction (PRNG-seeded user_id → `sign_cookie`).
//!
//! **Path substitutions (principled — file-layout adaptation):**
//!
//!   - `@import("../testing/bench.zig")` → `@import("framework/bench.zig")`
//!
//! **Additions (flaw fix — TIGER_STYLE alignment):**
//!
//!   - Pair-assertion covering both positive and negative space per
//!     TIGER_STYLE's "golden rule": `sign_cookie` → `verify_cookie`
//!     round-trip must recover the exact `user_id` and `kind`
//!     (positive), AND a cookie with a flipped byte in the HMAC
//!     region must return `null` (negative). TB's template has no
//!     pair-assertion because its kernel (checksum) has no rejection
//!     path; ours does, and the negative-space check guards the
//!     security property that makes the positive measurement
//!     meaningful.
//!   - `bench.assert_budget` call — documented principled divergence
//!     in `framework/bench.zig` (TB's "regression detection is a
//!     non-goal" vs our smoke-mode-fails-unit-test workflow).
//!   - Substituted report format to `"hmac_session = {d} ns"` per
//!     DR-2 (`scripts/devhub.zig` parser requires `label = value unit`).
//!
//! **External commitment:** the cookie wire format (97 bytes:
//! 32-hex user_id + separator + 64-hex HMAC) is user-visible. Every
//! active session was signed against this format; changing it
//! invalidates every session and forces re-login. This bench protects
//! the verification-cost property of that commitment — if per-request
//! auth cost blows up, every request slows down.
//!
//! **Actionability:** if ns/call rises >20%, check whether
//! `HmacSha256` stdlib changed or the cookie format grew (new field
//! added to the HMAC input). If the positive pair-assertion fires,
//! the cookie schema drifted — session invalidation is a user-visible
//! breaking change. If the *negative* pair-assertion fires,
//! verification is accepting tampered cookies — a security
//! regression, not a performance issue. If ns/call drops sharply
//! without a known optimization, verify a step wasn't removed (e.g.,
//! `timingSafeEql` replaced with a non-constant-time compare).
//!
//! **Budget calibration:** dev-machine Debug, 3 runs, smoke mode
//! (same fixed input as benchmark mode since the parameter was
//! dropped). Numbers populated by the commit message; 10× `max(runs)`
//! rounded up. Re-calibrate on `ubuntu-22.04` in phase F per plan.

const std = @import("std");
const assert = std.debug.assert;

const auth = @import("framework/auth.zig");

const stdx = @import("stdx");

// Path substitution from TB's `../testing/bench.zig` — our layout
// co-locates the harness under `framework/`.
const Bench = @import("framework/bench.zig");

const repetitions = 35;

// Budget — 10× `max(3 runs)` on dev-machine Debug, rounded up.
// Observed: 2109 / 2072 / 2691 ns → max 2691 → 10× = 26_910 →
// round up to 30_000. Phase F re-calibrates on CI ubuntu-22.04.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 30_000 };

// Fixed test key — only the cookie shape matters for the throughput
// measurement. Not a secret.
const bench_key: *const [auth.key_length]u8 = "tiger-web-bench-hmac-key-0123456";

test "benchmark: hmac_session" {
    var bench: Bench = .init();
    defer bench.deinit();

    var prng = stdx.PRNG.from_seed(bench.seed);
    const user_id: u128 = prng.int(u128) | 1; // non-zero per verify_cookie contract

    var cookie_buffer: [auth.cookie_value_max]u8 = undefined;
    const cookie = auth.sign_cookie(&cookie_buffer, user_id, .authenticated, bench_key);
    assert(cookie.len == auth.cookie_value_max);

    // Pair-assertion — positive space: round-trip recovers the exact
    // identity we signed. If this fires, sign/verify drifted.
    {
        const round_trip = auth.verify_cookie(cookie, bench_key) orelse
            std.debug.panic("hmac_session: sign/verify round-trip returned null", .{});
        assert(round_trip.user_id == user_id);
        assert(round_trip.kind == .authenticated);
    }

    // Pair-assertion — negative space: a cookie with a flipped byte
    // in the HMAC region must be rejected. If this fires, verify is
    // accepting tampered input and the security property is broken
    // — the throughput number is meaningless under that regression.
    {
        var tampered: [auth.cookie_value_max]u8 = cookie_buffer;
        tampered[60] ^= 0x01; // flip one bit inside the 64-hex HMAC tail
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

    // Hash-of-run — same discipline as TB template line 41.
    bench.report("verify_counter {x:0>16}", .{verify_counter_sum});
    bench.report("hmac_session = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_ns_smoke_max, "hmac_session");
}
