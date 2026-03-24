const std = @import("std");
const assert = std.debug.assert;

/// Handler interface types — comptime-generated per operation.
///
/// The framework's App() function calls these with app-specific types
/// to generate per-operation Context structs and validate handler signatures.
/// The framework never imports app types directly.

/// Framework-provided context — resolved once before prefetch, immutable
/// through the entire request lifecycle. Available in all handler phases
/// (prefetch, handle, render).
///
/// Three fields, deliberately small:
/// - identity: who is making the request (resolved from cookie credential)
/// - now: wall-clock timestamp (seconds since epoch)
/// - is_sse: true if this is a Datastar SSE request (affects render format)
///
/// Everything else the handler needs is either in the message body (user
/// input) or in the prefetch data (storage results). The framework context
/// is "things about the request environment that aren't the request itself."
pub fn FrameworkCtx(comptime Identity: type) type {
    return struct {
        identity: Identity,
        now: i64,
        is_sse: bool,
    };
}

/// Generate a per-operation context type.
///
/// Handlers receive this in handle and render. The framework assembles it
/// from prefetched data, the typed request body, status, and framework
/// context (identity, timestamp, request metadata).
///
/// Render may also receive a read-only db handle as a second parameter
/// for post-mutation queries. See decisions/render-db-access.md.
///
/// Usage (in handler):
///   pub const Context = HandlerContext(Prefetch, Body, Identity, Status);
///   pub fn handle(ctx: Context) ExecuteResult { ... }
///   pub fn render(ctx: Context) []const u8 { ... }
///   pub fn render(ctx: Context, db: anytype) []const u8 { ... }  // with db
pub fn HandlerContext(comptime Prefetch: type, comptime Body: type, comptime Identity: type, comptime Status: type) type {
    if (@typeInfo(Prefetch) != .@"struct") {
        @compileError("Prefetch must be a struct, got " ++ @typeName(Prefetch));
    }
    if (@typeInfo(Identity) != .@"struct") {
        @compileError("Identity must be a struct, got " ++ @typeName(Identity));
    }
    if (@typeInfo(Status) != .@"enum") {
        @compileError("Status must be an enum, got " ++ @typeName(Status));
    }
    const FwCtx = FrameworkCtx(Identity);
    return struct {
        prefetched: Prefetch,
        body: if (Body == void) void else *const Body,
        fw: FwCtx,
        render_buf: []u8,
        /// Handler status — set by the framework after handle() returns.
        /// Available in render(). Default .ok for handle phase (unused).
        status: Status = .ok,

        pub const PrefetchType = Prefetch;
        pub const BodyType = Body;
        pub const IdentityType = Identity;
        pub const StatusType = Status;
        pub const FwCtxType = FwCtx;

        /// Access body — asserts non-void at comptime.
        pub fn body_val(self: @This()) if (Body == void) @compileError("no body for void EventType") else *const Body {
            return self.body;
        }
    };
}

/// Validate that a handler module has the required interface.
///
/// Called at comptime by App() for each handler in the tuple.
/// Checks that the handler exports the right types AND full function
/// signatures (parameter types, return types, parameter count).
///
/// App-level types (Message, ExecuteResult) are passed as comptime parameters.
/// Render returns []const u8 or a comptime tuple — validated by the framework.
///
/// Returns a descriptor struct with resolved types for dispatch generation.
pub fn ValidateHandler(
    comptime handler: type,
    comptime operation: anytype,
    comptime Identity: type,
    comptime Status: type,
    comptime Message: type,
    comptime ExecuteResult: type,
) type {
    const op_name = @tagName(operation);

    // Handler must export a Prefetch type that is a struct.
    if (!@hasDecl(handler, "Prefetch")) {
        @compileError("handler for ." ++ op_name ++ " must export a Prefetch type");
    }
    const Prefetch = handler.Prefetch;
    if (@typeInfo(Prefetch) != .@"struct") {
        @compileError("handler for ." ++ op_name ++ ": Prefetch must be a struct");
    }

    // Resolve the body type from the operation's EventType.
    const Body = operation.EventType();
    const Ctx = HandlerContext(Prefetch, Body, Identity, Status);

    // --- Validate route ---
    if (!@hasDecl(handler, "route")) {
        @compileError("handler for ." ++ op_name ++ " must export a route function");
    }
    {
        const info = @typeInfo(@TypeOf(handler.route)).@"fn";
        if (info.params.len < 3) {
            @compileError("handler for ." ++ op_name ++ ": route must accept (Method, path, body)");
        }
        const Return = info.return_type orelse
            @compileError("handler for ." ++ op_name ++ ": route must have a return type");
        if (Return != ?Message) {
            @compileError("handler for ." ++ op_name ++ ": route must return ?" ++ @typeName(Message));
        }
    }

    // --- Validate prefetch ---
    if (!@hasDecl(handler, "prefetch")) {
        @compileError("handler for ." ++ op_name ++ " must export a prefetch function");
    }
    {
        const info = @typeInfo(@TypeOf(handler.prefetch)).@"fn";
        const Return = info.return_type orelse
            @compileError("handler for ." ++ op_name ++ ": prefetch must have a return type");
        if (Return != ?Prefetch) {
            @compileError("handler for ." ++ op_name ++ ": prefetch must return ?" ++ @typeName(Prefetch));
        }
    }

    // --- Validate handle (required) ---
    // Every handler must export handle(). The handler decides the status —
    // the framework can't guess. Even read-only handlers must declare
    // "this always succeeds" explicitly. No default ok, no silent guessing.
    if (!@hasDecl(handler, "handle")) {
        @compileError("handler for ." ++ op_name ++ " must export a handle function");
    }
    {
        const info = @typeInfo(@TypeOf(handler.handle)).@"fn";
        if (info.params.len < 1) {
            @compileError("handler for ." ++ op_name ++ ": handle must accept (ctx)");
        }
        // First param should be the Context type.
        if (info.params[0].type) |T| {
            if (T != Ctx) {
                @compileError("handler for ." ++ op_name ++ ": handle first param must be " ++ @typeName(Ctx));
            }
        }
        const Return = info.return_type orelse
            @compileError("handler for ." ++ op_name ++ ": handle must have a return type");
        if (Return != ExecuteResult) {
            @compileError("handler for ." ++ op_name ++ ": handle must return " ++ @typeName(ExecuteResult));
        }
    }

    // --- Validate render ---
    // render(ctx) or render(ctx, db) — returns []const u8 or a comptime tuple.
    // First param must be the Context type. Second param (if present) is the
    // read-only db handle (anytype). See decisions/handler-owns-response.md.
    if (!@hasDecl(handler, "render")) {
        @compileError("handler for ." ++ op_name ++ " must export a render function");
    }
    {
        const info = @typeInfo(@TypeOf(handler.render)).@"fn";
        if (info.params.len < 1) {
            @compileError("handler for ." ++ op_name ++ ": render must accept (ctx) or (ctx, db)");
        }
        // First param should be the Context type.
        if (info.params[0].type) |T| {
            if (T != Ctx) {
                @compileError("handler for ." ++ op_name ++ ": render first param must be " ++ @typeName(Ctx));
            }
        }
    }

    return struct {
        pub const Context = Ctx;
        pub const PrefetchType = Prefetch;
        pub const BodyType = Body;
    };
}

// =====================================================================
// Tests
// =====================================================================

const MockStatus = enum { ok, not_found };

test "HandlerContext void body" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity, MockStatus);

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .product = 42 },
        .body = {},
        .fw = .{ .identity = .{ .user_id = 1 }, .now = 0, .is_sse = false },
        .render_buf = &render_buf,
    };

    try std.testing.expectEqual(@as(?u32, 42), ctx.prefetched.product);
    try std.testing.expectEqual(@as(u128, 1), ctx.fw.identity.user_id);
    try std.testing.expectEqual(MockStatus.ok, ctx.status);
}

test "HandlerContext typed body" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { existing: ?u32 };
    const Body = struct { name: [8]u8, name_len: u8 };
    const Ctx = HandlerContext(Prefetch, Body, Identity, MockStatus);

    var body = Body{ .name = .{0} ** 8, .name_len = 4 };
    @memcpy(body.name[0..4], "test");

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .existing = null },
        .body = &body,
        .fw = .{ .identity = .{ .user_id = 2 }, .now = 0, .is_sse = false },
        .render_buf = &render_buf,
    };

    try std.testing.expectEqual(@as(?u32, null), ctx.prefetched.existing);
    try std.testing.expectEqual(@as(u8, 4), ctx.body_val().name_len);
}

test "HandlerContext status field" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity, MockStatus);

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .product = null },
        .body = {},
        .fw = .{ .identity = .{ .user_id = 1 }, .now = 0, .is_sse = false },
        .render_buf = &render_buf,
        .status = .not_found,
    };

    try std.testing.expectEqual(MockStatus.not_found, ctx.status);
}

test "HandlerContext exposes type aliases" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity, MockStatus);

    try std.testing.expect(Ctx.PrefetchType == Prefetch);
    try std.testing.expect(Ctx.BodyType == void);
    try std.testing.expect(Ctx.IdentityType == Identity);
    try std.testing.expect(Ctx.StatusType == MockStatus);
}

// --- Mock types for testing ---

const MockIdentity = struct { user_id: u128 };
const MockMessage = struct { operation: MockOp };
const MockExecuteResult = struct {
    response: struct { status: u8 },
    writes: [1]u8,
    writes_len: u8,
};
const MockBody = struct { name: u8 };

const MockOp = enum(u8) {
    root = 0,
    get_thing = 1,
    create_thing = 2,

    pub fn EventType(comptime op: MockOp) type {
        return switch (op) {
            .root, .get_thing => void,
            .create_thing => MockBody,
        };
    }
};

// Forward-declare context types using the handler's own Prefetch type.
// Must match what ValidateHandler computes internally.

const MockReadOnlyHandler = struct {
    pub const Prefetch = struct { product: ?u32 };
    pub const Context = HandlerContext(Prefetch, void, MockIdentity, MockStatus);
    pub fn route(_: @import("http.zig").Method, _: []const u8, _: []const u8) ?MockMessage {
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn handle(_: Context) MockExecuteResult {
        return .{ .response = .{ .status = 1 }, .writes = .{0}, .writes_len = 0 };
    }
    pub fn render(ctx: Context) []const u8 {
        _ = ctx;
        return "<div>ok</div>";
    }
};

// Mutation handler — correct signatures for typed EventType.

const MockMutationHandler = struct {
    pub const Prefetch = struct { existing: ?u32 };
    const Ctx = HandlerContext(Prefetch, MockBody, MockIdentity, MockStatus);
    pub fn route(_: @import("http.zig").Method, _: []const u8, _: []const u8) ?MockMessage {
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn handle(_: Ctx) MockExecuteResult {
        return .{ .response = .{ .status = 1 }, .writes = .{0}, .writes_len = 0 };
    }
    pub fn render(ctx: Ctx) []const u8 {
        _ = ctx;
        return "<div>ok</div>";
    }
};

test "ValidateHandler read-only" {
    const V = ValidateHandler(MockReadOnlyHandler, MockOp.get_thing, MockIdentity, MockStatus, MockMessage, MockExecuteResult);
    try std.testing.expect(V.PrefetchType == MockReadOnlyHandler.Prefetch);
    try std.testing.expect(V.BodyType == void);
}

test "ValidateHandler mutation" {
    const V = ValidateHandler(MockMutationHandler, MockOp.create_thing, MockIdentity, MockStatus, MockMessage, MockExecuteResult);
    try std.testing.expect(V.BodyType == MockBody);
}
