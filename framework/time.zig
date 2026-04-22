const std = @import("std");
const builtin = @import("builtin");

const stdx = @import("stdx");

const constants = @import("constants.zig");
const posix = std.posix;
const system = posix.system;
const assert = std.debug.assert;
const is_darwin = builtin.target.os.tag.isDarwin();
const is_linux = builtin.target.os.tag == .linux;
const Instant = stdx.Instant;

pub const Time = struct {
    context: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        monotonic: *const fn (*anyopaque) u64,
        realtime: *const fn (*anyopaque) i64,
        tick: *const fn (*anyopaque) void,
    };

    /// A timestamp to measure elapsed time, meaningful only on the same system, not across reboots.
    /// Always use a monotonic timestamp if the goal is to measure elapsed time.
    /// This clock is not affected by discontinuous jumps in the system time, for example if the
    /// system administrator manually changes the clock.
    pub fn monotonic(self: Time) Instant {
        return .{ .ns = self.vtable.monotonic(self.context) };
    }

    /// A timestamp to measure real (i.e. wall clock) time, meaningful across systems, and reboots.
    /// This clock is affected by discontinuous jumps in the system time.
    pub fn realtime(self: Time) i64 {
        return self.vtable.realtime(self.context);
    }

    pub fn tick(self: Time) void {
        self.vtable.tick(self.context);
    }
};

pub const TimeOS = struct {
    /// Hardware and/or software bugs can mean that the monotonic clock may regress.
    /// One example (of many): https://bugzilla.redhat.com/show_bug.cgi?id=448449
    /// We crash the process for safety if this ever happens, to protect against infinite loops.
    /// It's better to crash and come back with a valid monotonic clock than get stuck forever.
    monotonic_guard: u64 = 0,

    pub fn time(self: *TimeOS) Time {
        return .{
            .context = self,
            .vtable = &.{
                .monotonic = monotonic,
                .realtime = realtime,
                .tick = tick,
            },
        };
    }

    fn monotonic(context: *anyopaque) u64 {
        const self: *TimeOS = @ptrCast(@alignCast(context));

        const m = blk: {
            if (is_darwin) break :blk monotonic_darwin();
            if (is_linux) break :blk monotonic_linux();
            @compileError("unsupported OS");
        };

        // "Oops!...I Did It Again"
        if (m < self.monotonic_guard) @panic("a hardware/kernel bug regressed the monotonic clock");
        self.monotonic_guard = m;
        return m;
    }

    fn monotonic_darwin() u64 {
        assert(is_darwin);
        // Uses mach_continuous_time() instead of mach_absolute_time() as it counts while suspended.
        //
        // https://developer.apple.com/documentation/kernel/1646199-mach_continuous_time
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.c.auto.html
        const darwin = struct {
            const mach_timebase_info_t = system.mach_timebase_info_data;
            extern "c" fn mach_timebase_info(info: *mach_timebase_info_t) system.kern_return_t;
            extern "c" fn mach_continuous_time() u64;
        };

        // mach_timebase_info() called through libc already does global caching for us
        //
        // https://opensource.apple.com/source/xnu/xnu-7195.81.3/libsyscall/wrappers/mach_timebase_info.c.auto.html
        var info: darwin.mach_timebase_info_t = undefined;
        if (darwin.mach_timebase_info(&info) != 0) @panic("mach_timebase_info() failed");

        const now = darwin.mach_continuous_time();
        return (now * info.numer) / info.denom;
    }

    fn monotonic_linux() u64 {
        assert(is_linux);
        // The true monotonic clock on Linux is not in fact CLOCK_MONOTONIC:
        //
        // CLOCK_MONOTONIC excludes elapsed time while the system is suspended (e.g. VM migration).
        //
        // CLOCK_BOOTTIME is the same as CLOCK_MONOTONIC but includes elapsed time during a suspend.
        //
        // For more detail and why CLOCK_MONOTONIC_RAW is even worse than CLOCK_MONOTONIC, see
        // https://github.com/ziglang/zig/pull/933#discussion_r656021295.
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.BOOTTIME) catch {
            @panic("CLOCK_BOOTTIME required");
        };
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    fn realtime(_: *anyopaque) i64 {
        // macos has supported clock_gettime() since 10.12:
        // https://opensource.apple.com/source/Libc/Libc-1158.1.2/gen/clock_gettime.3.auto.html
        if (is_darwin or is_linux) return realtime_unix();
        @compileError("unsupported OS");
    }

    fn realtime_unix() i64 {
        assert(is_darwin or is_linux);
        const ts: posix.timespec = posix.clock_gettime(posix.CLOCK.REALTIME) catch unreachable;
        return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
    }

    fn tick(_: *anyopaque) void {}
};

// --- TimeSim: copied from TigerBeetle's testing/time.zig ---

pub const OffsetType = enum {
    linear,
    periodic,
    step,
    non_ideal,
};

pub const TimeSim = struct {
    /// The duration of a single tick in nanoseconds.
    resolution: u64,

    offset_type: OffsetType,

    /// Co-efficients to scale the offset according to the `offset_type`.
    /// Linear offset is described as A * x + B: A is the drift per tick and B the initial offset.
    /// Periodic is described as A * sin(x * pi / B): A controls the amplitude and B the period in
    /// terms of ticks.
    /// Step function represents a discontinuous jump in the wall-clock time. B is the period in
    /// which the jumps occur. A is the amplitude of the step.
    /// Non-ideal is similar to periodic except the phase is adjusted using a random number taken
    /// from a normal distribution with mean=0, stddev=10. Finally, a random offset (up to
    /// offset_coefficient_C) is added to the result.
    offset_coefficient_A: i64,
    offset_coefficient_B: i64,
    offset_coefficient_C: u32 = 0,

    prng: stdx.PRNG = stdx.PRNG.from_seed(0),

    /// The number of ticks elapsed since initialization.
    ticks: u64 = 0,

    /// The instant in time chosen as the origin of this time source.
    epoch: i64 = 0,

    pub fn time(self: *TimeSim) Time {
        return .{
            .context = self,
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

        return self.epoch + @as(i64, @intCast(monotonic(context))) - self.offset(self.ticks);
    }

    pub fn offset(self: *TimeSim, ticks: u64) i64 {
        switch (self.offset_type) {
            .linear => {
                const drift_per_tick = self.offset_coefficient_A;
                return @as(i64, @intCast(ticks)) * drift_per_tick + @as(
                    i64,
                    @intCast(self.offset_coefficient_B),
                );
            },
            .periodic => {
                const unscaled = std.math.sin(@as(f64, @floatFromInt(ticks)) * 2 * std.math.pi /
                    @as(f64, @floatFromInt(self.offset_coefficient_B)));
                const scaled = @as(f64, @floatFromInt(self.offset_coefficient_A)) * unscaled;
                return @as(i64, @intFromFloat(std.math.floor(scaled)));
            },
            .step => {
                return if (ticks > self.offset_coefficient_B) self.offset_coefficient_A else 0;
            },
            .non_ideal => {
                const phase: f64 = @as(f64, @floatFromInt(ticks)) * 2 * std.math.pi /
                    (@as(f64, @floatFromInt(self.offset_coefficient_B)) +
                        std.Random.init(&self.prng, stdx.PRNG.fill).floatNorm(f64) * 10);
                const unscaled = std.math.sin(phase);
                const scaled = @as(f64, @floatFromInt(self.offset_coefficient_A)) * unscaled;
                const offset_random: i64 = -@as(i64, @intCast(self.offset_coefficient_C)) +
                    @as(i64, @intCast(self.prng.int_inclusive(u64, 2 * self.offset_coefficient_C)));
                return @as(i64, @intFromFloat(std.math.floor(scaled))) + offset_random;
            },
        }
    }

    fn tick_fn(context: *anyopaque) void {
        const self: *TimeSim = @ptrCast(@alignCast(context));

        self.ticks += 1;
    }

    /// Advance epoch by N seconds (convenience for tests that set wall-clock time).
    /// [ADDITION] Not in TB — our server uses wall-clock timestamps for responses.
    pub fn advance(self: *TimeSim, seconds: i64) void {
        self.epoch += seconds * std.time.ns_per_s;
    }
};

/// Equivalent to `std.time.Timer`,
/// but using the `Time` interface as the source of time.
pub const Timer = struct {
    time: Time,
    started: Instant,

    pub fn init(time: Time) Timer {
        return .{
            .time = time,
            .started = time.monotonic(),
        };
    }

    /// Reads the timer value since start or the last reset.
    pub fn read(self: *Timer) stdx.Duration {
        const current = self.time.monotonic();
        assert(current.ns >= self.started.ns);
        return current.duration_since(self.started);
    }

    /// Resets the timer.
    pub fn reset(self: *Timer) void {
        const current = self.time.monotonic();
        assert(current.ns >= self.started.ns);
        self.started = current;
    }
};

// --- Test fixtures: matches TB's testing/fixtures.zig init_time ---

pub fn init_time(options: struct {
    resolution: u64 = constants.tick_ms * std.time.ns_per_ms,
    offset_type: OffsetType = .linear,
    offset_coefficient_A: i64 = 0,
    offset_coefficient_B: i64 = 0,
    offset_coefficient_C: u32 = 0,
    /// [ADDITION] Our state_machine asserts realtime > 0, so sim tests need a
    /// plausible epoch. TB defaults to 0 (no wall-clock assertions).
    epoch: i64 = 1_700_000_000 * std.time.ns_per_s,
}) TimeSim {
    const result: TimeSim = .{
        .resolution = options.resolution,
        .offset_type = options.offset_type,
        .offset_coefficient_A = options.offset_coefficient_A,
        .offset_coefficient_B = options.offset_coefficient_B,
        .offset_coefficient_C = options.offset_coefficient_C,
        .epoch = options.epoch,
    };
    // Boundary assertion: periodic and non_ideal divide by coefficient_B.
    if (result.offset_type == .periodic or result.offset_type == .non_ideal) {
        assert(result.offset_coefficient_B != 0);
    }
    return result;
}

const testing = std.testing;

test "Time monotonic smoke" {
    var time_os: TimeOS = .{};
    const time = time_os.time();
    const instant_1 = time.monotonic();
    const instant_2 = time.monotonic();
    assert(instant_1.duration_since(instant_1).ns == 0);
    assert(instant_2.duration_since(instant_1).ns >= 0);
}

test Timer {
    var time_sim = init_time(.{ .resolution = 1 });
    const time = time_sim.time();

    var timer = Timer.init(time);
    // Repeat the cycle read/reset multiple times:
    for (0..3) |_| {
        const time_0 = timer.read();
        try testing.expectEqual(@as(u64, 0), time_0.ns);
        time.tick();

        const time_1 = timer.read();
        try testing.expectEqual(@as(u64, 1), time_1.ns);
        time.tick();

        const time_2 = timer.read();
        try testing.expectEqual(@as(u64, 2), time_2.ns);
        time.tick();

        timer.reset();
    }
}

// --- Additional tests for TimeSim offset types (not in TB) ---

test "TimeSim realtime with linear offset" {
    var time_sim = init_time(.{
        .resolution = 10 * std.time.ns_per_ms,
        .offset_type = .linear,
        .offset_coefficient_A = 100,
        .offset_coefficient_B = 0,
    });
    time_sim.epoch = 1_700_000_000 * std.time.ns_per_s;
    const time = time_sim.time();

    try testing.expectEqual(@as(i64, time_sim.epoch), time.realtime());
    time.tick();
    const expected = time_sim.epoch + @as(i64, 10 * std.time.ns_per_ms) - 100;
    try testing.expectEqual(expected, time.realtime());
}

test "TimeSim realtime with step offset" {
    var time_sim = init_time(.{
        .resolution = 1,
        .offset_type = .step,
        .offset_coefficient_A = 1_000_000,
        .offset_coefficient_B = 5,
    });
    const time = time_sim.time();

    for (0..5) |_| time.tick();
    const before = time.realtime();
    time.tick();
    const after = time.realtime();

    const monotonic_delta: i64 = 1;
    try testing.expectEqual(monotonic_delta - 1_000_000, after - before);
}

test "TimeSim periodic offset" {
    var time_sim = init_time(.{
        .resolution = 1,
        .offset_type = .periodic,
        .offset_coefficient_A = 1000, // amplitude
        .offset_coefficient_B = 100, // period in ticks
    });
    const time = time_sim.time();
    // At tick 0: sin(0) = 0, offset = 0.
    try testing.expectEqual(@as(i64, 0), time_sim.offset(0));
    // At quarter period: sin(pi/2) = 1, offset = amplitude.
    try testing.expectEqual(@as(i64, 1000), time_sim.offset(25));
    // Verify realtime includes the offset.
    for (0..25) |_| time.tick();
    const rt = time.realtime();
    const mono: i64 = @intCast(time.monotonic().ns);
    try testing.expectEqual(time_sim.epoch + mono - 1000, rt);
}

// NOTE: init_time with periodic/non_ideal and B=0 asserts at init.
// This is not testable as a "should panic" test — the assertion IS
// the protection. Same pattern as TB: crash, don't corrupt.

test "TimeSim advance" {
    var time_sim = init_time(.{ .resolution = 10 * std.time.ns_per_ms });
    time_sim.epoch = 1_700_000_000 * std.time.ns_per_s;
    const time = time_sim.time();
    time_sim.advance(3600);
    try testing.expectEqual(@as(i64, 1_700_000_000 * std.time.ns_per_s + 3600 * std.time.ns_per_s), time.realtime());
}
