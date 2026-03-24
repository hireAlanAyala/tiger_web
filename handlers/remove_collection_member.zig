const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { collection_id: u128, product_id: u128, collection: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.remove_collection_member), t.Identity, Status);

// [route] .remove_collection_member
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .delete) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (!segments.has_id) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "products")) return null;
    if (!segments.has_sub_id) return null;
    return t.Message.init(.remove_collection_member, segments.id, 0, segments.sub_id);
}

// [prefetch] .remove_collection_member
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{
        .collection_id = msg.id,
        .product_id = msg.body_as(u128).*,
        .collection = storage.query(t.CollectionRow,
            "SELECT id, name, active FROM collections WHERE id = ?1;", .{msg.id}),
    };
}

// [handle] .remove_collection_member
pub fn handle(ctx: Context, writes: *t.WriteQueue) t.HandleResult {
    _ = ctx.prefetched.collection orelse
        return .{ .status = .not_found };
    writes.add(.{ .update_membership = .{
        .collection_id = ctx.prefetched.collection_id,
        .product_id = ctx.prefetched.product_id,
        .removed = 1,
        .reserved = .{0} ** 15,
    } });
    return .{};
}

// [render] .remove_collection_member
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Collection not found</div>",
    };
}
