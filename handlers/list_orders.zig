const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { orders: t.BoundedList(t.OrderSummary, t.list_max) };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_orders), t.Identity);

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
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    // TODO: query orders table
    return .{ .orders = .{} };
}

// [handle] .list_orders

// [render] .list_orders
pub fn render(ctx: Context) t.RenderResult {
    if (ctx.prefetched.orders.len == 0)
        return ctx.render(.{ .{ "patch", "#order-list", "<div class=\"meta\">No orders</div>", "inner" } });
    return ctx.render(.{}); // TODO: render order cards
}
