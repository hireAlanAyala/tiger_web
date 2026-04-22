//! Aegis-128L checksum primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (`/home/walker/Documents/personal/tigerbeetle`, 43 lines).
//!
//! **Survival:** 40/43 lines verbatim (93%). Three surgical changes,
//! all required and all in the "principled — file-layout adaptation"
//! bucket:
//!
//!   1. `@import("../constants.zig")` → `@import("framework/constants.zig")`
//!   2. `@import("checksum.zig")` → `@import("framework/checksum.zig")`
//!   3. `@import("../testing/bench.zig")` → `@import("framework/bench.zig")`
//!
//! Three additional surgical edits beyond the import paths:
//!
//!   - Test name: `"benchmark: checksum"` → `"benchmark: aegis_checksum"`
//!     (flaw fix: TB's name is ambiguous in a codebase that has both
//!     Aegis and CRC32 checksum benches; our name disambiguates).
//!   - `bench.report("{} for whole blob", ...)` →
//!     `bench.report("aegis_checksum = {d} ns", ...)`
//!     (principled: `scripts/devhub.zig`'s `get_measurement` parser
//!     requires `label = value unit` — see benchmark-tracking plan
//!     DR-2. TB's format is human-readable only; ours must also be
//!     machine-parseable).
//!   - `bench.assert_budget` call added — same principled divergence
//!     documented in `framework/bench.zig`: our smoke-mode catches
//!     order-of-magnitude regressions, TB's does not.
//!
//! **External commitment:** WAL entry format on disk. Every existing
//! WAL was hash-chained with this primitive; changing it breaks every
//! existing WAL. This benchmark protects the throughput property of
//! that commitment.
//!
//! **Actionability:** if MB/s drops >10%, check whether AES-NI
//! hardware acceleration is still engaged
//! (`std.crypto.core.aes.has_hardware_support`). A cross-architecture
//! CI change or VM disabling AES-NI will produce a step-function
//! drop. If the software fallback is active, WAL throughput
//! bottlenecks on checksum computation.
//!
//! **Budget calibration:** 10 µs for the 1 KiB smoke-mode blob.
//! Expected ~200 ns/blob with AES-NI engaged (≈ 5 GB/s). 10× headroom
//! against the highest observed smoke-mode sample, rounded up for slow
//! CI runners. Re-calibrate on ubuntu-22.04 in phase F.

const std = @import("std");

const cache_line_size = @import("framework/constants.zig").cache_line_size;
const checksum = @import("framework/checksum.zig").checksum;

const stdx = @import("stdx");

const KiB = stdx.KiB;
const MiB = stdx.MiB;

const Bench = @import("framework/bench.zig");

const repetitions = 35;

const budget_smoke: stdx.Duration = .{ .ns = 10_000 }; // 10 µs per 1 KiB blob

test "benchmark: aegis_checksum" {
    var bench: Bench = .init();
    defer bench.deinit();

    const blob_size = bench.parameter("blob_size", KiB, MiB);

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();
    var prng = stdx.PRNG.from_seed(bench.seed);
    const blob = try arena.alignedAlloc(u8, cache_line_size, blob_size);
    prng.fill(blob);

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var checksum_counter: u128 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        checksum_counter +%= checksum(blob);
        duration.* = bench.stop();
    }

    const result = bench.estimate(&duration_samples);

    // See "benchmark: API tutorial" to understand why we print out the "hash" of this run.
    bench.report("checksum {x:0>32}", .{checksum_counter});
    bench.report("aegis_checksum = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_smoke, "aegis_checksum");
}
