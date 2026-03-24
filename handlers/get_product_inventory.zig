const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { product: ?t.ProductRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_product_inventory), t.Identity, Status);

// [route] .get_product_inventory
// match GET /products/:id/inventory
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
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
    const product = ctx.prefetched.product orelse
        return .{ .status = .not_found };
    if (!product.active) return .{ .status = .not_found };
    return .{};
}


// [render] .get_product_inventory
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .not_found => "Product not found",
        .ok => render_ok(ctx),
    };
}

fn render_ok(ctx: Context) []const u8 {
    const product = ctx.prefetched.product.?;
    var pos: usize = 0;
    pos += t.html.raw(ctx.render_buf[pos..], "inventory: ");
    pos += t.html.u32_decimal(ctx.render_buf[pos..], product.inventory);
    return ctx.render_buf[0..pos];
}
