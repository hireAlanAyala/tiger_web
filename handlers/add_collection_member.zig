const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct {
    collection_id: u128,
    product_id: u128,
    collection: ?t.CollectionRow,
    product: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.add_collection_member), t.Identity);

// [route] .add_collection_member
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
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx.prefetched.collection orelse
        return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
    _ = ctx.prefetched.product orelse
        return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
    return t.ExecuteResult.single(
        t.HandlerResponse.ok,
        .{ .put_membership = .{ .collection_id = ctx.prefetched.collection_id, .product_id = ctx.prefetched.product_id } },
    );
}

// [render] .add_collection_member
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
