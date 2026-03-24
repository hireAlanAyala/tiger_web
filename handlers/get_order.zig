const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_order), t.Identity, t.Status);

// [route] .get_order
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;
    return t.Message.init(.get_order, segments.id, 0, {});
}

// [prefetch] .get_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_order
pub fn handle(ctx: Context) t.ExecuteResult {
    if (ctx.prefetched.order == null)
        return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}


// [render] .get_order
pub fn render(ctx: Context) []const u8 {
    _ = ctx.prefetched.order orelse return "<div class=\"error\">Order not found</div>";
    return ""; // TODO: render order detail
}
