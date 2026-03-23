const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Prefetch = struct {
    products: ?t.BoundedList(t.ProductRow, t.list_max),
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_products), t.Identity);

// [route] .list_products
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const query_sep = std.mem.indexOf(u8, path, "?");
    const path_clean = if (query_sep) |q| path[0..q] else path;
    const query_string = if (query_sep) |q| path[q + 1 ..] else "";

    const segments = t.parse.split_path(path_clean) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (segments.has_id) return null;
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

// [render] .list_products
pub fn render(ctx: Context) t.RenderResult {
    const products_list = ctx.prefetched.products orelse
        return ctx.render(.{ .{ "patch", "#product-list", "<div class=\"meta\">No products</div>", "inner" } });
    var buf: [32 * 1024]u8 = undefined;
    var pos: usize = 0;

    for (products_list.slice()) |*p| {
        if (!p.active) continue;
        const card = get_product.render_product_card(buf[pos..], p);
        pos += card.len;
    }

    if (pos == 0) return ctx.render(.{ .{ "patch", "#product-list", "<div class=\"meta\">No products</div>", "inner" } });
    return ctx.render(.{ .{ "patch", "#product-list", buf[0..pos], "inner" } });
}
