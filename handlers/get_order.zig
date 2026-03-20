const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { order: ?t.OrderResult };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_order), t.Identity);

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
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    // TODO: query order from orders table. For now use typed method.
    _ = storage;
    _ = msg;
    return .{ .order = null };
}

// [handle] .get_order

// [render] .get_order
pub fn render(ctx: Context) t.RenderResult {
    _ = ctx.prefetched.order orelse
        return ctx.render(.{ .{ "patch", "#content", "Order not found", "inner" } });
    return ctx.render(.{}); // TODO: render order detail
}
