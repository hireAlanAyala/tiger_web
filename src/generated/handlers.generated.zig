// Handler dispatch and PrefetchCache for the unified pipeline.
//
// Comptime dispatch: the per-operation import table is explicit (Zig
// requires string literals for @import), but the dispatch functions
// use `inline else` — no per-operation switch arms to maintain.
//
// When adding a new native Operation: add it to handler_imports and
// ensure a handlers/{name}.zig file exists. The dispatch functions
// and PrefetchCache auto-derive from the import table.
//
// When adding a sidecar-only Operation: add it to is_sidecar_operation.

const std = @import("std");
const message = @import("../message.zig");
const state_machine = @import("../state_machine.zig");

const Operation = message.Operation;
const Message = message.Message;
const Status = message.Status;

/// Returns true if the operation is handled by a sidecar runtime (not native Zig).
/// Derived at comptime: if the operation has no entry in handler_imports, it's sidecar-only.
pub fn is_sidecar_operation(comptime op: Operation) bool {
    if (op == .root) return true;
    return !@hasDecl(handler_imports, @tagName(op));
}

/// Per-operation handler imports. Zig requires string literals for @import,
/// so this table is explicit. But the dispatch functions below use
/// `inline else` with this table — no per-operation switch arms.
/// Sidecar-only operations are NOT listed here — is_sidecar_operation
/// auto-derives from the absence of an import.
const handler_imports = struct {
    const create_product = @import("../handlers/create_product.zig");
    const get_product = @import("../handlers/get_product.zig");
    const list_products = @import("../handlers/list_products.zig");
    const update_product = @import("../handlers/update_product.zig");
    const delete_product = @import("../handlers/delete_product.zig");
    const get_product_inventory = @import("../handlers/get_product_inventory.zig");
    const transfer_inventory = @import("../handlers/transfer_inventory.zig");
    const create_order = @import("../handlers/create_order.zig");
    const get_order = @import("../handlers/get_order.zig");
    const list_orders = @import("../handlers/list_orders.zig");
    const complete_order = @import("../handlers/complete_order.zig");
    const cancel_order = @import("../handlers/cancel_order.zig");
    const search_products = @import("../handlers/search_products.zig");
    const create_collection = @import("../handlers/create_collection.zig");
    const get_collection = @import("../handlers/get_collection.zig");
    const list_collections = @import("../handlers/list_collections.zig");
    const delete_collection = @import("../handlers/delete_collection.zig");
    const add_collection_member = @import("../handlers/add_collection_member.zig");
    const remove_collection_member = @import("../handlers/remove_collection_member.zig");
    const page_load_dashboard = @import("../handlers/page_load_dashboard.zig");
    const page_load_login = @import("../handlers/page_load_login.zig");
    const request_login_code = @import("../handlers/request_login_code.zig");
    const verify_login_code = @import("../handlers/verify_login_code.zig");
    const logout = @import("../handlers/logout.zig");
};

/// Resolve the handler module for an operation at comptime.
pub fn HandlerModule(comptime op: Operation) type {
    if (comptime is_sidecar_operation(op)) return void;
    return @field(handler_imports, @tagName(op));
}

/// PrefetchCache — tagged union of handler Prefetch types.
pub const PrefetchCache = blk: {
    const fields = @typeInfo(Operation).@"enum".fields;
    var union_fields: [fields.len]std.builtin.Type.UnionField = undefined;
    for (fields, 0..) |f, i| {
        const op: Operation = @enumFromInt(f.value);
        const H = HandlerModule(op);
        union_fields[i] = .{
            .name = f.name,
            .type = if (H == void) void else H.Prefetch,
            .alignment = 0,
        };
    }
    break :blk @Type(.{
        .@"union" = .{
            .layout = .auto,
            .tag_type = Operation,
            .fields = &union_fields,
            .decls = &.{},
        },
    });
};

/// Phase 1: dispatch to handler.prefetch().
pub fn dispatch_prefetch(ro: anytype, msg: *const Message) ?PrefetchCache {
    return switch (msg.operation) {
        inline else => |comptime_op| {
            const H = comptime HandlerModule(comptime_op);
            if (H == void) unreachable;
            const result = H.prefetch(ro, msg) orelse return null;
            return @unionInit(PrefetchCache, @tagName(comptime_op), result);
        },
    };
}

/// Phase 2: dispatch to handler.handle().
pub fn dispatch_execute(
    cache: PrefetchCache,
    msg: Message,
    fw: anytype,
    db: anytype,
) state_machine.HandleResult {
    return switch (msg.operation) {
        inline else => |comptime_op| {
            const H = comptime HandlerModule(comptime_op);
            if (H == void) unreachable;
            const prefetched = @field(cache, @tagName(comptime_op));
            const ctx = H.Context{
                .prefetched = prefetched,
                .body = if (H.Context.BodyType == void) {} else msg.body_as(H.Context.BodyType),
                .fw = fw,
                .render_buf = &.{},
            };
            return H.handle(ctx, db);
        },
    };
}

/// Phase 3: dispatch to handler.render().
pub fn dispatch_render(
    cache: PrefetchCache,
    operation: Operation,
    status: Status,
    fw: anytype,
    render_buf: []u8,
    storage: anytype,
) []const u8 {
    return switch (operation) {
        inline else => |comptime_op| {
            const H = comptime HandlerModule(comptime_op);
            if (H == void) unreachable;
            const prefetched = @field(cache, @tagName(comptime_op));
            const HandlerStatus = H.Context.StatusType;
            const ctx = H.Context{
                .prefetched = prefetched,
                .body = if (H.Context.BodyType == void) {} else undefined,
                .fw = fw,
                .render_buf = render_buf,
                .status = map_status(HandlerStatus, status),
            };
            const render_fn_info = @typeInfo(@TypeOf(H.render)).@"fn";
            if (render_fn_info.params.len >= 2) {
                return H.render(ctx, storage);
            } else {
                return H.render(ctx);
            }
        },
    };
}

// Comptime safety: every native handler must export input_valid and
// gen_fuzz_message. Without these, the fuzzer silently falls through
// to the else arm and sends void-body messages to typed handlers.
// This restores the exhaustive safety that per-operation switches provided.
comptime {
    for (@typeInfo(Operation).@"enum".fields) |f| {
        const op: Operation = @enumFromInt(f.value);
        if (is_sidecar_operation(op)) continue;
        const H = HandlerModule(op);
        // Handlers with struct body types need input_valid for field validation.
        // Void and primitive bodies (u128) have nothing to validate.
        if (@hasDecl(H, "Context")) {
            const BT = H.Context.BodyType;
            if (BT != void and @typeInfo(BT) == .@"struct") {
                if (!@hasDecl(H, "input_valid"))
                    @compileError("native handler '" ++ f.name ++ "' must export pub fn input_valid");
            }
        }
        if (!@hasDecl(H, "gen_fuzz_message"))
            @compileError("native handler '" ++ f.name ++ "' must export pub fn gen_fuzz_message");
    }
}

fn map_status(comptime HandlerStatus: type, status: Status) HandlerStatus {
    if (HandlerStatus == Status) return status;
    const status_name = @tagName(status);
    inline for (@typeInfo(HandlerStatus).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, status_name)) {
            return @enumFromInt(f.value);
        }
    }
    unreachable;
}
