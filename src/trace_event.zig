const std = @import("std");
const assert = std.debug.assert;
const constants = @import("framework/constants.zig");
const message = @import("message.zig");

/// Domain types — imported directly, same as TB's trace/event.zig
/// imports from tigerbeetle.zig, vsr.zig, and state_machine.zig.
/// The event definitions describe the system, which includes domain types.
pub const Operation = message.Operation;
pub const Status = message.Status;

/// Maps an exhaustive enum value from an enum type that might potentially start with a non-zero
/// value or be sparse to a continuous index that fits within enum_count().
fn index_from_enum(enum_tag: anytype) u8 {
    const type_info = @typeInfo(@TypeOf(enum_tag));
    assert(type_info == .@"enum" or type_info == .@"union");

    const Enum = if (type_info == .@"enum")
        type_info.@"enum"
    else
        @typeInfo(type_info.@"union".tag_type.?).@"enum";
    assert(Enum.is_exhaustive);

    inline for (Enum.fields, 0..) |enum_field, i| {
        if (enum_field.value == @intFromEnum(enum_tag)) {
            return i;
        }
    } else unreachable;
}

/// Returns the count of an exhaustive enum.
fn enum_count(EnumOrUnion: type) u8 {
    const type_info = @typeInfo(EnumOrUnion);
    assert(type_info == .@"enum" or type_info == .@"union");

    const Enum = if (type_info == .@"enum")
        type_info.@"enum"
    else
        @typeInfo(type_info.@"union".tag_type.?).@"enum";
    assert(Enum.is_exhaustive);

    return Enum.fields.len;
}

/// Pipeline stage identifier — matches CommitStage in server.zig.
pub const Stage = enum {
    route,
    prefetch,
    handle,
    handle_wait,
    render,
};

/// Sidecar CALL function — the 4 protocol round-trips.
pub const CallFunction = enum {
    route,
    prefetch,
    handle,
    render,
};

// ---------------------------------------------------------------------------
// Base Event — further split into EventTracing and EventTiming.
//
// EventTracing tracks concurrent instances (one slot per in-flight span).
// EventTiming tracks aggregate statistics (one slot per timing signature).
//
// Same tag, different payloads, different array sizes.
// ---------------------------------------------------------------------------

pub const Event = union(enum) {
    // aggregate_only — fires every tick, too frequent for JSON spans
    tick,

    // Pipeline stage — one span per stage per slot
    pipeline_stage: struct {
        stage: Stage,
        slot: u8,
        op: ?u8 = null, // null at .route (operation unknown); raw Operation enum value
    },

    // Sidecar CALL→RESULT — one span per round-trip
    sidecar_call: struct {
        function: CallFunction,
        slot: u8,
        request_id: u32 = 0,
    },

    // Storage operation — one span per query or write
    storage_op: struct { slot: u8 },

    // Synchronization wait — not a boundary crossing
    handle_lock_wait: struct { slot: u8 },

    // WAL append — disk write after commit
    wal_append,

    // Metrics emission — self-traces the emit call
    metrics_emit,

    pub const Tag = std.meta.Tag(Event);

    /// Flatten the union for JSON — remove the extra indirection layer.
    pub fn jsonStringify(event: Event, jw: anytype) !void {
        switch (event) {
            inline else => |payload, tag| {
                if (@TypeOf(payload) == void) {
                    try jw.write("");
                } else if (tag == .pipeline_stage) {
                    try jw.write(.{
                        .stage = @tagName(payload.stage),
                        .slot = payload.slot,
                        .op = payload.op,
                    });
                } else if (tag == .sidecar_call) {
                    try jw.write(.{
                        .function = @tagName(payload.function),
                        .slot = payload.slot,
                        .request_id = payload.request_id,
                    });
                } else {
                    try jw.write(payload);
                }
            },
        }
    }

    /// Convert base Event to EventTracing or EventTiming.
    pub fn as(event: *const Event, EventType: type) EventType {
        return switch (event.*) {
            inline else => |source_payload, tag| {
                const TargetPayload = @FieldType(EventType, @tagName(tag));
                const target_payload_info = @typeInfo(TargetPayload);
                assert(target_payload_info == .void or target_payload_info == .@"struct");

                const target_payload: TargetPayload = switch (@typeInfo(TargetPayload)) {
                    .void => {},
                    .@"struct" => blk: {
                        var target_payload: TargetPayload = undefined;
                        inline for (std.meta.fields(TargetPayload)) |field| {
                            @field(target_payload, field.name) = @field(source_payload, field.name);
                        }
                        break :blk target_payload;
                    },
                    else => unreachable,
                };

                return @unionInit(EventType, @tagName(tag), target_payload);
            },
        };
    }
};

// ---------------------------------------------------------------------------
// EventTracing — tracks concurrent instances.
//
// Each event type has a cardinality = max concurrent instances.
// stack() computes a unique array index for each instance.
// Total array size = sum of all cardinalities (stack_count).
// ---------------------------------------------------------------------------

pub const EventTracing = union(enum) {
    tick,
    pipeline_stage: struct { slot: u8 },
    sidecar_call: struct { slot: u8 },
    storage_op: struct { slot: u8 },
    handle_lock_wait: struct { slot: u8 },
    wal_append,
    metrics_emit,

    pub fn aggregate_only(event: *const EventTracing) bool {
        return switch (event.*) {
            .tick => true,
            else => false,
        };
    }

    /// Compute unique stack position for this event instance.
    pub fn stack(event: *const EventTracing) u32 {
        switch (event.*) {
            inline .pipeline_stage,
            .sidecar_call,
            .storage_op,
            .handle_lock_wait,
            => |data, tag| {
                const event_tag: Event.Tag = @enumFromInt(@intFromEnum(tag));
                assert(data.slot < stack_limits.get(event_tag));
                const base = stack_bases.get(event_tag);
                return base + @as(u32, data.slot);
            },
            inline else => |data, tag| {
                const event_tag: Event.Tag = @enumFromInt(@intFromEnum(tag));
                comptime assert(@TypeOf(data) == void);
                comptime assert(stack_limits.get(event_tag) == 1);
                return comptime stack_bases.get(event_tag);
            },
        }
    }

    pub fn format(
        event: *const EventTracing,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (event.*) {
            inline else => |data| {
                if (@TypeOf(data) == void) return;
                try format_data(data, writer);
            },
        }
    }

    // -- Comptime stack layout --

    pub const slots_max = constants.pipeline_slots_max;

    pub const stack_limits = std.enums.EnumArray(Event.Tag, u32).init(.{
        .tick = 1,
        .pipeline_stage = slots_max,
        .sidecar_call = slots_max,
        .storage_op = slots_max,
        .handle_lock_wait = slots_max,
        .wal_append = 1,
        .metrics_emit = 1,
    });

    pub const stack_count = count: {
        var count: u32 = 0;
        for (std.enums.values(Event.Tag)) |event_type| {
            count += stack_limits.get(event_type);
        }
        break :count count;
    };

    pub const stack_bases = bases: {
        var bases = std.enums.EnumArray(Event.Tag, u32).initUndefined();
        var offset: u32 = 0;
        for (std.enums.values(Event.Tag)) |event_type| {
            bases.set(event_type, offset);
            offset += stack_limits.get(event_type);
        }
        break :bases bases;
    };
};

// ---------------------------------------------------------------------------
// EventTiming — aggregate statistics (min/max/sum/count).
//
// Different cardinality from EventTracing. Timing aggregates by
// WORK TYPE (stage, function), not by INSTANCE (slot).
//
// pipeline_stage timing distinguishes route vs prefetch vs handle.
// sidecar_call timing distinguishes route vs prefetch vs handle vs render.
// All slots' timings aggregate together.
// ---------------------------------------------------------------------------

pub const EventTiming = union(enum) {
    tick,
    pipeline_stage: struct { stage: Stage },
    sidecar_call: struct { function: CallFunction },
    storage_op,
    handle_lock_wait,
    wal_append,
    metrics_emit,

    pub fn slot(event: *const EventTiming) u32 {
        switch (event.*) {
            .pipeline_stage => |data| {
                return slot_bases.get(.pipeline_stage) + @as(u32, index_from_enum(data.stage));
            },
            .sidecar_call => |data| {
                return slot_bases.get(.sidecar_call) + @as(u32, index_from_enum(data.function));
            },
            inline else => |data, tag| {
                const event_tag: Event.Tag = @enumFromInt(@intFromEnum(tag));
                comptime assert(@TypeOf(data) == void);
                comptime assert(slot_limits.get(event_tag) == 1);
                return comptime slot_bases.get(event_tag);
            },
        }
    }

    pub fn format(
        event: *const EventTiming,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (event.*) {
            inline else => |data| {
                if (@TypeOf(data) == void) return;
                try format_data(data, writer);
            },
        }
    }

    pub const slot_limits = std.enums.EnumArray(Event.Tag, u32).init(.{
        .tick = 1,
        .pipeline_stage = enum_count(Stage),
        .sidecar_call = enum_count(CallFunction),
        .storage_op = 1,
        .handle_lock_wait = 1,
        .wal_append = 1,
        .metrics_emit = 1,
    });

    pub const slot_count = count: {
        var count: u32 = 0;
        for (std.enums.values(Event.Tag)) |event_type| {
            count += slot_limits.get(event_type);
        }
        break :count count;
    };

    pub const slot_bases = bases: {
        var bases = std.enums.EnumArray(Event.Tag, u32).initUndefined();
        var offset: u32 = 0;
        for (std.enums.values(Event.Tag)) |event_type| {
            bases.set(event_type, offset);
            offset += slot_limits.get(event_type);
        }
        break :bases bases;
    };
};

// ---------------------------------------------------------------------------
// EventMetric — gauges and counters.
//
// Same slot/base/count infrastructure as EventTiming.
// gauge(): last-set wins. count(): cumulative.
// Matches TB's trace/event.zig EventMetric.
// ---------------------------------------------------------------------------

pub const EventMetric = union(enum) {
    const Tag = std.meta.Tag(EventMetric);

    // Framework gauges — connection pool health.
    connections_active,
    connections_receiving,
    connections_ready,
    connections_sending,

    // Per-operation counters — one slot per Operation variant.
    // Exact cardinality from the domain enum, same as TB's
    // table_count_visible using enum_count(TreeEnum).
    requests_by_operation: struct { operation: Operation },

    // Per-status counters — one slot per Status variant.
    requests_by_status: struct { status: Status },

    pub const slot_limits = std.enums.EnumArray(Tag, u32).init(.{
        .connections_active = 1,
        .connections_receiving = 1,
        .connections_ready = 1,
        .connections_sending = 1,
        .requests_by_operation = enum_count(Operation),
        .requests_by_status = enum_count(Status),
    });

    pub const slot_bases = array: {
        var array = std.enums.EnumArray(Tag, u32).initDefault(0, .{});
        var next: u32 = 0;
        for (std.enums.values(Tag)) |event_type| {
            array.set(event_type, next);
            next += slot_limits.get(event_type);
        }
        break :array array;
    };

    pub const slot_count = count: {
        var total: u32 = 0;
        for (std.enums.values(Tag)) |event_type| {
            total += slot_limits.get(event_type);
        }
        break :count total;
    };

    pub fn slot(event: *const EventMetric) u32 {
        switch (event.*) {
            inline .requests_by_operation => |data| {
                const offset = index_from_enum(data.operation);
                assert(offset < slot_limits.get(.requests_by_operation));
                return slot_bases.get(.requests_by_operation) + offset;
            },
            inline .requests_by_status => |data| {
                const offset = index_from_enum(data.status);
                assert(offset < slot_limits.get(.requests_by_status));
                return slot_bases.get(.requests_by_status) + offset;
            },
            else => {
                return slot_bases.get(event.*);
            },
        }
    }
};

/// Format event data fields as "key=value" pairs. Enums use @tagName.
/// Copied from TB's trace/event.zig format_data.
pub fn format_data(
    data: anytype,
    writer: anytype,
) !void {
    const Data = @TypeOf(data);
    if (Data == void) return;

    const fields = std.meta.fields(Data);
    inline for (fields, 0..) |data_field, i| {
        assert(data_field.type == bool or
            @typeInfo(data_field.type) == .int or
            @typeInfo(data_field.type) == .@"enum" or
            @typeInfo(data_field.type) == .@"union");

        const data_field_value = @field(data, data_field.name);
        try writer.writeAll(data_field.name);
        try writer.writeByte('=');

        if (@typeInfo(data_field.type) == .@"enum" or
            @typeInfo(data_field.type) == .@"union")
        {
            try writer.print("{s}", .{@tagName(data_field_value)});
        } else {
            try writer.print("{}", .{data_field_value});
        }

        if (i != fields.len - 1) {
            try writer.writeByte(' ');
        }
    }
}

// ---------------------------------------------------------------------------
// EventTimingAggregate — accumulated timing values between emissions.
// ---------------------------------------------------------------------------

pub const EventTimingAggregate = struct {
    event: EventTiming,
    values: struct {
        duration_min: @import("stdx").Duration,
        duration_max: @import("stdx").Duration,
        duration_sum: @import("stdx").Duration,
        count: u64,
    },
};

// ---------------------------------------------------------------------------
// EventMetricAggregate — gauge/counter value between emissions.
// Matches TB's trace/event.zig EventMetricAggregate.
// ---------------------------------------------------------------------------

pub const EventMetricAggregate = struct {
    pub const ValueType = i65;

    event: EventMetric,
    value: ValueType,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stack_count covers all events" {
    // stack_count should be the sum of all cardinalities.
    const expected = 1 + // tick
        EventTracing.slots_max + // pipeline_stage
        EventTracing.slots_max + // sidecar_call
        EventTracing.slots_max + // storage_op
        EventTracing.slots_max + // handle_lock_wait
        1 + // wal_append
        1; // metrics_emit
    try std.testing.expectEqual(expected, EventTracing.stack_count);
}

test "slot_count covers all timing variants" {
    const expected = 1 + // tick
        enum_count(Stage) + // pipeline_stage (5 stages)
        enum_count(CallFunction) + // sidecar_call (4 functions)
        1 + // storage_op
        1 + // handle_lock_wait
        1 + // wal_append
        1; // metrics_emit
    try std.testing.expectEqual(expected, EventTiming.slot_count);
}

test "stack positions are unique per event type" {
    const s0 = EventTracing.stack(&.{ .pipeline_stage = .{ .slot = 0 } });
    const c0 = EventTracing.stack(&.{ .sidecar_call = .{ .slot = 0 } });
    const q0 = EventTracing.stack(&.{ .storage_op = .{ .slot = 0 } });
    const tick = EventTracing.stack(&.{ .tick = {} });
    // Each event type occupies a different stack range.
    try std.testing.expect(s0 != c0);
    try std.testing.expect(c0 != q0);
    try std.testing.expect(s0 != tick);
    // Within a type, slot 0 gets the base position.
    if (EventTracing.slots_max > 1) {
        const s1 = EventTracing.stack(&.{ .pipeline_stage = .{ .slot = 1 } });
        try std.testing.expect(s0 != s1);
        try std.testing.expect(s1 != c0);
    }
}

test "timing slots aggregate by work type, not instance" {
    // Different slots → same timing slot (aggregate together)
    const t0 = EventTiming.slot(&.{ .pipeline_stage = .{ .stage = .prefetch } });
    // Same stage from a different slot should produce the same timing slot
    // (timing doesn't know about slots — only stages)
    const t1 = EventTiming.slot(&.{ .pipeline_stage = .{ .stage = .prefetch } });
    try std.testing.expectEqual(t0, t1);

    // Different stages → different timing slots
    const t2 = EventTiming.slot(&.{ .pipeline_stage = .{ .stage = .handle } });
    try std.testing.expect(t0 != t2);
}

test "Event.as converts to EventTracing" {
    const event = Event{ .pipeline_stage = .{ .stage = .prefetch, .slot = 2, .op = 5 } };
    const tracing = event.as(EventTracing);
    try std.testing.expectEqual(@as(u8, 2), tracing.pipeline_stage.slot);
}

test "Event.as converts to EventTiming" {
    const event = Event{ .pipeline_stage = .{ .stage = .prefetch, .slot = 2, .op = 5 } };
    const timing = event.as(EventTiming);
    try std.testing.expectEqual(Stage.prefetch, timing.pipeline_stage.stage);
}

test "aggregate_only: only tick" {
    try std.testing.expect(EventTracing.aggregate_only(&.{ .tick = {} }));
    try std.testing.expect(!EventTracing.aggregate_only(&.{ .pipeline_stage = .{ .slot = 0 } }));
    try std.testing.expect(!EventTracing.aggregate_only(&.{ .sidecar_call = .{ .slot = 0 } }));
}
