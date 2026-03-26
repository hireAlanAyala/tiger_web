const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { collection_id: u128, product_id: u128, collection: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.remove_collection_member), t.Identity, Status);

// [route] .remove_collection_member
// match DELETE /collections/:id/products/:sub_id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    const sub_id = t.stdx.parse_uuid(params.get("sub_id") orelse return null) orelse return null;
    return t.Message.init(.remove_collection_member, id, 0, sub_id);
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
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx.prefetched.collection orelse
        return .{ .status = .not_found };
    db.execute(
        t.sql.collection_members.remove,
        .{ ctx.prefetched.collection_id, ctx.prefetched.product_id },
    );
    return .{};
}

// [render] .remove_collection_member
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Collection not found</div>",
    };
}
