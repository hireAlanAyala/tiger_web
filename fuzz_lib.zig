//! Shared utilities for fuzz tests.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const PRNG = @import("stdx").PRNG;

pub const FuzzArgs = struct {
    seed: u64,
    events_max: ?usize,
};

/// ID pools for fuzz message generation. Handlers that reference
/// existing entities (get_product, transfer_inventory, etc.) pick
/// IDs from these pools.
pub const IdPools = struct {
    product_ids: []const u128,
    collection_ids: []const u128,
    order_ids: []const u128,
};

/// Dummy storage for tests and fuzzers that don't exercise QUERY frames.
/// QUERY frames are never generated in unit tests — DummyStorage panics
/// if query_raw is called (indicating a test bug).
pub const DummyStorage = struct {
    pub const QueryMode = enum { query, query_all };
    pub fn query_raw(_: *const DummyStorage, _: []const u8, _: []const u8, _: u8, _: QueryMode, _: []u8) ?[]const u8 {
        @panic("DummyStorage.query_raw called — test should not generate QUERY frames");
    }
};

const GiB = 1024 * 1024 * 1024;

/// Cap virtual address space so a leaking fuzzer OOMs fast instead of
/// swapping the machine. Matches TigerBeetle's testing/fuzz.zig.
pub fn limit_ram() void {
    if (builtin.target.os.tag != .linux) return;

    std.posix.setrlimit(.AS, .{
        .cur = 20 * GiB,
        .max = 20 * GiB,
    }) catch |err| {
        std.log.scoped(.fuzz).warn("failed to setrlimit address space: {}", .{err});
    };
}

/// Return a weight distribution for use with `PRNG.enum_weighted`.
///
/// This is swarm testing: some variants are disabled completely,
/// and the rest have wildly different probabilities. Matches
/// TigerBeetle's testing/fuzz.zig random_enum_weights.
pub fn random_enum_weights(prng: *PRNG, comptime Enum: type) PRNG.EnumWeightsType(Enum) {
    const fields = comptime std.meta.fieldNames(Enum);

    var combination = PRNG.Combination.init(.{
        .total = fields.len,
        .sample = prng.range_inclusive(u32, 1, fields.len),
    });
    defer assert(combination.done());

    var ws: PRNG.EnumWeightsType(Enum) = undefined;
    inline for (fields) |field| {
        @field(ws, field) = if (combination.take(prng))
            prng.range_inclusive(u64, 1, 100)
        else
            0;
    }

    return ws;
}
