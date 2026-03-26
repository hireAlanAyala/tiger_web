const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Status = enum { ok };

pub const Prefetch = struct {
    products: ?t.BoundedList(t.ProductRow, t.list_max),
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_products), t.Identity, Status);

// [route] .list_products
// match GET /products
// query q
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    // Reject if ?q= is present — search_products handles filtered queries.
    // Both share GET /products; disambiguation by query param presence.
    if (params.get("q") != null) return null;
    return t.Message.init(.list_products, 0, 0, std.mem.zeroes(t.ListParams));
}

// [prefetch] .list_products
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{ .products = storage.query_all(t.ProductRow, t.list_max,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .list_products
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .list_products
pub fn render(ctx: Context) []const u8 {
    const products_list = ctx.prefetched.products orelse
        return "<div class=\"meta\">No products</div>";
    var pos: usize = 0;
    for (products_list.slice()) |*p| {
        if (!p.active) continue;
        const card = get_product.render_product_card(ctx.render_buf[pos..], p);
        pos += card.len;
    }
    if (pos == 0) return "<div class=\"meta\">No products</div>";
    return ctx.render_buf[0..pos];
}
