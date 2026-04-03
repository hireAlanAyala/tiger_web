const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const stdx = @import("stdx");
const Instant = stdx.Instant;

const is_linux = builtin.target.os.tag == .linux;
const posix = std.posix;

/// Time vtable — monotonic, realtime, tick.
///
/// Matches TigerBeetle's Time exactly. Three methods:
///   monotonic() → Instant (elapsed time, not wall clock)
///   realtime() → i64 (wall clock nanoseconds since Unix epoch)
///   tick() → void (advance simulated time)
///
/// The tracer requires monotonic(). The server uses realtime()
/// for wall-clock timestamps. Simulation controls both via TimeSim.
pub const Time = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        monotonic: *const fn (*anyopaque) u64,
        realtime: *const fn (*anyopaque) i64,
        tick: *const fn (*anyopaque) void,
    };

    /// Monotonic timestamp — elapsed time since an arbitrary origin.
    /// Not affected by wall-clock adjustments. Use for measuring durations.
    pub fn monotonic(self: Time) Instant {
        return .{ .ns = self.vtable.monotonic(self.context) };
    }

    /// Wall-clock time — nanoseconds since Unix epoch.
    /// Affected by NTP adjustments. Use for timestamps visible to users.
    pub fn realtime(self: Time) i64 {
        return self.vtable.realtime(self.context);
    }

    /// Advance simulated time by one tick. No-op for real time.
    pub fn tick(self: Time) void {
        self.vtable.tick(self.context);
    }
};

/// Production time source — delegates to OS clocks.
/// monotonic: CLOCK_BOOTTIME (includes time during suspend).
/// realtime: CLOCK_REALTIME (wall clock).
pub const TimeReal = struct {
    /// Guard against monotonic clock regression (hardware/kernel bugs).
    /// TB: "crash and come back with a valid clock rather than get stuck."
    monotonic_guard: u64 = 0,

    pub fn time(self: *TimeReal) Time {
        return .{
            .context = @ptrCast(self),
            .vtable = &.{
                .monotonic = monotonic,
                .realtime = realtime,
                .tick = tick,
            },
        };
    }

    fn monotonic(context: *anyopaque) u64 {
        const self: *TimeReal = @ptrCast(@alignCast(context));

        if (!is_linux) @compileError("monotonic clock: Linux only (CLOCK_BOOTTIME)");

        // CLOCK_BOOTTIME: true monotonic on Linux — includes elapsed time
        // during suspend (e.g. VM migration). CLOCK_MONOTONIC does not.
        // See: https://github.com/ziglang/zig/pull/933#discussion_r656021295
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.BOOTTIME) catch {
            @panic("CLOCK_BOOTTIME required");
        };
        const m = @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));

        if (m < self.monotonic_guard) @panic("a hardware/kernel bug regressed the monotonic clock");
        self.monotonic_guard = m;
        return m;
    }

    fn realtime(_: *anyopaque) i64 {
        if (!is_linux) @compileError("realtime clock: Linux only");
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
        return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    fn tick(_: *anyopaque) void {}
};

/// Deterministic time source for simulation and testing.
///
/// monotonic: ticks × resolution (nanoseconds per tick).
/// realtime: epoch + monotonic (wall clock derived from tick count).
/// tick: increments the tick counter.
///
/// Tests control time explicitly — advance ticks, observe deterministic
/// timestamps. Same seed = same trace output.
pub const TimeSim = struct {
    /// Nanoseconds per tick. Default 10ms matches server tick interval.
    resolution: u64 = 10 * std.time.ns_per_ms,
    /// Tick counter — advanced by tick().
    ticks: u64 = 0,
    /// Wall-clock epoch — arbitrary fixed origin for deterministic realtime.
    epoch: i64 = 1_700_000_000 * std.time.ns_per_s, // 2023-11-14

    pub fn time(self: *TimeSim) Time {
        return .{
            .context = @ptrCast(self),
            .vtable = &.{
                .monotonic = monotonic,
                .realtime = realtime,
                .tick = tick_fn,
            },
        };
    }

    fn monotonic(context: *anyopaque) u64 {
        const self: *TimeSim = @ptrCast(@alignCast(context));
        return self.ticks * self.resolution;
    }

    fn realtime(context: *anyopaque) i64 {
        const self: *TimeSim = @ptrCast(@alignCast(context));
        return self.epoch + @as(i64, @intCast(self.ticks * self.resolution));
    }

    fn tick_fn(context: *anyopaque) void {
        const self: *TimeSim = @ptrCast(@alignCast(context));
        self.ticks += 1;
    }

    /// Advance by N seconds (convenience for tests that set wall-clock time).
    pub fn advance(self: *TimeSim, seconds: i64) void {
        // Advance the epoch, not the ticks — ticks are for monotonic.
        self.epoch += seconds * std.time.ns_per_s;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "TimeReal monotonic smoke" {
    if (!is_linux) return error.SkipZigTest;
    var real = TimeReal{};
    const t = real.time();
    const a = t.monotonic();
    const b = t.monotonic();
    try std.testing.expect(b.ns >= a.ns);
}

test "TimeReal realtime plausible" {
    if (!is_linux) return error.SkipZigTest;
    var real = TimeReal{};
    const t = real.time();
    const now = t.realtime();
    // After 2024-01-01, before 2100-01-01 (in nanoseconds).
    try std.testing.expect(now > 1_704_067_200 * std.time.ns_per_s);
    try std.testing.expect(now < 4_102_444_800 * std.time.ns_per_s);
}

test "TimeSim monotonic deterministic" {
    var sim = TimeSim{};
    const t = sim.time();
    try std.testing.expectEqual(@as(u64, 0), t.monotonic().ns);
    t.tick();
    try std.testing.expectEqual(@as(u64, 10 * std.time.ns_per_ms), t.monotonic().ns);
    t.tick();
    try std.testing.expectEqual(@as(u64, 20 * std.time.ns_per_ms), t.monotonic().ns);
}

test "TimeSim realtime deterministic" {
    var sim = TimeSim{};
    const t = sim.time();
    const epoch = 1_700_000_000 * std.time.ns_per_s;
    try std.testing.expectEqual(@as(i64, epoch), t.realtime());
    t.tick();
    try std.testing.expectEqual(@as(i64, epoch + 10 * std.time.ns_per_ms), t.realtime());
}

test "TimeSim advance" {
    var sim = TimeSim{};
    const t = sim.time();
    const epoch = 1_700_000_000 * std.time.ns_per_s;
    sim.advance(3600);
    try std.testing.expectEqual(@as(i64, epoch + 3600 * std.time.ns_per_s), t.realtime());
}

test "TimeSim custom resolution" {
    var sim = TimeSim{ .resolution = 1 }; // 1ns per tick
    const t = sim.time();
    t.tick();
    try std.testing.expectEqual(@as(u64, 1), t.monotonic().ns);
    t.tick();
    try std.testing.expectEqual(@as(u64, 2), t.monotonic().ns);
}
