//! HTTP route-match primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (the cp-template for every primitive bench in phase C).
//!
//! **Survival:** ~20/43 lines of the template carry over (~47%). The
//! bench harness (Bench init/deinit, sample loop, estimate, hash-of-run
//! print) is verbatim; kernel, input, and parameter are substituted.
//!
//! Substitutions relative to the template:
//!
//!   - Kernel: `checksum(blob)` → full iteration over
//!     `generated/routes.generated.zig` calling `parse.match_route`
//!     for each. One sample = one pass over all paths × all routes.
//!   - Input: PRNG-filled blob → mixed canonical path set (exact,
//!     parameterized, deeper-parameterized, unmatched, root).
//!   - Parameter: `bench.parameter("blob_size", KiB, MiB)` removed —
//!     the input set is fixed; varying it would measure a different
//!     property (e.g. route-table depth).
//!   - Counter: `u128` checksum accumulator → `u64` match-count
//!     counter (prevents DCE).
//!   - Report format: `"{} for whole blob"` →
//!     `"route_match = {d} ns"` per-path size (DR-2).
//!
//! Additions beyond the template (all principled):
//!
//!   - Pair-assertion at test start: each known-good path must
//!     resolve to its expected Operation. A drift between the
//!     generated-route table and the scanner's annotations fires
//!     here before the throughput number becomes meaningless.
//!   - `bench.assert_budget` (same principled divergence documented
//!     in `framework/bench.zig`).
//!
//! **External commitment:** the scanner → generated-table contract.
//! Every handler annotation becomes a row in
//! `generated/routes.generated.zig`; the matcher consumes that row.
//! The matcher implementation is plastic (could swap for a trie or
//! regex), but the *interface* (take a path, return an Operation) is
//! locked by the scanner output.
//!
//! **Actionability:** if ns/match rises >10%, check whether the
//! generated route table grew (more routes = more comparisons) or
//! the matcher's loop structure changed. A rise on parameterized
//! routes but not exact-match usually means the pattern-matcher's
//! splitter got slower. If unmatched-path performance regresses,
//! the 404 path is taking longer — which affects DoS surface.
//!
//! **Budget calibration:** 50 µs per full-path-set pass. Dev-machine
//! Debug: a table of ~24 routes × 5 paths with `inline for`
//! unrolling should be sub-µs; 50× headroom for Debug +
//! slow CI. Re-calibrate on ubuntu-22.04 in phase F.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const http = @import("framework/http.zig");
const parse = @import("framework/parse.zig");
const message = @import("message.zig");
const gen = @import("generated/routes.generated.zig");

const repetitions = 35;

const budget_smoke: stdx.Duration = .{ .ns = 50_000 }; // 50 µs per pass

const Probe = struct {
    method: http.Method,
    path: []const u8,
    expect: ?message.Operation, // null = expected unmatched
};

// Mixed input: exact-match, parameterized, deeper parameterized,
// unmatched (DoS surface), and root.
const probes = [_]Probe{
    .{ .method = .get, .path = "/products", .expect = .list_products },
    .{ .method = .get, .path = "/products/abc123def456", .expect = .get_product },
    .{ .method = .post, .path = "/collections/c1/products/p9", .expect = .add_collection_member },
    .{ .method = .get, .path = "/definitely-not-a-route/extra", .expect = null },
    .{ .method = .get, .path = "/", .expect = .page_load_dashboard },
};

/// Full iteration over the generated route table. Mirrors the shape of
/// `handler_route` in `app.zig` minus the handler-body decode, which is
/// out of scope for the primitive bench.
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

    // Pair-assertion: every probe must resolve to its expected
    // operation. If this fires, the generated table drifted from the
    // scanner's annotations — no throughput number from below would
    // be meaningful.
    for (probes) |p| {
        const got = match_any(p.method, p.path);
        if (!eql_opt(got, p.expect)) {
            std.debug.panic(
                "route_match: probe {s} {s} resolved to {?}, want {?}",
                .{ @tagName(p.method), p.path, got, p.expect },
            );
        }
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var match_counter: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        inline for (probes) |p| {
            if (match_any(p.method, p.path)) |op| {
                match_counter +%= @intFromEnum(op);
            }
        }
        duration.* = bench.stop();
    }

    const result = bench.estimate(&duration_samples);

    bench.report("match_sum {x:0>16}", .{match_counter});
    bench.report("route_match = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_smoke, "route_match");
}

fn eql_opt(a: ?message.Operation, b: ?message.Operation) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
