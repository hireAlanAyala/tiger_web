const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { existing: ?t.ProductCollection };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.delete_collection), t.Identity);

// [route] .delete_collection
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .delete) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;
    return t.Message.init(.delete_collection, segments.id, 0, {});
}

// [prefetch] .delete_collection
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.ProductCollection,
        "SELECT id, name, active, name_len FROM product_collections WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .delete_collection
pub fn handle(ctx: Context) t.ExecuteResult {
    var col = ctx.prefetched.existing orelse
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    if (!col.flags.active)
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    col.flags.active = false;
    return t.ExecuteResult.single(
        .{ .status = .ok, .result = .{ .empty = {} } },
        .{ .update_collection = col },
    );
}

// [render] .delete_collection
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
