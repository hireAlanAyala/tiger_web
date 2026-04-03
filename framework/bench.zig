//! Micro benchmarking harness.
//!
//! Modeled on TigerBeetle's src/testing/bench.zig.
//!
//! Goals:
//! - relative (comparative) benchmarking,
//! - manual checks when refactoring/optimizing,
//! - no benchmark bitrot.
//!
//! Non-goals:
//! - absolute benchmarking,
//! - continuous benchmarking,
//! - automatic regression detection.
//!
//! Smoke mode runs as part of `zig build unit-test` — small inputs, silent,
//! prevents bitrot. Benchmark mode runs via `zig build bench` — large inputs,
//! prints results to stderr.

const std = @import("std");
const assert = std.debug.assert;

const seed_benchmark: u64 = 42;

const mode: enum { smoke, benchmark } =
    if (@import("bench_options").benchmark) .benchmark else .smoke;

seed: u64,
timer: std.time.Timer,
timing: bool,

const Bench = @This();

pub fn init() Bench {
    return .{
        .seed = if (mode == .benchmark) seed_benchmark else 12345,
        .timer = undefined,
        .timing = false,
    };
}

pub fn deinit(bench: *Bench) void {
    assert(!bench.timing);
    bench.* = undefined;
}

/// Dual-valued parameter: small for smoke, large for benchmark.
/// Override in benchmark mode via environment variable: `ops=10000 ./zig/zig build bench`.
pub fn parameter(
    bench: *const Bench,
    comptime name: []const u8,
    value_smoke: u64,
    value_benchmark: u64,
) u64 {
    assert(value_smoke <= value_benchmark);
    const value = parameter_fallible(name, value_smoke, value_benchmark) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => @panic("invalid benchmark parameter value"),
    };
    bench.report("{s}={}", .{ name, value });
    return value;
}

fn parameter_fallible(
    comptime name: []const u8,
    value_smoke: u64,
    value_benchmark: u64,
) std.fmt.ParseIntError!u64 {
    assert(value_smoke <= value_benchmark);
    return switch (mode) {
        .smoke => value_smoke,
        .benchmark => std.process.parseEnvVarInt(name, u64, 10) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return value_benchmark,
            else => |e| return e,
        },
    };
}

pub fn start(bench: *Bench) void {
    assert(!bench.timing);
    bench.timing = true;
    bench.timer = std.time.Timer.start() catch unreachable;
}

pub fn stop(bench: *Bench) u64 {
    assert(bench.timing);
    bench.timing = false;
    return bench.timer.lap();
}

/// Sort durations, return 3rd fastest (discard 2 fastest outliers).
/// See https://lemire.me/blog/2018/01/16/microbenchmarking-calls-for-idealized-conditions/
pub fn estimate(_: *const Bench, durations: []u64) u64 {
    assert(durations.len >= 8);
    std.sort.block(u64, durations, {}, struct {
        fn order(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.order);
    return durations[2];
}

/// Assert that a measured duration is within budget. Smoke mode only —
/// benchmark mode prints results without asserting.
/// Catches catastrophic regressions (O(n²), accidental allocations).
pub fn assert_budget(_: *const Bench, measured_ns: u64, budget_ns: u64, comptime name: []const u8) void {
    switch (mode) {
        .smoke => {
            if (measured_ns > budget_ns) {
                std.debug.panic(
                    "budget exceeded: {s}: {d}ns > {d}ns budget",
                    .{ name, measured_ns, budget_ns },
                );
            }
        },
        .benchmark => {},
    }
}

/// Only prints in benchmark mode. Silent in smoke.
pub fn report(_: *const Bench, comptime fmt: []const u8, args: anytype) void {
    switch (mode) {
        .smoke => {},
        .benchmark => std.debug.print(fmt ++ "\n", args),
    }
}
