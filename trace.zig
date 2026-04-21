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
const Time = @import("framework/time.zig").Time;
pub const Event = @import("trace_event.zig").Event;
pub const EventMetric = @import("trace_event.zig").EventMetric;
pub const EventTracing = @import("trace_event.zig").EventTracing;
pub const EventTiming = @import("trace_event.zig").EventTiming;
pub const EventTimingAggregate = @import("trace_event.zig").EventTimingAggregate;
pub const EventMetricAggregate = @import("trace_event.zig").EventMetricAggregate;

const trace_span_size_max = 1 * KiB;

pub const Tracer = @This();

time: Time,
options: Options,
buffer: []u8,

events_started: [EventTracing.stack_count]?stdx.Instant = @splat(null),
events_metric: [EventMetric.slot_count]?EventMetricAggregate =
    @as([EventMetric.slot_count]?EventMetricAggregate, @splat(null)),
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

/// Gauges work on a last-set wins. Multiple calls to .gauge() followed by an emit will
/// result in only the last value being submitted.
// Takes an i65 to keep calling code simple: lots of places want to call this with a u64, and
// requiring an @intCast and checks at every call site is cumbersome.
pub fn gauge(tracer: *Tracer, event: EventMetric, value: i65) void {
    const timing_slot = event.slot();
    tracer.events_metric[timing_slot] = .{
        .event = event,
        .value = value,
    };
}

/// Counters are cumulative values that only increase.
pub fn count(tracer: *Tracer, event: EventMetric, value: u64) void {
    const timing_slot = event.slot();
    if (tracer.events_metric[timing_slot]) |*metric| {
        metric.value +|= value;
    } else {
        tracer.events_metric[timing_slot] = .{
            .event = event,
            .value = value,
        };
    }
}

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

/// Emit timing and metric values via log and reset. Called periodically.
/// Self-traces the emission call (TB pattern).
pub fn emit_metrics(tracer: *Tracer) void {
    tracer.start(.metrics_emit);
    defer tracer.stop(.metrics_emit);

    for (&tracer.events_metric) |*metric_opt| {
        const m = metric_opt.* orelse continue;
        switch (m.event) {
            inline else => |data| {
                if (@TypeOf(data) == void) {
                    log.info("metric: {s} value={d}", .{ @tagName(m.event), m.value });
                } else {
                    // Use format_data to emit domain enum names (TB pattern).
                    // Output: "metric: requests_by_operation operation=create_product value=5"
                    var name_buf: [128]u8 = undefined;
                    var name_stream = std.io.fixedBufferStream(&name_buf);
                    @import("trace_event.zig").format_data(data, name_stream.writer()) catch {};
                    log.info("metric: {s} {s} value={d}", .{
                        @tagName(m.event),
                        name_stream.getWritten(),
                        m.value,
                    });
                }
            },
        }
    }

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

    @memset(&tracer.events_metric, null);
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

const time_mod = @import("framework/time.zig");
const TimeSim = time_mod.TimeSim;
const init_time = time_mod.init_time;

test "start/stop produces valid timing" {
    var sim = init_time(.{ .resolution = 1000 });
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
    var sim = init_time(.{ .resolution = 1000 });
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
    var sim = init_time(.{ .resolution = 1000 });
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

    var sim = init_time(.{ .resolution = 1000 });
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

    var sim = init_time(.{ .resolution = 1000 });
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
    var sim = init_time(.{ .resolution = 1000 });
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
    var sim = init_time(.{ .resolution = 1000 });
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

test "gauge sets last value, count accumulates" {
    var sim = init_time(.{ .resolution = 1000 });
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    // Gauge: last-set wins.
    tracer.gauge(.connections_active, 5);
    tracer.gauge(.connections_active, 10);
    const gauge_slot = (EventMetric{ .connections_active = {} }).slot();
    try std.testing.expectEqual(@as(EventMetricAggregate.ValueType, 10), tracer.events_metric[gauge_slot].?.value);

    // Count: cumulative. Per-operation counter uses domain type directly.
    tracer.count(.{ .requests_by_operation = .{ .operation = .create_product } }, 3);
    tracer.count(.{ .requests_by_operation = .{ .operation = .create_product } }, 7);
    const count_slot = (EventMetric{ .requests_by_operation = .{ .operation = .create_product } }).slot();
    try std.testing.expectEqual(@as(EventMetricAggregate.ValueType, 10), tracer.events_metric[count_slot].?.value);

    // Different operation → different slot.
    tracer.count(.{ .requests_by_operation = .{ .operation = .list_products } }, 1);
    const other_slot = (EventMetric{ .requests_by_operation = .{ .operation = .list_products } }).slot();
    try std.testing.expect(count_slot != other_slot);
    try std.testing.expectEqual(@as(EventMetricAggregate.ValueType, 1), tracer.events_metric[other_slot].?.value);
}

test "emit_metrics resets gauges and counters" {
    var sim = init_time(.{ .resolution = 1000 });
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.gauge(.connections_active, 5);
    tracer.count(.{ .requests_by_operation = .{ .operation = .create_product } }, 1);
    tracer.emit_metrics();

    const gauge_slot = (EventMetric{ .connections_active = {} }).slot();
    const count_slot = (EventMetric{ .requests_by_operation = .{ .operation = .create_product } }).slot();
    try std.testing.expect(tracer.events_metric[gauge_slot] == null);
    try std.testing.expect(tracer.events_metric[count_slot] == null);
}
