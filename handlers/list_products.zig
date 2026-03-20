const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Prefetch = struct {
    products: t.BoundedList(t.Product, t.list_max),
};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_products), t.Identity);

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

    const list_params = parse_list_params(query_string);
    return t.Message.init(.list_products, 0, 0, list_params);
}

// [prefetch] .list_products
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    _ = msg;
    const products = storage.query_all(
        t.Product,
        t.list_max,
        "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)},
    ) orelse return null;
    return .{ .products = products };
}

// [handle] .list_products

// [render] .list_products
pub fn render(ctx: Context) t.RenderResult {
    var buf: [32 * 1024]u8 = undefined;
    var pos: usize = 0;

    for (ctx.prefetched.products.slice()) |*p| {
        if (!p.flags.active) continue;
        const card = get_product.render_product_card(buf[pos..], p);
        pos += card.len;
    }

    if (pos == 0) {
        return ctx.render(.{
            .{ "patch", "#product-list", @as([]const u8, "<div class=\"meta\">No products</div>"), "inner" },
        });
    }

    return ctx.render(.{
        .{ "patch", "#product-list", buf[0..pos], "inner" },
    });
}

fn parse_list_params(query_string: []const u8) t.ListParams {
    _ = query_string;
    return std.mem.zeroes(t.ListParams);
}
