const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { product: ?t.ProductRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_product_inventory), t.Identity);

// [route] .get_product_inventory
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "inventory")) return null;
    return t.Message.init(.get_product_inventory, segments.id, 0, {});
}

// [prefetch] .get_product_inventory
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .product = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_product_inventory
pub fn handle(ctx: Context) t.ExecuteResult {
    const product = ctx.prefetched.product orelse
        return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
    if (!product.active) return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}


// [render] .get_product_inventory
pub fn render(ctx: Context) t.RenderResult {
    const product = ctx.prefetched.product orelse
        return ctx.render(.{ .{ "patch", "#content", "Product not found", "inner" } });
    if (!product.active)
        return ctx.render(.{ .{ "patch", "#content", "Product not found", "inner" } });
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos += t.html.raw(buf[pos..], "inventory: ");
    pos += t.html.u32_decimal(buf[pos..], product.inventory);
    return ctx.render(.{ .{ "patch", "#inventory", buf[0..pos], "inner" } });
}
