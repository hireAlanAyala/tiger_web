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
    return struct {
        prefetched: Prefetch,
        body: if (Body == void) void else *const Body,
        identity: Identity,

        pub const PrefetchType = Prefetch;
        pub const BodyType = Body;
        pub const IdentityType = Identity;

        /// Access body — asserts non-void at comptime.
        pub fn body_val(self: @This()) if (Body == void) @compileError("no body for void EventType") else *const Body {
            return self.body;
        }
    };
}

/// Validate that a handler module has the required interface.
///
/// Called at comptime by App() for each handler in the tuple.
/// Checks that the handler exports the right types and function signatures.
///
/// Returns a descriptor struct with resolved types for dispatch generation.
pub fn ValidateHandler(
    comptime handler: type,
    comptime operation: anytype,
    comptime Identity: type,
) type {
    // Handler must export a Prefetch type.
    if (!@hasDecl(handler, "Prefetch")) {
        @compileError("handler for ." ++ @tagName(operation) ++ " must export a Prefetch type");
    }
    const Prefetch = handler.Prefetch;

    // Handler must export a route function.
    if (!@hasDecl(handler, "route")) {
        @compileError("handler for ." ++ @tagName(operation) ++ " must export a route function");
    }

    // Handler must export a prefetch function.
    if (!@hasDecl(handler, "prefetch")) {
        @compileError("handler for ." ++ @tagName(operation) ++ " must export a prefetch function");
    }

    // Handler must export a render function.
    if (!@hasDecl(handler, "render")) {
        @compileError("handler for ." ++ @tagName(operation) ++ " must export a render function");
    }

    // Resolve the body type from the operation's EventType.
    const Body = operation.EventType();
    const Ctx = HandlerContext(Prefetch, Body, Identity);

    // Handle is optional — if missing, operation is read-only.
    const has_handle = @hasDecl(handler, "handle");

    // Validate prefetch return type is ?Prefetch.
    const prefetch_info = @typeInfo(@TypeOf(handler.prefetch));
    const PrefetchReturn = prefetch_info.@"fn".return_type orelse
        @compileError("handler for ." ++ @tagName(operation) ++ ": prefetch must have a return type");
    if (PrefetchReturn != ?Prefetch) {
        @compileError("handler for ." ++ @tagName(operation) ++ ": prefetch must return ?" ++ @typeName(Prefetch));
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

    const ctx = Ctx{
        .prefetched = .{ .product = 42 },
        .body = {},
        .identity = .{ .user_id = 1 },
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

    const ctx = Ctx{
        .prefetched = .{ .existing = null },
        .body = &body,
        .identity = .{ .user_id = 2 },
    };

    try std.testing.expectEqual(@as(?u32, null), ctx.prefetched.existing);
    try std.testing.expectEqual(@as(u8, 4), ctx.body_val().name_len);
}

test "HandlerContext exposes type aliases" {
    const Identity = struct { user_id: u128 };
    const Prefetch = struct { product: ?u32 };
    const Ctx = HandlerContext(Prefetch, void, Identity);

    try std.testing.expect(Ctx.PrefetchType == Prefetch);
    try std.testing.expect(Ctx.BodyType == void);
    try std.testing.expect(Ctx.IdentityType == Identity);
}

const MockIdentity = struct { user_id: u128 };

const MockReadOnlyHandler = struct {
    pub const Prefetch = struct { product: ?u32 };
    pub fn route() void {}
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn render() void {}
};

const MockMutationHandler = struct {
    pub const Prefetch = struct { existing: ?u32 };
    pub fn route() void {}
    pub fn prefetch() ?Prefetch {
        return null;
    }
    pub fn handle() void {}
    pub fn render() void {}
};

const MockVoidOp = struct {
    pub fn EventType() type {
        return void;
    }
};

const MockBodyOp = struct {
    const Body = struct { name: u8 };
    pub fn EventType() type {
        return Body;
    }
};

test "ValidateHandler read-only" {
    const V = ValidateHandler(MockReadOnlyHandler, MockVoidOp, MockIdentity);
    try std.testing.expect(V.is_read_only);
    try std.testing.expect(V.PrefetchType == MockReadOnlyHandler.Prefetch);
    try std.testing.expect(V.BodyType == void);
}

test "ValidateHandler mutation" {
    const V = ValidateHandler(MockMutationHandler, MockBodyOp, MockIdentity);
    try std.testing.expect(!V.is_read_only);
    try std.testing.expect(V.BodyType == MockBodyOp.Body);
}
