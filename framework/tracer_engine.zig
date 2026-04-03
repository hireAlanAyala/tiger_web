//! Trace engine — Chrome Tracing JSON output + timing aggregation.
//!
//! Ported from TigerBeetle's src/trace.zig. Outputs JSON compatible with:
//! - https://ui.perfetto.dev/
//! - https://gravitymoth.com/spall/spall.html
//! - chrome://tracing/
//!
//! Usage:
//!     $ ./tiger-web --trace=trace.json
//!
//! Three modes, always-on timing:
//!   1. Timing aggregation (always) — min/max/sum/count per event
//!   2. Debug logging (--log-trace) — log.debug per start/stop
//!   3. Chrome Tracing JSON (--trace=file) — Perfetto timeline
//!
//! cancel_slot(slot_idx) cancels all open spans for a pipeline slot.
//! Departure from TB (which cancels by event type). Required because
//! concurrent slots are independent — cancelling by type would kill
//! other slots' spans.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const Duration = stdx.Duration;
const Instant = stdx.Instant;
const Time = @import("time.zig").Time;
const event_mod = @import("trace_event.zig");
const Event = event_mod.Event;
const EventTracing = event_mod.EventTracing;
const EventTiming = event_mod.EventTiming;
const EventTimingAggregate = event_mod.EventTimingAggregate;

const log = std.log.scoped(.trace);

const trace_span_size_max = 1024;

pub const Tracer = @This();

time: Time,
options: Options,
buffer: []u8,

events_started: [EventTracing.stack_count]?Instant = @splat(null),
events_timing: [EventTiming.slot_count]?EventTimingAggregate =
    @as([EventTiming.slot_count]?EventTimingAggregate, @splat(null)),

time_start: Instant,
log_trace: bool,

pub const Options = struct {
    /// JSON writer — null disables JSON output but timing is still captured.
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

// =========================================================================
// Start / Stop / Cancel
// =========================================================================

pub fn start(tracer: *Tracer, event: Event) void {
    const event_tracing = event.as(EventTracing);
    const event_timing = event.as(EventTiming);
    const stack = event_tracing.stack();

    const time_now = tracer.time.monotonic();

    assert(tracer.events_started[stack] == null);
    tracer.events_started[stack] = time_now;

    if (event_tracing.aggregate_only()) return;

    if (tracer.log_trace) {
        log.debug("{s}({}): start: {}", .{
            @tagName(event),
            event_tracing,
            event_timing,
        });
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
        "\"name\":\"{[category]s} {[event_tracing]}\"," ++
        "\"args\":{[args]s}" ++
        "}},\n", .{
        .thread_id = stack,
        .category = @tagName(event),
        .event = 'B',
        .timestamp = time_elapsed.to_us(),
        .event_tracing = event_tracing,
        .args = std.json.Formatter(Event){ .value = event, .options = .{} },
    }) catch {
        log.err("{s}({}): event too large", .{ @tagName(event), event_tracing });
        return;
    };

    writer.writeAll(buffer_stream.getWritten()) catch |err| {
        std.debug.panic("Tracer.start: {}\n", .{err});
    };
}

pub fn stop(tracer: *Tracer, event: Event) void {
    const event_tracing = event.as(EventTracing);
    const event_timing = event.as(EventTiming);
    const stack = event_tracing.stack();

    const event_start = tracer.events_started[stack].?;
    const event_end = tracer.time.monotonic();
    const event_duration = event_end.duration_since(event_start);

    assert(tracer.events_started[stack] != null);
    tracer.events_started[stack] = null;

    // Timing is ALWAYS recorded, even for aggregate_only events.
    tracer.timing(event_timing, event_duration);

    if (event_tracing.aggregate_only()) return;

    if (tracer.log_trace) {
        const us_log_threshold_ns = 5 * std.time.ns_per_ms;
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

/// Cancel all running instances of an event type.
/// Writes JSON stop events but does NOT record timing.
pub fn cancel(tracer: *Tracer, event_tag: Event.Tag) void {
    const stack_base = EventTracing.stack_bases.get(event_tag);
    const cardinality = EventTracing.stack_limits.get(event_tag);
    const event_end = tracer.time.monotonic();
    for (stack_base..stack_base + cardinality) |stack| {
        if (tracer.events_started[stack]) |_| {
            if (tracer.log_trace) {
                log.debug("{s}: cancel", .{@tagName(event_tag)});
            }
            tracer.events_started[stack] = null;
            tracer.write_stop(@intCast(stack), event_end.duration_since(tracer.time_start));
        }
    }
}

/// Cancel all open spans for a specific pipeline slot.
/// Iterates all event types and cancels the target slot's stack.
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

// =========================================================================
// Timing aggregation
// =========================================================================

fn timing(tracer: *Tracer, event_timing: EventTiming, duration: Duration) void {
    const timing_slot = event_timing.slot();

    if (tracer.events_timing[timing_slot]) |*existing| {
        assert(std.meta.eql(existing.event, event_timing));
        existing.values = .{
            .duration_min = existing.values.duration_min.min(duration),
            .duration_max = existing.values.duration_max.max(duration),
            .duration_sum = .{ .ns = existing.values.duration_sum.ns +| duration.ns },
            .count = existing.values.count +| 1,
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

/// Emit timing metrics and reset. Called periodically (metrics interval).
pub fn emit_timing(tracer: *Tracer) bool {
    var emitted = false;
    for (&tracer.events_timing) |*timing_opt| {
        const t = timing_opt.* orelse continue;
        const tag_name = @tagName(t.event);
        log.info("timing: {s} count={d} min={d}us max={d}us avg={d}us", .{
            tag_name,
            t.values.count,
            t.values.duration_min.to_us(),
            t.values.duration_max.to_us(),
            if (t.values.count > 0) t.values.duration_sum.to_us() / t.values.count else 0,
        });
        timing_opt.* = null;
        emitted = true;
    }
    return emitted;
}

// =========================================================================
// JSON output helpers
// =========================================================================

fn write_stop(tracer: *Tracer, stack: u32, time_elapsed: Duration) void {
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

// =========================================================================
// Tests
// =========================================================================

const TimeSim = @import("time.zig").TimeSim;

test "start/stop produces valid timing" {
    var sim = TimeSim{ .resolution = 1000 }; // 1µs per tick
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });
    time.tick(); // 1µs
    time.tick(); // 2µs
    tracer.stop(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });

    // Timing should be recorded.
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

    // Timing should NOT be recorded for cancelled spans.
    const slot = (EventTiming{ .sidecar_call = .{ .function = .route } }).slot();
    try std.testing.expect(tracer.events_timing[slot] == null);
}

test "cancel_slot cancels only target slot" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    // Start spans on slot 0.
    tracer.start(.{ .pipeline_stage = .{ .stage = .prefetch, .slot = 0 } });

    // Cancel slot 0.
    tracer.cancel_slot(0);

    // Slot 0's span should be cleared.
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

    // Record the initial "[" size.
    const initial_len = trace_buf.items.len;

    tracer.start(.tick);
    time.tick();
    tracer.stop(.tick);

    // No JSON written for aggregate_only events.
    try std.testing.expectEqual(initial_len, trace_buf.items.len);

    // But timing IS captured.
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
    // Should contain begin and end events.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ph\":\"B\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"ph\":\"E\"") != null);
    // Should contain category.
    try std.testing.expect(std.mem.indexOf(u8, output, "\"cat\":\"pipeline_stage\"") != null);
    // Stop event should be minimal (no cat).
    // Find the E event and check it doesn't have "cat".
    const e_pos = std.mem.indexOf(u8, output, "\"ph\":\"E\"").?;
    const e_line_end = std.mem.indexOfPos(u8, output, e_pos, "\n").?;
    const e_line = output[e_pos..e_line_end];
    try std.testing.expect(std.mem.indexOf(u8, e_line, "\"cat\"") == null);
}

test "span duration > 0 in sim (time.tick integration)" {
    var sim = TimeSim{ .resolution = 1000 };
    const time = sim.time();

    var tracer = try Tracer.init(std.testing.allocator, time, .{});
    defer tracer.deinit(std.testing.allocator);

    tracer.start(.{ .storage_op = .{ .slot = 0 } });
    time.tick(); // Advance monotonic by 1µs
    tracer.stop(.{ .storage_op = .{ .slot = 0 } });

    const slot = (EventTiming{ .storage_op = {} }).slot();
    const t = tracer.events_timing[slot].?;
    try std.testing.expect(t.values.duration_min.ns > 0);
}
