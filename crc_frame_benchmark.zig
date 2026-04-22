//! CRC32 frame-checksum primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle,
//! cp'd verbatim and trimmed. Every change from TB's original is
//! named with its bucket — **principled** (TB's answer doesn't fit
//! our domain), **flaw fix** (TB has a known weakness we can cheaply
//! improve), or **tracked follow-up**. Anything not listed here is
//! TB's code, unchanged.
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
//! **Deletions (all principled):**
//!
//!   - `checksum` import (template line 4) — replaced by
//!     `shm_layout.crc_frame`.
//!   - `KiB`/`MiB` imports (template lines 8–9) — payload sizes are
//!     a fixed canonical set (64 B … 64 KiB), not a single
//!     parameter. Actionability statement compares cross-size
//!     behavior, which a single `bench.parameter` would hide.
//!   - `blob_size = bench.parameter(...)` (template line 19) — same
//!     reason.
//!
//! **Path substitutions (principled — file-layout adaptation):**
//!
//!   - `@import("../constants.zig")` → `@import("framework/constants.zig")`
//!   - `@import("../testing/bench.zig")` → `@import("framework/bench.zig")`
//!
//! **Surgical restructuring (principled — multi-size):**
//!
//!   - Template's single-kernel sample loop → `inline for (sizes)`
//!     wrapping the template's sample loop. Each size emits its own
//!     parseable `crc_frame_{size} = {d} ns` line and its own
//!     `assert_budget`. TB's shape is preserved *inside* the outer
//!     loop; the outer loop is our addition, justified by the
//!     cross-size actionability property.
//!   - `u128` checksum accumulator → `u64` CRC accumulator (kernel
//!     returns `u32`; `u64` still prevents DCE).
//!
//! **Additions (flaw fix — TIGER_STYLE alignment):**
//!
//!   - Pair-assertions at test start covering positive AND negative
//!     space per TIGER_STYLE's "golden rule":
//!       * Positive: `crc_frame(5, "hello") == 0x5CAC007A`. The
//!         cross-language wire vector asserted in
//!         `worker_dispatch.zig:636` and the C SHM addon. Drift
//!         between {Zig, C, TS} fires here first.
//!       * Negative 1: `crc_frame(4, "hello") != crc_frame(5, "hello")`.
//!         Declaring a different length must change the CRC — the
//!         whole reason the length prefix is inside the CRC, not
//!         outside.
//!       * Negative 2: `crc_frame(5, "hallo") != crc_frame(5, "hello")`.
//!         One-byte payload flip must change the CRC.
//!   - `bench.assert_budget` per size — documented principled
//!     divergence in `framework/bench.zig`.
//!   - Substituted report format to `"crc_frame_{size} = {d} ns"`
//!     per DR-2.
//!
//! **External commitment:** frame CRC is a cross-language wire
//! contract (`packages/vectors/shm_layout.json`: crc_convention).
//! Cannot change without simultaneous Zig + C + TS update.
//!
//! **Actionability:** if ns/call drops >10% on one payload size but
//! not others, cache behavior changed (e.g., 64 KiB case spilling
//! L1 differently). If it drops uniformly, verify SIMD kernel
//! engagement in `std.hash.crc.Crc32` and that the `inline`
//! annotation on `crc_frame` survived optimization. If the positive
//! pair-assertion fires, the CRC drifted vs the C/TS implementations
//! — cross-language frames will misalign. If either negative
//! pair-assertion fires, the CRC is no longer length-aware or
//! content-aware — data corruption will go undetected.
//!
//! **Budget calibration:** dev-machine Debug, 3 runs per size (same
//! input in smoke and benchmark mode since the parameter was
//! dropped). Observed and budgets:
//!
//!   | size   | run 1  | run 2  | run 3  | max    | 10×    | budget   |
//!   |--------|--------|--------|--------|--------|--------|----------|
//!   | 64     |   1366 |    615 |    316 |   1366 |  13660 |    15000 |
//!   | 256    |   4735 |   2103 |   1086 |   4735 |  47350 |    50000 |
//!   | 1024   |  14722 |   8060 |   4194 |  14722 | 147220 |   150000 |
//!   | 4096   |  54241 |  32239 |  16417 |  54241 | 542410 |   600000 |
//!   | 65536  | 260480 | 264483 | 119601 | 264483 |2644830 |  3000000 |
//!
//! Phase F re-calibrates on `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;

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

const sizes = [_]Size{
    .{ .bytes = 64, .name = "crc_frame_64", .budget_ns_smoke_max = 15_000 },
    .{ .bytes = 256, .name = "crc_frame_256", .budget_ns_smoke_max = 50_000 },
    .{ .bytes = 1024, .name = "crc_frame_1024", .budget_ns_smoke_max = 150_000 },
    .{ .bytes = 4096, .name = "crc_frame_4096", .budget_ns_smoke_max = 600_000 },
    .{ .bytes = 65536, .name = "crc_frame_65536", .budget_ns_smoke_max = 3_000_000 },
};

test "benchmark: crc_frame" {
    // Pair-assertion — positive space: cross-language wire vector.
    {
        const got = shm_layout.crc_frame(5, "hello");
        if (got != 0x5CAC007A) {
            std.debug.panic(
                "crc_frame: vector mismatch: got 0x{X:0>8}, want 0x5CAC007A",
                .{got},
            );
        }
    }

    // Pair-assertion — negative space 1: length prefix participates
    // in the CRC. A different declared length must change the CRC.
    {
        const with_len_5 = shm_layout.crc_frame(5, "hello");
        const with_len_4 = shm_layout.crc_frame(4, "hello");
        if (with_len_5 == with_len_4) {
            std.debug.panic("crc_frame: length prefix not part of CRC", .{});
        }
    }

    // Pair-assertion — negative space 2: payload changes must
    // change the CRC (content sensitivity).
    {
        const hello = shm_layout.crc_frame(5, "hello");
        const hallo = shm_layout.crc_frame(5, "hallo");
        if (hello == hallo) {
            std.debug.panic("crc_frame: payload flip did not change CRC", .{});
        }
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

    // Hash-of-run — same discipline as TB template line 41.
    bench.report("crc_sum {x:0>16}", .{crc_counter_sum});
}
