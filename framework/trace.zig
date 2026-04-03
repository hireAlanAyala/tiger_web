//! Log IO/CPU event spans for analysis/visualization.
//!
//! Example:
//!
//!     $ ./tigerbeetle start --experimental --trace=trace.json
//!
//! or:
//!
//!     $ ./tigerbeetle benchmark --trace=trace.json
//!
//! The trace JSON output is compatible with:
//! - https://ui.perfetto.dev/
//! - https://gravitymoth.com/spall/spall.html
//! - chrome://tracing/
//!
//! Example integrations:
//!
//!     // Trace a synchronous event.
//!     // The second argument is a `anytype` struct, corresponding to the struct argument to
//!     // `log.debug()`.
//!     tree.grid.trace.start(.{ .compact_mutable = .{ .tree = tree.config.name } });
//!     defer tree.grid.trace.stop(.{ .compact_mutable = .{ .tree = tree.config.name } });
//!
//! Note that only one of each Event can be running at a time:
//!
//!     // good
//!     trace.start(.{.foo = .{}});
//!     trace.stop(.{ .foo = .{} });
//!     trace.start(.{ .bar = .{} });
//!     trace.stop(.{ .bar = .{} });
//!
//!     // good
//!     trace.start(.{ .foo = .{} });
//!     trace.start(.{ .bar = .{} });
//!     trace.stop(.{ .foo = .{} });
//!     trace.stop(.{ .bar = .{} });
//!
//!     // bad
//!     trace.start(.{ .foo = .{} });
//!     trace.start(.{ .foo = .{} });
//!
//!     // bad
//!     trace.stop(.{ .foo = .{} });
//!     trace.start(.{ .foo = .{} });
//!
//! If an event is is cancelled rather than properly stopped, use .reset():
//! - Reset is safe to call regardless of whether the event is currently started.
//! - For events with multiple instances (e.g. IO reads and writes), .reset() will
//!   cancel all running traces of the same event.
//!
//!     // good
//!     trace.start(.{ .foo = .{} });
//!     trace.cancel(.foo);
//!     trace.start(.{ .foo = .{} });
//!     trace.stop(.{ .foo = .{} });
//!
//! Notes:
//! - When enabled, traces are written to stdout (as opposed to logs, which are written to stderr).
//! - The JSON output is a "[" followed by a comma-separated list of JSON objects. The JSON array is
//!   never closed with a "]", but Chrome, Spall, and Perfetto all handle this.
//! - Event pairing (start/stop) is asserted at runtime.
//! - `trace.start()/.stop()/.reset()` will `log.debug()` regardless of whether tracing is enabled.
//!
//! The JSON output looks like:
//!
//!     {
//!         // Process id:
//!         // The replica index is encoded as the "process id" of trace events, so events from
//!         // multiple replicas of a cluster can be unified to visualize them on the same timeline.
//!         "pid": 0,
//!
//!         // Thread id:
//!         "tid": 0,
//!
//!         // Category.
//!         "cat": "replica_commit",
//!
//!         // Phase.
//!         "ph": "B",
//!
//!         // Timestamp:
//!         // Microseconds since program start.
//!         "ts": 934327,
//!
//!         // Event name:
//!         // Includes the event name and a *low cardinality subset* of the second argument to
//!         // `trace.start()`. (Low-cardinality part so that tools like Perfetto can distinguish
//!         // events usefully.)
//!         "name": "replica_commit stage='next_pipeline'",
//!
//!         // Extra event arguments. (Encoded from the second argument to `trace.start()`).
//!         "args": {
//!             "stage": "next_pipeline",
//!             "op": 1
//!         },
//!     },
//!
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.trace);

const stdx = @import("stdx");
const KiB = stdx.KiB;
const Duration = stdx.Duration;
const Time = @import("time.zig").Time;
pub const Event = @import("trace_event.zig").Event;
pub const EventTracing = @import("trace_event.zig").EventTracing;
pub const EventTiming = @import("trace_event.zig").EventTiming;
pub const EventTimingAggregate = @import("trace_event.zig").EventTimingAggregate;

const trace_span_size_max = 1 * KiB;

pub const Tracer = @This();

time: Time,
options: Options,
buffer: []u8,

events_started: [EventTracing.stack_count]?stdx.Instant = @splat(null),
events_timing: [EventTiming.slot_count]?EventTimingAggregate =
    @as([EventTiming.slot_count]?EventTimingAggregate, @splat(null)),

time_start: stdx.Instant,

log_trace: bool,

pub const Options = struct {
    /// The tracer still validates start/stop state even when writer=null.
    writer: ?std.io.AnyWriter = null,
    log_trace: bool = false,
};

pub fn init(
    allocator: std.mem.Allocator,
    time: Time,
    options: Options,
) !Tracer {
    if (options.writer) |writer| {
        try writer.writeAll("[\n");
    }

    const buffer = try allocator.alloc(u8, trace_span_size_max);
    errdefer allocator.free(buffer);

    return .{
        .time = time,
        .options = options,
        .buffer = buffer,
        .time_start = time.monotonic(),
        .log_trace = options.log_trace,
    };
}

pub fn deinit(tracer: *Tracer, allocator: std.mem.Allocator) void {
    allocator.free(tracer.buffer);
    tracer.* = undefined;
}

// TODO: gauge() and count() via EventMetric — add when wiring metrics.

pub fn start(tracer: *Tracer, event: Event) void {
    const event_tracing = event.as(EventTracing);
    const event_timing = event.as(EventTiming);
    const stack = event_tracing.stack();

    const time_now = tracer.time.monotonic();

    assert(tracer.events_started[stack] == null);
    tracer.events_started[stack] = time_now;

    if (event_tracing.aggregate_only()) {
        return;
    }

    if (tracer.log_trace) {
        log.debug("{s}({}): start: {}", .{ @tagName(event), event_tracing, event_timing });
    }

    const writer = tracer.options.writer orelse return;
    const time_elapsed = time_now.duration_since(tracer.time_start);

    var buffer_stream = std.io.fixedBufferStream(tracer.buffer);

    buffer_stream.writer().print("{{" ++
        "\"pid\":0," ++
        "\"tid\":{[thread_id]}," ++
        "\"ph\":\"{[event]c}\"," ++
        "\"ts\":{[timestamp]}," ++
        "\"cat\":\"{[category]s}\"," ++
        "\"name\":\"{[category]s} {[event_tracing]} {[event_timing]}\"," ++
        "\"args\":{[args]s}" ++
        "}},\n", .{
        .thread_id = event_tracing.stack(),
        .category = @tagName(event),
        .event = 'B',
        .timestamp = time_elapsed.to_us(),
        .event_tracing = event_tracing,
        .event_timing = event_timing,
        .args = std.json.Formatter(Event){ .value = event, .options = .{} },
    }) catch {
        log.err("{s}({}): event too large: {}", .{
            @tagName(event),
            event_tracing,
            event_timing,
        });
        return;
    };

    writer.writeAll(buffer_stream.getWritten()) catch |err| {
        std.debug.panic("Tracer.start: {}\n", .{err});
    };
}

pub fn stop(tracer: *Tracer, event: Event) void {
    const us_log_threshold_ns = 5 * std.time.ns_per_ms;

    const event_tracing = event.as(EventTracing);
    const event_timing = event.as(EventTiming);
    const stack = event_tracing.stack();

    const event_start = tracer.events_started[stack].?;
    const event_end = tracer.time.monotonic();
    const event_duration = event_end.duration_since(event_start);

    assert(tracer.events_started[stack] != null);
    tracer.events_started[stack] = null;

    tracer.timing(event_timing, event_duration);

    if (event_tracing.aggregate_only()) {
        return;
    }

    if (tracer.log_trace) {
        log.debug("{s}({}): stop:  {} (duration={}{s})", .{
            @tagName(event),
            event_tracing,
            event_timing,
            if (event_duration.ns < us_log_threshold_ns)
                event_duration.to_us()
            else
                event_duration.to_ms(),
            if (event_duration.ns < us_log_threshold_ns) "us" else "ms",
        });
    }

    tracer.write_stop(stack, event_end.duration_since(tracer.time_start));
}

pub fn cancel(tracer: *Tracer, event_tag: Event.Tag) void {
    const stack_base = EventTracing.stack_bases.get(event_tag);
    const cardinality = EventTracing.stack_limits.get(event_tag);
    const event_end = tracer.time.monotonic();
    for (stack_base..stack_base + cardinality) |stack| {
        if (tracer.events_started[stack]) |_| {
            if (tracer.log_trace) {
                log.debug("{s}: cancel", .{@tagName(event_tag)});
            }

            const event_duration = event_end.duration_since(tracer.time_start);

            tracer.events_started[stack] = null;
            tracer.write_stop(@intCast(stack), event_duration);
        }
    }
}

/// Cancel all open spans for a specific pipeline slot.
/// Iterates all event types, cancels only the target slot's stack.
/// Required for concurrent dispatch — per-type cancel would kill
/// other slots' spans.
pub fn cancel_slot(tracer: *Tracer, slot_idx: u8) void {
    const event_end = tracer.time.monotonic();
    inline for (std.meta.fields(Event.Tag)) |field| {
        const event_tag: Event.Tag = @enumFromInt(field.value);
        const stack_base = EventTracing.stack_bases.get(event_tag);
        const cardinality = EventTracing.stack_limits.get(event_tag);
        if (slot_idx < cardinality) {
            const stack = stack_base + @as(u32, slot_idx);
            if (tracer.events_started[stack]) |_| {
                if (tracer.log_trace) {
                    log.debug("{s}[{d}]: cancel_slot", .{ field.name, slot_idx });
                }
                tracer.events_started[stack] = null;
                tracer.write_stop(@intCast(stack), event_end.duration_since(tracer.time_start));
            }
        }
    }
}

fn write_stop(tracer: *Tracer, stack: u32, time_elapsed: stdx.Duration) void {
    const writer = tracer.options.writer orelse return;
    var buffer_stream = std.io.fixedBufferStream(tracer.buffer);

    buffer_stream.writer().print(
        "{{" ++
            "\"pid\":0," ++
            "\"tid\":{[thread_id]}," ++
            "\"ph\":\"{[event]c}\"," ++
            "\"ts\":{[timestamp]}" ++
            "}},\n",
        .{
            .thread_id = stack,
            .event = 'E',
            .timestamp = time_elapsed.to_us(),
        },
    ) catch unreachable;

    writer.writeAll(buffer_stream.getWritten()) catch |err| {
        std.debug.panic("Tracer.stop: {}\n", .{err});
    };
}

/// Emit timing metrics via log and reset. Called periodically.
/// Self-traces the emission call (TB pattern).
pub fn emit_metrics(tracer: *Tracer) void {
    tracer.start(.metrics_emit);
    defer tracer.stop(.metrics_emit);

    for (&tracer.events_timing) |*timing_opt| {
        const t = timing_opt.* orelse continue;
        log.info("timing: {s} count={d} min={d}us max={d}us avg={d}us", .{
            @tagName(t.event),
            t.values.count,
            t.values.duration_min.to_us(),
            t.values.duration_max.to_us(),
            if (t.values.count > 0) t.values.duration_sum.to_us() / t.values.count else 0,
        });
    }

    @memset(&tracer.events_timing, null);
}

// Timing works by storing the min, max, sum and count of each value provided. The avg is calculated
// from sum and count at emit time.
//
// When these are emitted upstream (via statsd, currently), upstream must apply different
// aggregations:
// * min/max/avg are considered gauges for aggregation: last value wins.
// * sum/count are considered counters for aggregation: they are added to the existing values.
//
// This matches the default behavior of the `g` and `c` statsd types respectively.
pub fn timing(tracer: *Tracer, event_timing: EventTiming, duration: Duration) void {
    const timing_slot = event_timing.slot();

    if (tracer.events_timing[timing_slot]) |*event_timing_existing| {
        assert(std.meta.eql(event_timing_existing.event, event_timing));

        const timing_existing = event_timing_existing.values;
        event_timing_existing.values = .{
            .duration_min = timing_existing.duration_min.min(duration),
            .duration_max = timing_existing.duration_max.max(duration),
            .duration_sum = .{ .ns = timing_existing.duration_sum.ns +| duration.ns },
            .count = timing_existing.count +| 1,
        };
    } else {
        tracer.events_timing[timing_slot] = .{
            .event = event_timing,
            .values = .{
                .duration_min = duration,
                .duration_max = duration,
                .duration_sum = duration,
                .count = 1,
            },
        };
    }
}

const TimeSim = @import("time.zig").TimeSim;

test "start/stop produces valid timing" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });
    time.tick();
    time.tick();
    tracer.stop(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });

    const slot = (EventTiming{ .pipeline_stage = .{ .stage = .prefetch } }).slot();
    const t = tracer.events_timing[slot].?;
    try std.testing.expectEqual(@as(u64, 1), t.values.count);
    try std.testing.expectEqual(@as(u64, 2), t.values.duration_min.to_us());
}

test "cancel does not record timing" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .sidecar_call = .{ .function = .route, .slot = 0 } });
    time.tick();
    tracer.cancel(.sidecar_call);

    const slot = (EventTiming{ .sidecar_call = .{ .function = .route } }).slot();
    try std.testing.expect(tracer.events_timing[slot] == null);
}

test "cancel_slot cancels only target slot" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });
    tracer.cancel_slot(0);

    const stack = (EventTracing{ .pipeline_stage = .{ .slot = 0 } }).stack();
    try std.testing.expect(tracer.events_started[stack] == null);
}

test "aggregate_only: tick timing captured but no JSON" {
    var trace_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer trace_buf.deinit();

    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{
        .writer = trace_buf.writer().any(),
    });
    defer tracer.deinit(std.testing.allocator);

    const initial_len = trace_buf.items.len;

    tracer.start(.tick);
    time.tick();
    tracer.stop(.tick);

    try std.testing.expectEqual(initial_len, trace_buf.items.len);

    const slot = (EventTiming{ .tick = {} }).slot();
    const t = tracer.events_timing[slot].?;
    try std.testing.expectEqual(@as(u64, 1), t.values.count);
}

test "Chrome Tracing JSON format" {
    var trace_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer trace_buf.deinit();

    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{
        .writer = trace_buf.writer().any(),
    });
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0, .op = 5 } });
    time.tick();
    tracer.stop(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0, .op = 5 } });

    const output = trace_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ph\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ph\":\"E\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cat\":\"pipeline_stage\"") != null);
}

test "span duration > 0 in sim (time.tick integration)" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .storage_op = .{ .slot = 0 } });
    time.tick();
    tracer.stop(.{ .storage_op = .{ .slot = 0 } });

    const slot = (EventTiming{ .storage_op = {} }).slot();
    const t = tracer.events_timing[slot].?;
    try std.testing.expect(t.values.duration_min.ns > 0);
}

test "timing overflow saturates" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    const event_timing: EventTiming = .{ .pipeline_stage = .{ .stage = .handle } };
    const value: Duration = .{ .ns = std.math.maxInt(u64) - 1 };
    tracer.timing(event_timing, value);
    tracer.timing(event_timing, value);

    const aggregate = tracer.events_timing[event_timing.slot()].?;

    try std.testing.expectEqual(@as(u64, 2), aggregate.values.count);
    try std.testing.expectEqual(value.ns, aggregate.values.duration_min.ns);
    try std.testing.expectEqual(value.ns, aggregate.values.duration_max.ns);
    try std.testing.expectEqual(std.math.maxInt(u64), aggregate.values.duration_sum.ns);
}
