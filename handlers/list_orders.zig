const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { orders: ?t.BoundedList(t.OrderRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_orders), t.Identity);

// [route] .list_orders
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (segments.has_id) return null;
    return t.Message.init(.list_orders, 0, 0, std.mem.zeroes(t.ListParams));
}

// [prefetch] .list_orders
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{ .orders = storage.query_all(t.OrderRow, t.list_max,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .list_orders
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}


// [render] .list_orders
pub fn render(ctx: Context) t.RenderResult {
    const orders = ctx.prefetched.orders orelse
        return ctx.render(.{ .{ "patch", "#order-list", "<div class=\"meta\">No orders</div>", "inner" } });
    if (orders.len == 0)
        return ctx.render(.{ .{ "patch", "#order-list", "<div class=\"meta\">No orders</div>", "inner" } });
    return ctx.render(.{}); // TODO: render order cards
}
