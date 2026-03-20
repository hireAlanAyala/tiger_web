const std = @import("std");
const assert = std.debug.assert;
const handler_mod = @import("handler.zig");
const http = @import("http.zig");

/// Build an App type from a handler tuple and domain types.
///
/// The returned type conforms to the interface ServerType expects:
/// translate(), encode_response(), etc. Dispatch functions are methods
/// on the type, comptime-generated from the handler tuple.
///
/// Usage:
///   pub const App = framework.app.AppType(.{
///       .handlers = @import("generated/handlers.generated.zig").handlers,
///       .Message = message.Message,
///       .MessageResponse = message.MessageResponse,
///       .Operation = message.Operation,
///       .Status = message.Status,
///       .Identity = message.PrefetchIdentity,
///       .FollowupState = message.FollowupState,
///       .StateMachineType = state_machine.StateMachineType,
///       .Wal = wal.WalType(message.Message, message.wal_root),
///       // Passthrough functions until fully migrated:
///       .encode_response = render.encode_response,
///       .encode_followup = render.encode_followup,
///       .refresh_message = refresh_message,
///   });
pub fn AppType(comptime config: anytype) type {
    const handlers = config.handlers;
    const Message = config.Message;
    const Operation = config.Operation;
    const Identity = config.Identity;

    // --- Comptime validation ---

    // Operation must be an enum with a .root sentinel.
    if (@typeInfo(Operation) != .@"enum") {
        @compileError("Operation must be an enum");
    }
    if (!@hasField(Operation, "root")) {
        @compileError("Operation enum must have a .root variant (framework sentinel)");
    }

    // 1. Handler count matches operation count (minus root).
    const op_fields = @typeInfo(Operation).@"enum".fields;
    var non_root_count: usize = 0;
    for (op_fields) |f| {
        if (!std.mem.eql(u8, f.name, "root")) non_root_count += 1;
    }
    if (handlers.len != non_root_count) {
        @compileError(std.fmt.comptimePrint(
            "handler count ({d}) does not match operation count ({d}, excluding root)",
            .{ handlers.len, non_root_count },
        ));
    }

    // 2. Validate each handler and check for duplicates.
    // Each handler entry must have .operation and a handler module.
    var seen_ops: [op_fields.len]bool = .{false} ** op_fields.len;
    for (handlers) |h| {
        const op_int = @intFromEnum(h.operation);
        if (h.operation == .root) {
            @compileError("handler registered for .root — root is a framework sentinel, not an operation");
        }
        if (seen_ops[op_int]) {
            @compileError("duplicate handler for ." ++ @tagName(h.operation));
        }
        seen_ops[op_int] = true;

        // Validate handler interface.
        _ = handler_mod.ValidateHandler(h.handler, h.operation, Identity);
    }

    // 3. Exhaustiveness — every non-root operation must have a handler.
    for (op_fields) |f| {
        if (std.mem.eql(u8, f.name, "root")) continue;
        if (!seen_ops[f.value]) {
            @compileError("missing handler for ." ++ f.name);
        }
    }

    return struct {
        // --- Pass-through types ---
        pub const MessageType = Message;
        pub const MessageResponseType = config.MessageResponse;
        pub const FollowupStateType = config.FollowupState;
        pub const OperationType = Operation;
        pub const StatusType = config.Status;
        pub const IdentityType = Identity;
        pub const StateMachineTypeFn = config.StateMachineType;
        pub const WalType = config.Wal;

        // Re-export under names ServerType expects.
        pub const MessageT = Message;
        pub const MessageResponse = config.MessageResponse;
        pub const FollowupState = config.FollowupState;
        pub const Status = config.Status;
        pub const Wal = config.Wal;
        pub fn StateMachineType(comptime Storage: type) type {
            return config.StateMachineType(Storage);
        }

        // --- Generated dispatch ---

        /// Route dispatch: try each handler's route function, assert at most one matches.
        /// Always tries all handlers — duplicate route detection is worth the cost.
        /// ~24 handlers × nanoseconds per route check = negligible vs request latency.
        pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
            var result: ?Message = null;
            inline for (handlers) |h| {
                if (h.handler.route(method, path, body)) |msg| {
                    assert(result == null); // duplicate route match
                    result = msg;
                }
            }
            return result;
        }

        // --- Passthrough functions (until render migration) ---
        pub const encode_response = config.encode_response;
        pub const encode_followup = config.encode_followup;
        pub const refresh_message = config.refresh_message;
    };
}

// =====================================================================
// Tests
// =====================================================================

// Mock types for testing.
const TestOperation = enum(u8) {
    root = 0,
    get_thing = 1,
    create_thing = 2,

    pub fn EventType(comptime op: TestOperation) type {
        return switch (op) {
            .root => void,
            .get_thing => void,
            .create_thing => TestBody,
        };
    }

    pub fn is_mutation(op: TestOperation) bool {
        return switch (op) {
            .root, .get_thing => false,
            .create_thing => true,
        };
    }
};

const TestBody = struct { name: u8 };
const TestIdentity = struct { user_id: u128 };
const TestMessage = struct {
    operation: TestOperation,
    pub fn set_credential(_: *@This(), _: ?[]const u8) void {}
};
const TestResponse = struct { status: TestStatus };
const TestStatus = enum(u8) { ok = 1, err = 2 };
const TestFollowup = struct {};

const GetThingHandler = struct {
    pub const Prefetch = struct { found: bool };
    pub fn route(method: http.Method, _: []const u8, _: []const u8) ?TestMessage {
        if (method == .get) return TestMessage{ .operation = .get_thing };
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return .{ .found = true };
    }
    pub fn render() void {}
};

const CreateThingHandler = struct {
    pub const Prefetch = struct { existing: bool };
    pub fn route(method: http.Method, _: []const u8, _: []const u8) ?TestMessage {
        if (method == .post) return TestMessage{ .operation = .create_thing };
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return .{ .existing = false };
    }
    pub fn handle() void {}
    pub fn render() void {}
};

fn dummy_encode(_: []u8, _: TestOperation, _: TestResponse, _: bool, _: *const [32]u8) void {}
fn dummy_followup(_: []u8, _: TestResponse, _: *const TestFollowup, _: *const [32]u8) void {}
fn dummy_refresh() TestMessage {
    return .{ .operation = .get_thing };
}
fn dummy_sm(_: anytype) type {
    return struct {};
}

const TestApp = AppType(.{
    .handlers = .{
        .{ .operation = TestOperation.get_thing, .handler = GetThingHandler },
        .{ .operation = TestOperation.create_thing, .handler = CreateThingHandler },
    },
    .Message = TestMessage,
    .MessageResponse = TestResponse,
    .Operation = TestOperation,
    .Status = TestStatus,
    .Identity = TestIdentity,
    .FollowupState = TestFollowup,
    .StateMachineType = dummy_sm,
    .Wal = struct {},
    .encode_response = dummy_encode,
    .encode_followup = dummy_followup,
    .refresh_message = dummy_refresh,
});

test "AppType translate routes GET to get_thing" {
    const result = TestApp.translate(.get, "/things/123", "");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(TestOperation.get_thing, result.?.operation);
}

test "AppType translate routes POST to create_thing" {
    const result = TestApp.translate(.post, "/things", "{}");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(TestOperation.create_thing, result.?.operation);
}

test "AppType translate returns null for unmatched" {
    const result = TestApp.translate(.delete, "/things/123", "");
    try std.testing.expect(result == null);
}

test "AppType comptime validation passes" {
    // If we got here, comptime validation succeeded:
    // - handler count matches operation count
    // - no duplicates
    // - exhaustiveness (all non-root ops covered)
    // - handler interface validation (Prefetch type, route/prefetch/render functions)
    try std.testing.expect(true);
}
