const std = @import("std");
const assert = std.debug.assert;
const effects = @import("effects.zig");

/// Handler interface types — comptime-generated per operation.
///
/// The framework's App() function calls these with app-specific types
/// to generate per-operation Context structs and validate handler signatures.
/// The framework never imports app types directly.

/// Generate a per-operation context type.
///
/// Handlers receive this as their single parameter in handle and render.
/// The framework assembles it from prefetched data, the typed request body,
/// and the visitor identity.
///
/// Usage (inside App comptime):
///   const Ctx = HandlerContext(GetProductPrefetch, void, PrefetchIdentity);
///   // Ctx has: .prefetched, .identity
///   // .body is omitted when EventType is void (read-only operations)
///
///   const Ctx = HandlerContext(CreateProductPrefetch, Product, PrefetchIdentity);
///   // Ctx has: .prefetched, .body, .identity
pub fn HandlerContext(comptime Prefetch: type, comptime Body: type, comptime Identity: type) type {
    if (@typeInfo(Prefetch) != .@"struct") {
        @compileError("Prefetch must be a struct, got " ++ @typeName(Prefetch));
    }
    if (@typeInfo(Identity) != .@"struct") {
        @compileError("Identity must be a struct, got " ++ @typeName(Identity));
    }
    return struct {
        prefetched: Prefetch,
        body: if (Body == void) void else *const Body,
        identity: Identity,
        render_buf: []u8,

        pub const PrefetchType = Prefetch;
        pub const BodyType = Body;
        pub const IdentityType = Identity;

        /// Access body — asserts non-void at comptime.
        pub fn body_val(self: @This()) if (Body == void) @compileError("no body for void EventType") else *const Body {
            return self.body;
        }

        /// Build render effects from a tuple of effect descriptors.
        /// Validates effect structure at comptime, writes content at runtime.
        ///
        /// Usage:
        ///   return ctx.render(.{
        ///       .{ "patch", "#product-card", html, "outer" },
        ///       .{ "sync", "/dashboard" },
        ///   });
        pub fn render(self: @This(), effects_tuple: anytype) effects.RenderResult {
            assert(self.render_buf.len > 0); // framework must provide a render buffer
            return effects.process_effects(effects_tuple, self.render_buf);
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
/// RenderResult is framework-owned (effects.RenderResult) — not app-provided.
///
/// Returns a descriptor struct with resolved types for dispatch generation.
pub fn ValidateHandler(
    comptime handler: type,
    comptime operation: anytype,
    comptime Identity: type,
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
    const Ctx = HandlerContext(Prefetch, Body, Identity);

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

    // --- Validate handle (optional — missing means read-only) ---
    const has_handle = @hasDecl(handler, "handle");
    if (has_handle) {
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
    if (!@hasDecl(handler, "render")) {
        @compileError("handler for ." ++ op_name ++ " must export a render function");
    }
    {
        const info = @typeInfo(@TypeOf(handler.render)).@"fn";
        if (info.params.len < 1) {
            @compileError("handler for ." ++ op_name ++ ": render must accept (ctx, ...)");
        }
        // First param should be the Context type.
        if (info.params[0].type) |T| {
            if (T != Ctx) {
                @compileError("handler for ." ++ op_name ++ ": render first param must be " ++ @typeName(Ctx));
            }
        }
        const Return = info.return_type orelse
            @compileError("handler for ." ++ op_name ++ ": render must have a return type");
        if (Return != effects.RenderResult) {
            @compileError("handler for ." ++ op_name ++ ": render must return " ++ @typeName(effects.RenderResult));
        }
    }

    return struct {
        pub const Context = Ctx;
        pub const PrefetchType = Prefetch;
        pub const BodyType = Body;
        pub const is_read_only = !has_handle;
    };
}

// =====================================================================
// Tests
// =====================================================================

test "HandlerContext void body" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity);

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .product = 42 },
        .body = {},
        .identity = .{ .user_id = 1 },
        .render_buf = &render_buf,
    };

    try std.testing.expectEqual(@as(?u32, 42), ctx.prefetched.product);
    try std.testing.expectEqual(@as(u128, 1), ctx.identity.user_id);
}

test "HandlerContext typed body" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { existing: ?u32 };
    const Body = struct { name: [8]u8, name_len: u8 };
    const Ctx = HandlerContext(Prefetch, Body, Identity);

    var body = Body{ .name = .{0} ** 8, .name_len = 4 };
    @memcpy(body.name[0..4], "test");

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .existing = null },
        .body = &body,
        .identity = .{ .user_id = 2 },
        .render_buf = &render_buf,
    };

    try std.testing.expectEqual(@as(?u32, null), ctx.prefetched.existing);
    try std.testing.expectEqual(@as(u8, 4), ctx.body_val().name_len);
}

test "HandlerContext ctx.render with effects" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity);

    var render_buf: [4096]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .product = 42 },
        .body = {},
        .identity = .{ .user_id = 1 },
        .render_buf = &render_buf,
    };

    const html = "<div>hello</div>";
    const result = ctx.render(.{
        .{ "patch", "#target", @as([]const u8, html), "inner" },
        .{ "sync", "/dashboard" },
    });

    try std.testing.expectEqual(@as(u8, 2), result.len);
    const s = result.slice();
    try std.testing.expectEqual(effects.Verb.patch, s[0].verb);
    try std.testing.expectEqual(effects.PatchMode.inner, s[0].mode);
    try std.testing.expect(std.mem.eql(u8, "#target", s[0].selector_slice()));
    try std.testing.expect(std.mem.eql(u8, html, s[0].content(&render_buf)));
    try std.testing.expectEqual(effects.Verb.sync, s[1].verb);
    try std.testing.expect(std.mem.eql(u8, "/dashboard", s[1].selector_slice()));
}

test "HandlerContext ctx.render empty tuple" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity);

    var render_buf: [1024]u8 = undefined;
    const ctx = Ctx{
        .prefetched = .{ .product = 42 },
        .body = {},
        .identity = .{ .user_id = 1 },
        .render_buf = &render_buf,
    };

    const result = ctx.render(.{});
    try std.testing.expectEqual(@as(u8, 0), result.len);
    try std.testing.expectEqual(@as(u32, 0), result.buf_used);
    try std.testing.expectEqual(@as(usize, 0), result.slice().len);
}

test "HandlerContext exposes type aliases" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity);

    try std.testing.expect(Ctx.PrefetchType == Prefetch);
    try std.testing.expect(Ctx.BodyType == void);
    try std.testing.expect(Ctx.IdentityType == Identity);
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
    const Ctx = HandlerContext(Prefetch, void, MockIdentity);
    pub fn route(_: @import("http.zig").Method, _: []const u8, _: []const u8) ?MockMessage {
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn render(ctx: Ctx) effects.RenderResult {
        return ctx.render(.{});
    }
};

// Mutation handler — correct signatures for typed EventType.

const MockMutationHandler = struct {
    pub const Prefetch = struct { existing: ?u32 };
    const Ctx = HandlerContext(Prefetch, MockBody, MockIdentity);
    pub fn route(_: @import("http.zig").Method, _: []const u8, _: []const u8) ?MockMessage {
        return null;
    }
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn handle(_: Ctx) MockExecuteResult {
        return .{ .response = .{ .status = 1 }, .writes = .{0}, .writes_len = 0 };
    }
    pub fn render(ctx: Ctx) effects.RenderResult {
        return ctx.render(.{});
    }
};

test "ValidateHandler read-only" {
    const V = ValidateHandler(MockReadOnlyHandler, MockOp.get_thing, MockIdentity, MockMessage, MockExecuteResult);
    try std.testing.expect(V.is_read_only);
    try std.testing.expect(V.PrefetchType == MockReadOnlyHandler.Prefetch);
    try std.testing.expect(V.BodyType == void);
}

test "ValidateHandler mutation" {
    const V = ValidateHandler(MockMutationHandler, MockOp.create_thing, MockIdentity, MockMessage, MockExecuteResult);
    try std.testing.expect(!V.is_read_only);
    try std.testing.expect(V.BodyType == MockBody);
}
