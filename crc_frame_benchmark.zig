//! CRC32 frame-checksum primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (the cp-template for every primitive bench in phase C).
//!
//! **Survival:** ~32/43 lines of the template carry over (~75%). The
//! template's scaffold (Bench init/deinit, arena, PRNG seed, sample
//! loop, estimate, hash-of-run print) is verbatim; the kernel call
//! and the parameter shape are substituted for this kernel's needs.
//!
//! Substitutions relative to the template:
//!
//!   - Kernel: `checksum(blob)` → `shm_layout.crc_frame(len, payload)`
//!   - Parameter: single `blob_size` → inline loop over 5 canonical
//!     payload sizes (64, 256, 1024, 4096, 65536 bytes). Plan
//!     phase-C.1 calls this out explicitly because the actionability
//!     statement below compares cross-size behavior.
//!   - Counter: `u128` Aegis accumulator → `u64` XOR accumulator (CRC
//!     returns `u32`; `u64` still prevents dead-code elimination).
//!   - Report format: `"{} for whole blob"` → `"crc_frame_{size} = {d} ns"`
//!     (DR-2 — `scripts/devhub.zig`'s `get_measurement` parser).
//!
//! Additions beyond the template (all principled):
//!
//!   - Cross-language pair-assertion at test start: `crc_frame(5, "hello")`
//!     must equal `0x5CAC007A`. Matches the vector asserted in
//!     `framework/worker_dispatch.zig:636` and in the C SHM addon
//!     (`shm.c`, via zlib). Divergence across any of the three
//!     implementations fires here first.
//!   - `bench.assert_budget` per size (same principled divergence
//!     documented in `framework/bench.zig`).
//!
//! **External commitment:** the frame CRC is a cross-language wire
//! contract (`packages/vectors/shm_layout.json`: crc_convention).
//! Cannot change without simultaneous Zig + C + TS update, so
//! regression detection here is load-bearing.
//!
//! **Actionability:** if ns/call drops >10%, check whether Zig added
//! SIMD specialization for CRC32 or `std.hash.crc.Crc32` changed. If
//! ns/call rises >10%, verify the `inline` annotation on `crc_frame`
//! survived optimization. A drop on one payload size but not others
//! usually means cache behavior changed (e.g., the 65536-byte case
//! spilling L1 differently).
//!
//! **Budget calibration:** 10× expected per size on dev machine.
//! zlib-style CRC32 runs ~1 GB/s in Debug; 5+ GB/s with hardware
//! acceleration. Budgets generous for Debug + slow CI. Re-calibrate
//! on ubuntu-22.04 in phase F.

const std = @import("std");

const cache_line_size = @import("framework/constants.zig").cache_line_size;
const shm_layout = @import("framework/shm_layout.zig");

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const repetitions = 35;

const Size = struct {
    bytes: u32,
    name: []const u8,
    budget_ns: u64,
};

const sizes = [_]Size{
    .{ .bytes = 64, .name = "crc_frame_64", .budget_ns = 5_000 },
    .{ .bytes = 256, .name = "crc_frame_256", .budget_ns = 10_000 },
    .{ .bytes = 1024, .name = "crc_frame_1024", .budget_ns = 20_000 },
    .{ .bytes = 4096, .name = "crc_frame_4096", .budget_ns = 80_000 },
    .{ .bytes = 65536, .name = "crc_frame_65536", .budget_ns = 1_000_000 },
};

test "benchmark: crc_frame" {
    // Cross-language pair-assertion before measurement. If this fires,
    // one of {Zig shm_layout.crc_frame, C shm.c, TS worker SHM client}
    // has drifted and no throughput number is meaningful.
    const vector_crc = shm_layout.crc_frame(5, "hello");
    if (vector_crc != 0x5CAC007A) {
        std.debug.panic(
            "crc_frame cross-language vector mismatch: got 0x{X:0>8}, want 0x5CAC007A",
            .{vector_crc},
        );
    }

    var bench: Bench = .init();
    defer bench.deinit();

    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var prng = stdx.PRNG.from_seed(bench.seed);

    var crc_counter: u64 = 0;

    inline for (sizes) |s| {
        const blob = try arena.alignedAlloc(u8, cache_line_size, s.bytes);
        prng.fill(blob);

        var duration_samples: [repetitions]stdx.Duration = undefined;
        for (&duration_samples) |*duration| {
            bench.start();
            crc_counter +%= shm_layout.crc_frame(s.bytes, blob);
            duration.* = bench.stop();
        }

        const result = bench.estimate(&duration_samples);
        bench.report(s.name ++ " = {d} ns", .{result.ns});
        bench.assert_budget(result, .{ .ns = s.budget_ns }, s.name);
    }

    // See "benchmark: API tutorial" for why the hash-of-run is printed.
    bench.report("crc_sum {x:0>16}", .{crc_counter});
}
