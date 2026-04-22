//! HTTP route-match primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle,
//! cp'd verbatim and trimmed. Every change from TB's original is
//! named with its bucket — **principled** (TB's answer doesn't fit
//! our domain), **flaw fix** (TB has a known weakness we can cheaply
//! improve), or **tracked follow-up** (temporary state with a known
//! end condition). Anything not listed here is TB's code, unchanged.
//!
//! **Transplanted verbatim from template:**
//!
//!   - `const std = @import("std");` — line 1
//!   - `const stdx = @import("stdx");` — line 6
//!   - `const repetitions = 35;` — line 13
//!   - `Bench.init`/`defer deinit` shape — lines 16–17
//!   - `var duration_samples: [repetitions]stdx.Duration = undefined;` — line 29
//!   - Sample-loop shape (`bench.start()` / kernel / `duration.* = bench.stop()`) — lines 32–36
//!   - `bench.estimate(&duration_samples)` — line 38
//!   - `bench.report("<hash>", ...)` pattern — line 41
//!
//! **Deletions (all principled):**
//!
//!   - `cache_line_size` import (template line 3) — probe set is
//!     compile-time; no aligned alloc.
//!   - `checksum` import (template line 4) — replaced by `parse` +
//!     generated route table.
//!   - `KiB`/`MiB` imports (template lines 8–9) — input is a fixed
//!     probe set, not a variable-sized blob.
//!   - `blob_size = bench.parameter(...)` (template line 19) — same
//!     reason.
//!   - `arena_instance` + `defer deinit` + `arena =
//!     arena_instance.allocator()` (template lines 21–24) — probes
//!     are `comptime` path literals; no heap.
//!   - `var prng = stdx.PRNG.from_seed(bench.seed);` (template
//!     line 25) — probes are deterministic; no random fill.
//!   - `const blob = try arena.alignedAlloc(...)` +
//!     `prng.fill(blob)` (template lines 26–27) — replaced by the
//!     `probes` compile-time array.
//!
//! **Path substitutions (principled — file-layout adaptation):**
//!
//!   - `@import("../testing/bench.zig")` → `@import("framework/bench.zig")`
//!
//! **Additions (flaw fix — TIGER_STYLE alignment):**
//!
//!   - `match_any` helper — mirrors `app.zig:handler_route` minus
//!     the handler-body decode. Not transplanted from TB; this is
//!     our routing primitive. Kept as a stand-alone function
//!     (no `self`) per TIGER_STYLE's "extract hot loops" rule.
//!   - Pair-assertion covering positive AND negative space per
//!     TIGER_STYLE's "golden rule":
//!       * Positive: every known-route probe resolves to its
//!         expected `Operation`.
//!       * Negative: the unmatched-path probe explicitly returns
//!         `null`. TB's template has no rejection path to assert;
//!         our matcher does, and the 404 path is DoS surface — we
//!         want regressions visible here.
//!   - `bench.assert_budget` call (same principled divergence
//!     documented in `framework/bench.zig`).
//!   - Substituted report format to `"route_match = {d} ns"` per
//!     DR-2.
//!
//! **External commitment:** the scanner → generated-table contract.
//! Every handler annotation becomes a row in
//! `generated/routes.generated.zig`; the matcher consumes that row.
//! The matcher implementation is plastic (could swap for a trie or
//! regex), but the *interface* (take method+path, return an
//! Operation) is locked by the scanner output.
//!
//! **Actionability:** if ns/pass rises >10%, check whether the
//! generated route table grew (more routes = more comparisons) or
//! `parse.match_route`'s inner loop changed. A rise on parameterized
//! probes but not exact-match usually means the pattern splitter
//! got slower. If the *negative* pair-assertion fires, a path that
//! should 404 is now matching — DoS surface regression, fix before
//! shipping. If unmatched-probe latency alone regresses (not
//! matched-probe), the 404 cost path widened — still a DoS concern.
//!
//! **Budget calibration:** dev-machine Debug, 3 runs. Observed
//! 4083 / 6485 / 5702 ns → max 6485 → 10× = 64_850 → round up to
//! 70_000 ns. Phase F re-calibrates on `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

// Path substitution from TB's `../testing/bench.zig` — our layout
// co-locates the harness under `framework/`.
const Bench = @import("framework/bench.zig");

const http = @import("framework/http.zig");
const parse = @import("framework/parse.zig");
const message = @import("message.zig");
const gen = @import("generated/routes.generated.zig");

const repetitions = 35;

// Budget — 10× `max(3 runs)` on dev-machine Debug, rounded up.
// Observed: 4083 / 6485 / 5702 ns → max 6485 → 10× = 64_850 →
// round up to 70_000. Phase F re-calibrates on CI ubuntu-22.04.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 70_000 };

const Probe = struct {
    method: http.Method,
    path: []const u8,
    expect: ?message.Operation, // `null` = expected unmatched
};

// Mixed probe set: exact-match, parameterized, deeper parameterized,
// unmatched (DoS surface), and root.
const probes = [_]Probe{
    .{ .method = .get, .path = "/products", .expect = .list_products },
    .{ .method = .get, .path = "/products/abc123def456", .expect = .get_product },
    .{ .method = .post, .path = "/collections/c1/products/p9", .expect = .add_collection_member },
    .{ .method = .get, .path = "/definitely-not-a-route/extra", .expect = null },
    .{ .method = .get, .path = "/", .expect = .page_load_dashboard },
};

/// Full iteration over the generated route table. Mirrors
/// `app.zig:handler_route` minus the handler-body decode, which is
/// out of scope for a primitive bench. Stand-alone function with
/// primitive args (no `self`) per TIGER_STYLE "extract hot loops".
fn match_any(method: http.Method, path: []const u8) ?message.Operation {
    var result: ?message.Operation = null;
    inline for (gen.routes) |route| {
        if (method == route.method) {
            if (parse.match_route(path, route.pattern)) |_| {
                if (result == null) result = route.operation;
            }
        }
    }
    return result;
}

test "benchmark: route_match" {
    var bench: Bench = .init();
    defer bench.deinit();

    // Pair-assertion — positive space: every known route resolves
    // to its expected operation. If this fires, the generated table
    // drifted from the scanner's annotations.
    for (probes) |p| {
        if (p.expect) |expected| {
            const got = match_any(p.method, p.path) orelse
                std.debug.panic("route_match: probe {s} {s} unmatched", .{ @tagName(p.method), p.path });
            if (got != expected) {
                std.debug.panic(
                    "route_match: probe {s} {s} resolved to {}, want {}",
                    .{ @tagName(p.method), p.path, got, expected },
                );
            }
        }
    }

    // Pair-assertion — negative space: the unmatched probe must
    // resolve to null. If a path that should 404 is matching,
    // that's a DoS-surface regression.
    for (probes) |p| {
        if (p.expect == null) {
            if (match_any(p.method, p.path) != null) {
                std.debug.panic(
                    "route_match: unmatched probe {s} {s} was matched",
                    .{ @tagName(p.method), p.path },
                );
            }
        }
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var match_counter_sum: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        inline for (probes) |p| {
            if (match_any(p.method, p.path)) |op| {
                match_counter_sum +%= @intFromEnum(op);
            }
        }
        duration.* = bench.stop();
    }

    const result = bench.estimate(&duration_samples);

    // Hash-of-run — same discipline as TB template line 41.
    bench.report("match_sum {x:0>16}", .{match_counter_sum});
    bench.report("route_match = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_ns_smoke_max, "route_match");
}
