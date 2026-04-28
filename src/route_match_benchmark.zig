//! HTTP route-match primitive benchmark.
//!
//! **Port:** `cp` of TigerBeetle's `src/vsr/checksum_benchmark.zig`,
//! trimmed. Diff against TB's file is the audit trail.
//!
//! **Edits vs TB's original:**
//!
//!   - Import paths rewritten for our layout (principled).
//!   - Kernel: `checksum(blob)` → `inline for (gen.routes)` calling
//!     `parse.match_route` per row (principled — our domain).
//!   - `cache_line_size` + arena + `alignedAlloc` + `prng.fill`
//!     removed (principled — probes are comptime path literals).
//!   - `blob_size` + `KiB`/`MiB` removed (principled — fixed probe
//!     set).
//!   - Counter `u128` → `u64` (principled).
//!   - Report format per DR-2.
//!   - Pair-assertions added (flaw fix — TIGER_STYLE golden rule):
//!     positive every-probe-resolves-to-expected, negative
//!     unmatched-probe-returns-null. 404 path is DoS surface — if
//!     a path that should 404 is matching, that's a correctness
//!     regression, not performance.
//!   - `bench.assert_budget` call (flaw fix — documented in
//!     `framework/bench.zig`).
//!   - `match_any` helper — ours, not transplanted (routing
//!     primitive is ours). Stand-alone function with primitive
//!     args per TIGER_STYLE "extract hot loops".
//!
//! **External commitment:** scanner → generated-table contract.
//! Matcher implementation is plastic; interface (method+path →
//! Operation) is locked by the scanner output.
//!
//! **Actionability:** if ns/pass rises >10%, check whether the
//! generated route table grew or `parse.match_route`'s inner loop
//! changed. A rise on parameterized probes but not exact-match
//! usually means the pattern splitter got slower. If the
//! *negative* pair-assertion fires, a path that should 404 is now
//! matching — DoS-surface regression, fix before shipping. If
//! unmatched-probe latency alone regresses (not matched-probe), the
//! 404 cost path widened — still a DoS concern.
//!
//! **Budget:** `docs/internal/benchmark-budgets.md#route_match_benchmarkzig`
//! holds the 3-run calibration. Phase F regenerates on `ubuntu-22.04`.

const std = @import("std");

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const http = @import("framework/http.zig");
const parse = @import("framework/parse.zig");
const message = @import("message.zig");
const gen = @import("generated/routes.generated.zig");

const repetitions = 35;

// Budget — see docs/internal/benchmark-budgets.md.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 70_000 };

const Probe = struct {
    method: http.Method,
    path: []const u8,
    expect: ?message.Operation, // null = expected unmatched
};

const probes = [_]Probe{
    .{ .method = .get, .path = "/products", .expect = .list_products },
    .{ .method = .get, .path = "/products/abc123def456", .expect = .get_product },
    .{ .method = .post, .path = "/collections/c1/products/p9", .expect = .add_collection_member },
    .{ .method = .get, .path = "/definitely-not-a-route/extra", .expect = null },
    .{ .method = .get, .path = "/", .expect = .page_load_dashboard },
};

// Ours, not transplanted from TB — routing primitive is ours.
// Mirrors `app.zig:handler_route` minus the handler-body decode.
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

    // Pair-assertion — positive: known routes resolve to expected ops.
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

    // Pair-assertion — negative: unmatched probe must return null.
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

    bench.report("match_sum {x:0>16}", .{match_counter_sum});
    bench.report("route_match = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_ns_smoke_max, "route_match");
}
