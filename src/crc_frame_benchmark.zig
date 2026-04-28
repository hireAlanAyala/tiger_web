//! CRC32 frame-checksum primitive benchmark.
//!
//! **Port:** `cp` of TigerBeetle's `src/vsr/checksum_benchmark.zig`,
//! trimmed. Diff against TB's file is the audit trail.
//!
//! **Edits vs TB's original:**
//!
//!   - Import paths rewritten for our layout (principled).
//!   - Kernel: `checksum(blob)` → `shm_layout.crc_frame(len, payload)`
//!     (principled — our domain).
//!   - `blob_size = bench.parameter(...)` → `inline for (sizes)` over
//!     5 canonical payload sizes (principled — actionability statement
//!     compares cross-size behavior, which a single parameter would
//!     hide).
//!   - Counter `u128` → `u64` (principled — CRC returns `u32`).
//!   - Report format `"crc_frame_{size} = {d} ns"` per DR-2.
//!   - Pair-assertions added (flaw fix — TIGER_STYLE golden rule):
//!     positive cross-language vector (`0x5CAC007A`), negative on
//!     length-prefix participation, negative on payload sensitivity.
//!     TB's template has no rejection path; our CRC covers
//!     `len ++ payload` specifically and both properties need
//!     guarding.
//!   - `bench.assert_budget` per size (flaw fix — documented in
//!     `framework/bench.zig`).
//!
//! **External commitment:** cross-language wire contract
//! (`packages/vectors/shm_layout.json`: crc_convention). Cannot
//! change without simultaneous Zig + C + TS update.
//!
//! **Actionability:** if ns/call drops >10% on one payload size but
//! not others, cache behavior changed (e.g., 64 KiB case spilling
//! L1 differently). If it drops uniformly, verify SIMD kernel
//! engagement and the `inline` annotation on `crc_frame` survived
//! optimization. If the positive pair-assertion fires, the Zig
//! CRC drifted from C/TS — cross-language frames will misalign.
//! If either negative pair-assertion fires, the CRC is no longer
//! length-aware or content-aware — data corruption will go
//! undetected.
//!
//! **Budgets:** `docs/internal/benchmark-budgets.md#crc_frame_benchmarkzig`
//! holds the per-size 3-run calibration table. Phase F regenerates
//! on `ubuntu-22.04`.

const std = @import("std");

const cache_line_size = @import("framework/constants.zig").cache_line_size;
const shm_layout = @import("framework/shm_layout.zig");

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const repetitions = 35;

const Size = struct {
    bytes: u32,
    name: []const u8,
    budget_ns_smoke_max: u64,
};

// Per-size budgets — see docs/internal/benchmark-budgets.md.
const sizes = [_]Size{
    .{ .bytes = 64, .name = "crc_frame_64", .budget_ns_smoke_max = 15_000 },
    .{ .bytes = 256, .name = "crc_frame_256", .budget_ns_smoke_max = 50_000 },
    .{ .bytes = 1024, .name = "crc_frame_1024", .budget_ns_smoke_max = 150_000 },
    .{ .bytes = 4096, .name = "crc_frame_4096", .budget_ns_smoke_max = 600_000 },
    .{ .bytes = 65536, .name = "crc_frame_65536", .budget_ns_smoke_max = 3_000_000 },
};

test "benchmark: crc_frame" {
    // Pair-assertion — positive: cross-language wire vector.
    {
        const got = shm_layout.crc_frame(5, "hello");
        if (got != 0x5CAC007A) {
            std.debug.panic(
                "crc_frame: vector mismatch: got 0x{X:0>8}, want 0x5CAC007A",
                .{got},
            );
        }
    }

    // Pair-assertion — negative: length prefix participates in the CRC.
    if (shm_layout.crc_frame(5, "hello") == shm_layout.crc_frame(4, "hello")) {
        std.debug.panic("crc_frame: length prefix not part of CRC", .{});
    }

    // Pair-assertion — negative: payload changes must change the CRC.
    if (shm_layout.crc_frame(5, "hello") == shm_layout.crc_frame(5, "hallo")) {
        std.debug.panic("crc_frame: payload flip did not change CRC", .{});
    }

    var bench: Bench = .init();
    defer bench.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var prng = stdx.PRNG.from_seed(bench.seed);

    var crc_counter_sum: u64 = 0;

    inline for (sizes) |s| {
        const blob = try arena.alignedAlloc(u8, cache_line_size, s.bytes);
        prng.fill(blob);

        var duration_samples: [repetitions]stdx.Duration = undefined;
        for (&duration_samples) |*duration| {
            bench.start();
            crc_counter_sum +%= shm_layout.crc_frame(s.bytes, blob);
            duration.* = bench.stop();
        }

        const result = bench.estimate(&duration_samples);
        bench.report(s.name ++ " = {d} ns", .{result.ns});
        bench.assert_budget(result, .{ .ns = s.budget_ns_smoke_max }, s.name);
    }

    bench.report("crc_sum {x:0>16}", .{crc_counter_sum});
}
