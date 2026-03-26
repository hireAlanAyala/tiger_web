const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found, order_not_pending };

pub const Prefetch = struct {
    order: ?t.OrderRow,
    items: ?t.BoundedList(t.OrderItemRow, t.order_items_max),
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.cancel_order), t.Identity, Status);

// [route] .cancel_order
// match POST /orders/:id/cancel
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    return t.Message.init(.cancel_order, id, 0, {});
}

// [prefetch] .cancel_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{
        .order = storage.query(t.OrderRow,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
            .{msg.id}),
        .items = storage.query_all(t.OrderItemRow, t.order_items_max,
            "SELECT product_id, name, quantity, price_cents, line_total_cents FROM order_items WHERE order_id = ?1;",
            .{msg.id}),
    };
}

// [handle] .cancel_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const order = ctx.prefetched.order orelse return .{ .status = .not_found };
    if (order.status != .pending) return .{ .status = .order_not_pending };

    db.execute(t.sql.orders.update_status, .{ order.id, @intFromEnum(t.OrderStatus.cancelled) });

    // Restore reserved inventory for each order item.
    const items = ctx.prefetched.items orelse return .{};
    for (items.slice()) |item| {
        db.execute(
            "UPDATE products SET inventory = inventory + ?2 WHERE id = ?1;",
            .{ item.product_id, item.quantity },
        );
    }
    return .{};
}

// [render] .cancel_order
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "<div>Order cancelled</div>",
        .not_found => "<div class=\"error\">Order not found</div>",
        .order_not_pending => "<div class=\"error\">Order is not pending</div>",
    };
}
