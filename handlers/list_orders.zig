const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok };

pub const Prefetch = struct { orders: ?t.BoundedList(t.OrderRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_orders), t.Identity, Status);

// [route] .list_orders
// match GET /orders
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params; _ = body;
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
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .list_orders
pub fn render(ctx: Context) []const u8 {
    const h = t.html;
    var buf = ctx.render_buf;
    var pos: usize = 0;

    const orders = (ctx.prefetched.orders orelse return "").slice();
    if (orders.len == 0) return "<div>No orders</div>";

    for (orders) |order| {
        pos += h.raw(buf[pos..], "<div class=\"card\">Order <strong>");
        pos += h.uuid(buf[pos..], order.id);
        pos += h.raw(buf[pos..], "</strong> &mdash; ");
        pos += h.raw(buf[pos..], switch (order.status) {
            .pending => "Pending",
            .confirmed => "Confirmed",
            .failed => "Failed",
            .cancelled => "Cancelled",
        });
        pos += h.raw(buf[pos..], " &mdash; ");
        pos += h.price_u64(buf[pos..], order.total_cents);
        pos += h.raw(buf[pos..], "</div>");
    }

    return buf[0..pos];
}
