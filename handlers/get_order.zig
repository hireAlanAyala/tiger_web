const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_order), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/orders/:id";

// [route] .get_order
// match GET /orders/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    _ = body;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    return t.Message.init(.get_order, id, 0, {});
}

// [prefetch] .get_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
    if (ctx.prefetched.order == null)
        return .{ .status = .not_found };
    return .{};
}


// [render] .get_order
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .not_found => "<div class=\"error\">Order not found</div>",
        .ok => "", // TODO: render order detail
    };
}
