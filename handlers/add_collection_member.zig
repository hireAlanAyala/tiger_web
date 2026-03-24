const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct {
    collection_id: u128,
    product_id: u128,
    collection: ?t.CollectionRow,
    product: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.add_collection_member), t.Identity, Status);

// [route] .add_collection_member
// match POST /collections/:id/products/:sub_id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (!segments.has_id) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "products")) return null;
    if (!segments.has_sub_id) return null;
    return t.Message.init(.add_collection_member, segments.id, 0, segments.sub_id);
}

// [prefetch] .add_collection_member
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const product_id = msg.body_as(u128).*;
    return .{
        .collection_id = msg.id,
        .product_id = product_id,
        .collection = storage.query(t.CollectionRow,
            "SELECT id, name, active FROM collections WHERE id = ?1;", .{msg.id}),
        .product = storage.query(t.ProductRow,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
            .{product_id}),
    };
}

// [handle] .add_collection_member
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx.prefetched.collection orelse
        return .{ .status = .not_found };
    _ = ctx.prefetched.product orelse
        return .{ .status = .not_found };
    db.execute(
        t.sql.collection_members.upsert,
        .{ ctx.prefetched.collection_id, ctx.prefetched.product_id },
    );
    return .{};
}

// [render] .add_collection_member
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Collection or product not found</div>",
    };
}
