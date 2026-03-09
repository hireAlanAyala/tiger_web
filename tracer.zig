//! Minimal tracer — timing aggregation and trace logging.
//!
//! Follows TigerBeetle's Tracer pattern: start()/stop() span tracking with
//! per-event min/max/sum/count aggregation. No JSON traces, no StatsD, no
//! overlapping spans — just the timing and logging core.
//!
//! Usage:
//!
//!     tracer.start(.prefetch);
//!     // ... do work ...
//!     tracer.stop(.prefetch, .get_product);
//!
//!     // Periodically:
//!     tracer.emit();
//!
const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.tracer));

/// Timed spans. Each span is a start/stop pair around a phase of request processing.
pub const Span = enum {
    prefetch,
    execute,
};

const span_count = std.meta.fields(Span).len;

/// Per-operation timing aggregate — min/max/sum/count.
/// Reset after each emission.
pub const OperationTiming = struct {
    duration_min_ns: u64,
    duration_max_ns: u64,
    duration_sum_ns: u64,
    count: u64,
};

/// Array size: one slot per possible Operation integer value.
const operation_slots = blk: {
    var max: u8 = 0;
    for (std.meta.fields(message.Operation)) |f| {
        if (f.value > max) max = f.value;
    }
    break :blk @as(usize, max) + 1;
};

/// Adaptive time unit threshold — below 5ms show microseconds, above show milliseconds.
/// Same threshold as TigerBeetle's us_log_threshold_ns.
const duration_threshold_ns = 5 * std.time.ns_per_ms;

const Instant = std.time.Instant;

timings: [span_count][operation_slots]?OperationTiming,
started: [span_count]?Instant,
/// Last completed duration per span — for trace logging the current request.
last_duration_ns: [span_count]u64,
log_trace: bool,

pub fn init(log_trace: bool) @This() {
    return .{
        .timings = [_][operation_slots]?OperationTiming{
            [_]?OperationTiming{null} ** operation_slots,
        } ** span_count,
        .started = [_]?Instant{null} ** span_count,
        .last_duration_ns = [_]u64{0} ** span_count,
        .log_trace = log_trace,
    };
}

/// Mark the beginning of a span. Asserts the span is not already started.
pub fn start(self: *@This(), span: Span) void {
    const slot = @intFromEnum(span);
    assert(self.started[slot] == null);
    self.started[slot] = Instant.now() catch unreachable;
}

/// Cancel a started span without recording. Used when prefetch returns
/// busy — the span never completed, so no timing is recorded.
pub fn cancel(self: *@This(), span: Span) void {
    const slot = @intFromEnum(span);
    assert(self.started[slot] != null);
    self.started[slot] = null;
}

/// Mark the end of a span. Records duration into the per-operation aggregate.
/// Asserts the span was started.
pub fn stop(self: *@This(), span: Span, op: message.Operation) void {
    const slot = @intFromEnum(span);
    const start_time = self.started[slot].?;
    self.started[slot] = null;

    const elapsed_ns = (Instant.now() catch unreachable).since(start_time);
    self.last_duration_ns[slot] = elapsed_ns;
    self.record(span, op, elapsed_ns);
}

/// Record a duration directly (for callers that manage their own timestamps).
fn record(self: *@This(), span: Span, op: message.Operation, duration_ns: u64) void {
    const op_slot = @intFromEnum(op);
    const span_slot = @intFromEnum(span);
    if (self.timings[span_slot][op_slot]) |*t| {
        t.duration_min_ns = @min(t.duration_min_ns, duration_ns);
        t.duration_max_ns = @max(t.duration_max_ns, duration_ns);
        t.duration_sum_ns +|= duration_ns;
        t.count +|= 1;
    } else {
        self.timings[span_slot][op_slot] = .{
            .duration_min_ns = duration_ns,
            .duration_max_ns = duration_ns,
            .duration_sum_ns = duration_ns,
            .count = 1,
        };
    }
}

/// Emit per-request trace log. Called after both spans complete.
/// Uses last_duration_ns from the most recent stop() calls.
pub fn trace_log(self: *@This(), op: message.Operation, status: message.Status, fd: i32) void {
    if (!self.log_trace) return;

    const prefetch_ns = self.last_duration_ns[@intFromEnum(Span.prefetch)];
    const execute_ns = self.last_duration_ns[@intFromEnum(Span.execute)];
    const total_ns = prefetch_ns +| execute_ns;

    log.debug("{s}: status={s} prefetch={d}{s} execute={d}{s} total={d}{s} fd={d}", .{
        @tagName(op),
        @tagName(status),
        format_duration(prefetch_ns),
        format_unit(prefetch_ns),
        format_duration(execute_ns),
        format_unit(execute_ns),
        format_duration(total_ns),
        format_unit(total_ns),
        fd,
    });
}

/// Emit aggregate timing metrics and reset. Returns true if any timings were emitted.
pub fn emit(self: *@This()) bool {
    var emitted = false;
    inline for (std.meta.fields(Span)) |span_field| {
        const span_slot = span_field.value;
        for (&self.timings[span_slot], 0..) |*timing_opt, op_slot| {
            const t = timing_opt.* orelse continue;
            const op: message.Operation = @enumFromInt(op_slot);
            log.info("metrics: span={s} op={s} count={d} min={d}us max={d}us avg={d}us", .{
                span_field.name,
                @tagName(op),
                t.count,
                t.duration_min_ns / std.time.ns_per_us,
                t.duration_max_ns / std.time.ns_per_us,
                t.duration_sum_ns / t.count / std.time.ns_per_us,
            });
            timing_opt.* = null;
            emitted = true;
        }
    }
    return emitted;
}

fn format_duration(ns: u64) u64 {
    return if (ns < duration_threshold_ns)
        ns / std.time.ns_per_us
    else
        ns / std.time.ns_per_ms;
}

fn format_unit(ns: u64) []const u8 {
    return if (ns < duration_threshold_ns) "us" else "ms";
}

// =====================================================================
// Tests
// =====================================================================

test "start/stop records timing" {
    var tracer = init(false);
    tracer.start(.prefetch);
    tracer.stop(.prefetch, .get_product);

    const slot = @intFromEnum(message.Operation.get_product);
    const t = tracer.timings[@intFromEnum(Span.prefetch)][slot].?;
    try std.testing.expect(t.count == 1);
    try std.testing.expect(t.duration_min_ns == t.duration_max_ns);
}

test "multiple stops accumulate" {
    var tracer = init(false);

    tracer.start(.execute);
    tracer.stop(.execute, .create_product);
    tracer.start(.execute);
    tracer.stop(.execute, .create_product);

    const slot = @intFromEnum(message.Operation.create_product);
    const t = tracer.timings[@intFromEnum(Span.execute)][slot].?;
    try std.testing.expect(t.count == 2);
    try std.testing.expect(t.duration_sum_ns >= t.duration_min_ns);
}

test "emit resets timings" {
    var tracer = init(false);
    tracer.start(.prefetch);
    tracer.stop(.prefetch, .get_product);
    try std.testing.expect(tracer.emit());

    const slot = @intFromEnum(message.Operation.get_product);
    try std.testing.expect(tracer.timings[@intFromEnum(Span.prefetch)][slot] == null);
}

test "emit with no data returns false" {
    var tracer = init(false);
    try std.testing.expect(!tracer.emit());
}

test "separate spans are independent" {
    var tracer = init(false);
    tracer.start(.prefetch);
    tracer.stop(.prefetch, .get_product);
    tracer.start(.execute);
    tracer.stop(.execute, .get_product);

    const op_slot = @intFromEnum(message.Operation.get_product);
    try std.testing.expect(tracer.timings[@intFromEnum(Span.prefetch)][op_slot] != null);
    try std.testing.expect(tracer.timings[@intFromEnum(Span.execute)][op_slot] != null);
    try std.testing.expectEqual(tracer.timings[@intFromEnum(Span.prefetch)][op_slot].?.count, 1);
    try std.testing.expectEqual(tracer.timings[@intFromEnum(Span.execute)][op_slot].?.count, 1);
}
