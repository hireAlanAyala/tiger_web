//! Aegis-128L checksum primitive benchmark.
//!
//! **Port:** `cp` of TigerBeetle's `src/vsr/checksum_benchmark.zig`,
//! trimmed. Diff against TB's file is the audit trail — every line
//! that differs is below with its bucket tag.
//!
//! **Edits vs TB's original:**
//!
//!   - Import paths rewritten for our layout (principled —
//!     `../constants.zig` → `framework/constants.zig` etc).
//!   - Test name `checksum` → `aegis_checksum` (flaw fix — disambiguates
//!     from `crc_frame_benchmark.zig`).
//!   - Report format `"{} for whole blob"` → `"aegis_checksum = {d} ns"`
//!     (principled — DR-2: `scripts/devhub.zig` parser requires
//!     `label = value unit`).
//!   - Pair-assertions added (flaw fix — TIGER_STYLE golden rule):
//!     positive known-vector check and negative-space
//!     collision-on-flip check. TB's template has no rejection path
//!     to assert; ours does, and the hash-fundamental property is
//!     load-bearing.
//!   - `bench.assert_budget` call added (flaw fix — documented
//!     principled divergence in `framework/bench.zig`).
//!
//! **External commitment:** WAL entry format on disk. Every existing
//! WAL was hash-chained with this primitive; changing it breaks
//! every existing WAL.
//!
//! **Actionability:** if throughput drops >10%, check AES-NI
//! engagement (`std.crypto.core.aes.has_hardware_support`); a
//! software-fallback path on a VM is a step-function drop. If the
//! positive pair-assertion fires, the Aegis implementation drifted
//! — WAL verification breaks on every existing entry. If the
//! negative pair-assertion fires, the primitive is mapping
//! different inputs to the same checksum (catastrophic).
//!
//! **Budget:** `docs/internal/benchmark-budgets.md` holds the 3-run
//! calibration table. Phase F regenerates on `ubuntu-22.04`.

const std = @import("std");

const cache_line_size = @import("framework/constants.zig").cache_line_size;
const checksum = @import("framework/checksum.zig").checksum;

const stdx = @import("stdx");

const KiB = stdx.KiB;
const MiB = stdx.MiB;

const Bench = @import("framework/bench.zig");

const repetitions = 35;

// Budget — see `docs/internal/benchmark-budgets.md#aegis_checksum_benchmarkzig`.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 50_000 };

// Known-good vector asserted in `framework/checksum.zig:82`.
const vector_hello: u128 = 0x945F96D02A647D7281BA51BB5EC83553;

test "benchmark: aegis_checksum" {
    // Pair-assertion — positive: known vector.
    if (checksum("hello") != vector_hello) {
        std.debug.panic(
            "aegis_checksum: vector mismatch: got 0x{X}, want 0x{X}",
            .{ checksum("hello"), vector_hello },
        );
    }

    // Pair-assertion — negative: flipping one byte must change the
    // checksum (hash fundamental).
    if (checksum("hello") == checksum("hallo")) {
        std.debug.panic("aegis_checksum: collision on 1-byte flip", .{});
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
