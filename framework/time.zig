const std = @import("std");
const assert = std.debug.assert;

/// Wall-clock time abstraction. Production uses OS clocks; simulation uses
/// a deterministic tick-driven clock. Follows TigerBeetle's Time vtable pattern.
///
/// Only `realtime` is exposed — monotonic time is handled by tick counts.
pub const Time = struct {
    context: *anyopaque,
    realtime_fn: *const fn (*anyopaque) i64,

    /// Returns wall-clock time as seconds since Unix epoch.
    pub fn realtime(self: Time) i64 {
        return self.realtime_fn(self.context);
    }
};

/// Production time source — delegates to the OS.
pub const TimeReal = struct {
    pub fn time(self: *TimeReal) Time {
        return .{
            .context = @ptrCast(self),
            .realtime_fn = realtime,
        };
    }

    fn realtime(_: *anyopaque) i64 {
        return @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_s));
    }
};

/// Deterministic time source for simulation and testing.
/// The test harness controls `now` directly.
pub const TimeSim = struct {
    now: i64 = 1_700_000_000, // 2023-11-14 — arbitrary epoch for tests

    pub fn time(self: *TimeSim) Time {
        return .{
            .context = @ptrCast(self),
            .realtime_fn = realtime,
        };
    }

    fn realtime(ctx: *anyopaque) i64 {
        const self: *TimeSim = @ptrCast(@alignCast(ctx));
        return self.now;
    }

    /// Advance by the given number of seconds.
    pub fn advance(self: *TimeSim, seconds: i64) void {
        self.now += seconds;
    }
};

// =====================================================================
// Tests
// =====================================================================

test "TimeReal returns plausible wall-clock time" {
    var real = TimeReal{};
    const t = real.time();
    const now = t.realtime();
    // Should be after 2024-01-01 and before 2100-01-01.
    try std.testing.expect(now > 1_704_067_200);
    try std.testing.expect(now < 4_102_444_800);
}

test "TimeSim starts at fixed epoch" {
    var sim = TimeSim{};
    const t = sim.time();
    try std.testing.expectEqual(t.realtime(), 1_700_000_000);
}

test "TimeSim advance" {
    var sim = TimeSim{};
    const t = sim.time();
    sim.advance(3600);
    try std.testing.expectEqual(t.realtime(), 1_700_003_600);
    sim.advance(-1800);
    try std.testing.expectEqual(t.realtime(), 1_700_001_800);
}
