const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found, order_not_pending };

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.cancel_order), t.Identity, Status);

pub const route_method = t.http.Method.post;
pub const route_pattern = "/orders/:id/cancel";

// [route] .cancel_order
// match POST /orders/:id/cancel
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    _ = body;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    return t.Message.init(.cancel_order, id, 0, {});
}

// [prefetch] .cancel_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .cancel_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const order = ctx.prefetched.order orelse return .{ .status = .not_found };
    if (order.status != .pending) return .{ .status = .order_not_pending };
    db.execute(t.sql.orders.update_status, .{ order.id, @intFromEnum(t.OrderStatus.cancelled) });
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
