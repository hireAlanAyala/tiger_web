//! PRNG — Deterministic pseudo-random number generator for fuzz testing.
//!
//! Xoshiro256++ seeded by SplitMix64, following TigerBeetle's PRNG.
//! No floating point, no stdlib PRNG dependency, fully deterministic.
//! Same seed → same sequence → reproducible test failures.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;

s: [4]u64,

const PRNG = @This();

/// Split a string on the first occurrence of a delimiter.
fn cut(haystack: []const u8, needle: []const u8) ?struct { []const u8, []const u8 } {
    const i = std.mem.indexOf(u8, haystack, needle) orelse return null;
    return .{ haystack[0..i], haystack[i + needle.len ..] };
}

/// A less than one rational number, used to specify probabilities.
pub const Ratio = struct {
    // Invariant: numerator ≤ denominator.
    numerator: u64,
    // Invariant: denominator ≠ 0.
    denominator: u64,

    pub fn zero() Ratio {
        return .{ .numerator = 0, .denominator = 1 };
    }

    pub fn format(
        r: Ratio,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        if (r.numerator == 0) return writer.print("0", .{});
        return writer.print("{d}/{d}", .{ r.numerator, r.denominator });
    }

    pub fn parse_flag_value(
        string: []const u8,
        static_diagnostic: *?[]const u8,
    ) error{InvalidFlagValue}!Ratio {
        assert(string.len > 0);
        if (string.len == 1 and string[0] == '0') return .zero();

        const string_numerator, const string_denominator = cut(string, "/") orelse {
            static_diagnostic.* = "expected 'a/b' ratio, but found:";
            return error.InvalidFlagValue;
        };

        const numerator = std.fmt.parseInt(u64, string_numerator, 10) catch {
            static_diagnostic.* = "invalid numerator:";
            return error.InvalidFlagValue;
        };
        const denominator = std.fmt.parseInt(u64, string_denominator, 10) catch {
            static_diagnostic.* = "invalid denominator:";
            return error.InvalidFlagValue;
        };
        if (denominator == 0) {
            static_diagnostic.* = "denominator is zero:";
            return error.InvalidFlagValue;
        }
        if (numerator > denominator) {
            static_diagnostic.* = "ratio greater than 1:";
            return error.InvalidFlagValue;
        }
        return ratio(numerator, denominator);
    }
};

/// Canonical constructor for Ratio.
pub fn ratio(numerator: u64, denominator: u64) Ratio {
    assert(denominator > 0);
    assert(numerator <= denominator);
    return .{ .numerator = numerator, .denominator = denominator };
}

/// Bridge to Zig's built-in test seed for reproducible unit tests.
/// Usage: `var prng = PRNG.from_seed_testing();`
/// Seed is passed via `--seed=N` to the test binary; defaults vary per run.
pub fn from_seed_testing() PRNG {
    comptime assert(@import("builtin").is_test);
    return .from_seed(std.testing.random_seed);
}

pub fn from_seed(seed: u64) PRNG {
    var s = seed;
    return .{ .s = .{
        split_mix_64(&s),
        split_mix_64(&s),
        split_mix_64(&s),
        split_mix_64(&s),
    } };
}

/// SplitMix64 — used only for seed expansion into xoshiro state.
fn split_mix_64(s: *u64) u64 {
    s.* +%= 0x9e3779b97f4a7c15;
    var z = s.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

/// Xoshiro256++ core.
fn next(prng: *PRNG) u64 {
    const r = math.rotl(u64, prng.s[0] +% prng.s[3], 23) +% prng.s[0];
    const t = prng.s[1] << 17;

    prng.s[2] ^= prng.s[0];
    prng.s[3] ^= prng.s[1];
    prng.s[1] ^= prng.s[2];
    prng.s[0] ^= prng.s[3];

    prng.s[2] ^= t;
    prng.s[3] = math.rotl(u64, prng.s[3], 45);

    return r;
}

/// Returns a uniformly distributed integer of type T.
pub fn int(prng: *PRNG, comptime T: type) T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    if (T == u64) return prng.next();
    if (@sizeOf(T) < @sizeOf(u64)) return @truncate(prng.next());
    var result: T = undefined;
    prng.fill(std.mem.asBytes(&result));
    return result;
}

/// Unbiased integer in [0, max]. Uses Lemire's debiased multiply-and-shift.
pub fn int_inclusive(prng: *PRNG, comptime T: type, max: T) T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    if (max == math.maxInt(T)) return prng.int(T);

    const bits = @typeInfo(T).int.bits;
    const less_than = max + 1;

    var x = prng.int(T);
    var m = math.mulWide(T, x, less_than);
    var l: T = @truncate(m);
    if (l < less_than) {
        var t = -%less_than;
        if (t >= less_than) {
            t -= less_than;
            if (t >= less_than) {
                t %= less_than;
            }
        }
        while (l < t) {
            x = prng.int(T);
            m = math.mulWide(T, x, less_than);
            l = @truncate(m);
        }
    }
    return @intCast(m >> bits);
}

// Deliberately excluded from the API to normalize everything to closed ranges.
// Somewhat surprisingly, closed ranges are more convenient for generating random numbers:
// - passing zero is not a subtle error
// - passing maxInt allows generating any integer
// - at the call-site, inclusive is usually somewhat more obvious.
pub const int_exclusive = @compileError("intentionally not implemented");

/// Generates a random valid index for the slice.
pub fn index(prng: *PRNG, slice: anytype) usize {
    assert(slice.len > 0);
    return prng.int_inclusive(usize, slice.len - 1);
}

/// Unbiased integer in [min, max].
pub fn range_inclusive(prng: *PRNG, comptime T: type, min: T, max: T) T {
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    assert(min <= max);
    return min + prng.int_inclusive(T, max - min);
}

/// Returns a Word with a single randomly-chosen bit set.
pub fn bit(prng: *PRNG, comptime Word: type) Word {
    comptime assert(@typeInfo(Word) == .int);
    comptime assert(@typeInfo(Word).int.signedness == .unsigned);
    return @as(Word, 1) << prng.int_inclusive(std.math.Log2Int(Word), @bitSizeOf(Word) - 1);
}

/// True with probability 0.5.
pub fn boolean(prng: *PRNG) bool {
    return prng.next() & 1 == 1;
}

/// Returns true with the given rational probability.
pub fn chance(prng: *PRNG, probability: Ratio) bool {
    assert(probability.denominator > 0);
    assert(probability.numerator <= probability.denominator);
    return prng.int_inclusive(u64, probability.denominator - 1) < probability.numerator;
}

/// Like enum_weighted, but doesn't require specifying the enum up-front.
pub fn chances(prng: *PRNG, weights: anytype) std.meta.FieldEnum(@TypeOf(weights)) {
    const Enum = std.meta.FieldEnum(@TypeOf(weights));
    return enum_weighted_impl(prng, Enum, weights);
}

/// Random enum variant, uniform distribution.
pub fn enum_uniform(prng: *PRNG, comptime Enum: type) Enum {
    const values = std.enums.values(Enum);
    return values[prng.index(values)];
}

/// Weight struct for weighted enum selection.
pub fn EnumWeightsType(comptime E: type) type {
    return std.enums.EnumFieldStruct(E, u64, null);
}

/// Random enum variant, weighted by per-variant probabilities.
pub fn enum_weighted(prng: *PRNG, comptime Enum: type, weights: EnumWeightsType(Enum)) Enum {
    return enum_weighted_impl(prng, Enum, weights);
}

fn enum_weighted_impl(prng: *PRNG, comptime Enum: type, weights: anytype) Enum {
    const fields = @typeInfo(Enum).@"enum".fields;
    var total: u64 = 0;
    inline for (fields) |field| {
        total += @field(weights, field.name);
    }
    assert(total > 0);
    var pick = prng.int_inclusive(u64, total - 1);
    inline for (fields) |field| {
        const weight = @field(weights, field.name);
        if (pick < weight) return @as(Enum, @enumFromInt(field.value));
        pick -= weight;
    }
    unreachable;
}

/// Return a distribution for use with `enum_weighted`.
///
/// This is swarm testing: some variants are disabled completely,
/// and the rest have wildly different probabilities.
pub fn enum_weights(prng: *PRNG, comptime Enum: type) EnumWeightsType(Enum) {
    const fields = comptime std.meta.fieldNames(Enum);

    var combination = Combination.init(.{
        .total = fields.len,
        .sample = prng.range_inclusive(u32, 1, fields.len),
    });
    defer assert(combination.done());

    var ws: EnumWeightsType(Enum) = undefined;
    inline for (fields) |field| {
        @field(ws, field) = if (combination.take(prng))
            prng.range_inclusive(u64, 1, 100)
        else
            0;
    }

    return ws;
}

/// An iterator-style API for selecting a random k-of-n combination.
pub const Combination = struct {
    total: u32,
    sample: u32,
    taken: u32,
    seen: u32,

    pub fn init(options: struct { total: u32, sample: u32 }) Combination {
        assert(options.sample <= options.total);
        return .{
            .total = options.total,
            .sample = options.sample,
            .taken = 0,
            .seen = 0,
        };
    }

    pub fn done(self: *const Combination) bool {
        return self.taken == self.sample and self.seen == self.total;
    }

    pub fn take(self: *Combination, prng: *PRNG) bool {
        assert(self.seen < self.total);
        assert(self.taken <= self.sample);

        const n = self.total - self.seen;
        const k = self.sample - self.taken;
        const result = prng.chance(ratio(k, n));

        self.seen += 1;
        if (result) self.taken += 1;
        return result;
    }
};

/// An iterator-style API for selecting a single element out of a
/// weighted sequence, without a priori knowledge about the total weight.
pub const Reservoir = struct {
    total: u64,

    pub fn init() Reservoir {
        return .{ .total = 0 };
    }

    pub fn replace(reservoir: *Reservoir, prng: *PRNG, weight: u64) bool {
        reservoir.total += weight;
        return prng.chance(ratio(weight, reservoir.total));
    }
};

/// Fisher-Yates shuffle.
pub fn shuffle(prng: *PRNG, comptime T: type, slice: []T) void {
    for (0..slice.len) |i| {
        const j = prng.int_inclusive(u64, i);
        std.mem.swap(T, &slice[i], &slice[j]);
    }
}

/// Fill buffer with random bytes.
pub fn fill(prng: *PRNG, target: []u8) void {
    var i: usize = 0;
    const aligned_len = target.len - (target.len & 7);

    while (i < aligned_len) : (i += 8) {
        var n = prng.next();
        comptime var j: usize = 0;
        inline while (j < 8) : (j += 1) {
            target[i + j] = @as(u8, @truncate(n));
            n >>= 8;
        }
    }

    if (i != target.len) {
        var n = prng.next();
        while (i < target.len) : (i += 1) {
            target[i] = @as(u8, @truncate(n));
            n >>= 8;
        }
    }
}

// =====================================================================
// Tests
// =====================================================================

test "from_seed produces non-zero state" {
    const prng = PRNG.from_seed(0);
    for (prng.s) |s| {
        assert(s != 0);
    }
}

test "deterministic — same seed same sequence" {
    var a = PRNG.from_seed(42);
    var b = PRNG.from_seed(42);
    for (0..100) |_| {
        assert(a.int(u64) == b.int(u64));
    }
}

test "different seeds diverge" {
    var a = PRNG.from_seed(1);
    var b = PRNG.from_seed(2);
    var differ: u32 = 0;
    for (0..100) |_| {
        if (a.int(u64) != b.int(u64)) differ += 1;
    }
    assert(differ > 90);
}

test "int_inclusive respects bounds" {
    var prng = PRNG.from_seed(99);
    for (0..1000) |_| {
        const v = prng.int_inclusive(u8, 10);
        assert(v <= 10);
    }
    // max == maxInt should not hang
    _ = prng.int_inclusive(u8, 255);
    _ = prng.int_inclusive(u64, math.maxInt(u64));
}

test "range_inclusive respects bounds" {
    var prng = PRNG.from_seed(77);
    for (0..1000) |_| {
        const v = prng.range_inclusive(u32, 100, 200);
        assert(v >= 100);
        assert(v <= 200);
    }
}

test "boolean roughly 50/50" {
    var prng = PRNG.from_seed(55);
    var heads: u32 = 0;
    for (0..1000) |_| {
        if (prng.boolean()) heads += 1;
    }
    assert(heads > 400);
    assert(heads < 600);
}

test "chance — 0 always false, den always true" {
    var prng = PRNG.from_seed(33);
    for (0..100) |_| {
        assert(!prng.chance(ratio(0, 10)));
        assert(prng.chance(ratio(10, 10)));
    }
}

test "chances — weighted inline choice" {
    const E = enum { a, b };
    var prng = PRNG.from_seed(11);
    var a_count: u32 = 0;
    var b_count: u32 = 0;
    for (0..1000) |_| {
        switch (prng.enum_weighted(E, .{ .a = 1, .b = 3 })) {
            .a => a_count += 1,
            .b => b_count += 1,
        }
    }
    assert(a_count > 150);
    assert(b_count > 600);
}

test "enum_uniform covers all variants" {
    const E = enum { a, b, c };
    var prng = PRNG.from_seed(11);
    var seen = [_]bool{ false, false, false };
    for (0..100) |_| {
        switch (prng.enum_uniform(E)) {
            .a => seen[0] = true,
            .b => seen[1] = true,
            .c => seen[2] = true,
        }
    }
    for (seen) |s| assert(s);
}

test "enum_weighted respects zero weight" {
    const E = enum { a, b, c };
    var prng = PRNG.from_seed(22);
    for (0..100) |_| {
        const v = prng.enum_weighted(E, .{ .a = 0, .b = 1, .c = 2 });
        assert(v != .a);
    }
}

test "enum_weights produces at least one non-zero" {
    const E = enum { a, b, c, d, e };
    var prng = PRNG.from_seed(44);
    for (0..20) |_| {
        const ws = prng.enum_weights(E);
        const total = ws.a + ws.b + ws.c + ws.d + ws.e;
        assert(total > 0);
    }
}

test "fill covers full buffer" {
    var prng = PRNG.from_seed(66);
    for (0..33) |size| {
        var buf: [32]u8 = [_]u8{0} ** 32;
        prng.fill(buf[0..size]);
        // Check that filled portion is not all zeros (probabilistic but reliable).
        if (size >= 4) {
            var any_nonzero = false;
            for (buf[0..size]) |b| {
                if (b != 0) any_nonzero = true;
            }
            assert(any_nonzero);
        }
    }
}

test "Combination selects exact sample count" {
    var prng = PRNG.from_seed(88);
    for (0..20) |_| {
        const total: u32 = 7;
        const sample = prng.range_inclusive(u32, 1, total);
        var combo = Combination.init(.{ .total = total, .sample = sample });
        var taken: u32 = 0;
        for (0..total) |_| {
            if (combo.take(&prng)) taken += 1;
        }
        assert(combo.done());
        assert(taken == sample);
    }
}

test "no floating point please" {
    const file_text = @embedFile("prng.zig");
    assert(std.mem.indexOf(u8, file_text, "f" ++ "32") == null);
    assert(std.mem.indexOf(u8, file_text, "f" ++ "64") == null);
}
