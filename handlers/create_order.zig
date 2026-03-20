const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");

pub const Prefetch = struct {
    products: [t.order_items_max]?t.Product,
    order_id: u128,
};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.create_order), t.Identity);

// [route] .create_order
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (segments.has_id) return null;
    if (body.len == 0) return null;
    // TODO: parse OrderRequest from JSON
    return null;
}

// [prefetch] .create_order
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    const order = msg.body_as(t.OrderRequest);
    var result = Prefetch{ .products = .{null} ** t.order_items_max, .order_id = order.id };
    for (order.items_slice(), 0..) |item, i| {
        result.products[i] = storage.query(t.Product,
            "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
            .{item.product_id});
    }
    return result;
}

// [handle] .create_order
pub fn handle(ctx: Context) t.ExecuteResult {
    // TODO: validate inventory, build order, decrement inventory
    _ = ctx;
    return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
}

// [render] .create_order
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
