//! Aegis-128L checksum primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (`/home/walker/Documents/personal/tigerbeetle`, 43 lines), cp'd
//! verbatim with minimal trim. Every change from TB's original is
//! named with its bucket — **principled** (TB's answer doesn't fit
//! our domain), **flaw fix** (TB has a known weakness we can cheaply
//! improve), or **tracked follow-up**. Anything not listed here is
//! TB's code, unchanged.
//!
//! **Survival: 40/43 lines verbatim (93%)** — the closest port in
//! phase C. Everything from `repetitions = 35` through
//! `bench.estimate` is TB's shape unchanged. Only the three import
//! paths, the test name, the report format, and the `assert_budget`
//! tail differ.
//!
//! **Path substitutions (principled — file-layout adaptation):**
//!
//!   - `@import("../constants.zig")` → `@import("framework/constants.zig")`
//!   - `@import("checksum.zig")` → `@import("framework/checksum.zig")`
//!   - `@import("../testing/bench.zig")` → `@import("framework/bench.zig")`
//!
//! **Surgical edits (flaw fix — TIGER_STYLE alignment):**
//!
//!   - Test name: `"benchmark: checksum"` → `"benchmark: aegis_checksum"`.
//!     TB's name is ambiguous in a codebase that also has
//!     `crc_frame_benchmark.zig`; ours disambiguates.
//!   - Report format `"{} for whole blob"` → `"aegis_checksum = {d} ns"`.
//!     DR-2: `scripts/devhub.zig` parser requires `label = value unit`.
//!   - Pair-assertions added (positive + negative per TIGER_STYLE
//!     "golden rule"):
//!       * Positive: `checksum("hello")` must equal the constant
//!         asserted in `framework/checksum.zig:82`. Fires if the
//!         primitive drifted (stdlib Aegis impl changed, key
//!         initialization bug).
//!       * Negative: flipping one byte of the blob must change the
//!         checksum. Guards the fundamental hash property that
//!         makes throughput meaningful — if the primitive ever
//!         maps different inputs to the same output, throughput is
//!         irrelevant because WAL integrity is broken.
//!   - `bench.assert_budget` call added — documented principled
//!     divergence in `framework/bench.zig`.
//!
//! **External commitment:** WAL entry format on disk. Every existing
//! WAL was hash-chained with this primitive; changing it breaks
//! every existing WAL. This benchmark protects the throughput
//! property of that commitment.
//!
//! **Actionability:** if MB/s drops >10%, check whether AES-NI
//! hardware acceleration is still engaged
//! (`std.crypto.core.aes.has_hardware_support`). A cross-architecture
//! CI change or VM disabling AES-NI produces a step-function drop.
//! If the positive pair-assertion fires, the Aegis implementation
//! drifted — WAL verification will fail on every existing entry.
//! If the negative pair-assertion fires, the primitive is mapping
//! different blobs to the same checksum — catastrophic, the
//! throughput number is meaningless under that regression.
//!
//! **Budget calibration:** dev-machine Debug, 3 runs in benchmark
//! mode forced to 1 KiB (same as smoke-mode input) via
//! `blob_size=1024`. Observed: 4942 / 2976 / 4841 ns → max 4942 →
//! 10× = 49_420 → round up to 50_000 ns. Phase F re-calibrates on
//! `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;

const cache_line_size = @import("framework/constants.zig").cache_line_size;
const checksum = @import("framework/checksum.zig").checksum;

const stdx = @import("stdx");

const KiB = stdx.KiB;
const MiB = stdx.MiB;

const Bench = @import("framework/bench.zig");

const repetitions = 35;

// Budget — 10× `max(3 runs)` on dev-machine Debug at 1 KiB input,
// rounded up. Observed 4942 / 2976 / 4841 ns. Phase F re-calibrates.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 50_000 };

// Known-good vector asserted in `framework/checksum.zig:82`. If the
// primitive drifts from this constant, WAL verification breaks on
// every existing entry — fire before the throughput loop starts.
const vector_hello: u128 = 0x945F96D02A647D7281BA51BB5EC83553;

test "benchmark: aegis_checksum" {
    // Pair-assertion — positive space: known vector.
    if (checksum("hello") != vector_hello) {
        std.debug.panic(
            "aegis_checksum: vector mismatch: got 0x{X}, want 0x{X}",
            .{ checksum("hello"), vector_hello },
        );
    }

    // Pair-assertion — negative space: flipping one byte must
    // change the checksum. Hash fundamental property.
    {
        const original = checksum("hello");
        const flipped = checksum("hallo"); // 'e' → 'a'
        if (original == flipped) {
            std.debug.panic("aegis_checksum: collision on 1-byte flip", .{});
        }
    }

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
    bench.assert_budget(result, budget_ns_smoke_max, "aegis_checksum");
}
