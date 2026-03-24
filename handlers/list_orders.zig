const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok };

pub const Prefetch = struct { orders: ?t.BoundedList(t.OrderRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_orders), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/orders";

// [route] .list_orders
// match GET /orders
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method; _ = body;
    if (t.match_route(raw_path, route_pattern) == null) return null;
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
    _ = ctx;
    // TODO: render order cards
    return "";
}
