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

pub const route_method = t.http.Method.post;
pub const route_pattern = "/collections/:id/products/:sub_id";

// [route] .add_collection_member
// match POST /collections/:id/products/:sub_id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    _ = body;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    const sub_id = t.stdx.parse_uuid(params.get("sub_id").?) orelse return null;
    return t.Message.init(.add_collection_member, id, 0, sub_id);
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
