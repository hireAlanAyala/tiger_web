const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { order_id: u128 };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.complete_order), t.Identity);

// [route] .complete_order
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (!segments.has_id) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "complete")) return null;
    if (body.len == 0) return null;
    // TODO: parse OrderCompletion from JSON
    return null;
}

// [prefetch] .complete_order
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    _ = storage;
    return .{ .order_id = msg.id };
}

// [handle] .complete_order
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
}

// [render] .complete_order
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
