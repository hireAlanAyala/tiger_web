//! Shared utilities for fuzz tests.

const std = @import("std");
const assert = std.debug.assert;
const PRNG = @import("tiger_framework").prng;

pub const FuzzArgs = struct {
    seed: u64,
    events_max: ?usize,
};

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
