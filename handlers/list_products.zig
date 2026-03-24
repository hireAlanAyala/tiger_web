const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Status = enum { ok };

pub const Prefetch = struct {
    products: ?t.BoundedList(t.ProductRow, t.list_max),
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_products), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/products";

// [route] .list_products
// match GET /products
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method; _ = body;
    if (t.match_route(raw_path, route_pattern) == null) return null;

    // Reject if query string contains ?q= (handled by search_products).
    const query_sep = std.mem.indexOf(u8, raw_path, "?");
    const query_string = if (query_sep) |q| raw_path[q + 1 ..] else "";
    if (t.parse.query_param(query_string, "q") != null) return null;

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
