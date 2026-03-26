const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Status = enum { ok };

pub const Prefetch = struct { products: ?t.BoundedList(t.ProductRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.search_products), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/products/search";

// [route] .search_products
// match GET /products/search
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method; _ = body;
    if (t.match_route(raw_path, route_pattern) == null) return null;

    // Extract ?q= query param from the full path.
    const query_sep = std.mem.indexOf(u8, raw_path, "?");
    const query_string = if (query_sep) |q| raw_path[q + 1 ..] else "";
    const q = t.parse.query_param(query_string, "q") orelse return null;
    if (q.len == 0 or q.len > @import("../message.zig").search_query_max) return null;

    var sq = std.mem.zeroes(t.SearchQuery);
    @memcpy(sq.query[0..q.len], q);
    sq.query_len = @intCast(q.len);
    return t.Message.init(.search_products, 0, 0, sq);
}

// [prefetch] .search_products
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{ .products = storage.query_all(t.ProductRow, t.list_max,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .search_products
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .search_products
pub fn render(ctx: Context) []const u8 {
    const products_list = ctx.prefetched.products orelse
        return "<div class=\"meta\">No results</div>";
    var pos: usize = 0;
    for (products_list.slice()) |*p| {
        if (!p.active) continue;
        const card = get_product.render_product_card(ctx.render_buf[pos..], p);
        pos += card.len;
    }
    if (pos == 0) return "<div class=\"meta\">No results</div>";
    return ctx.render_buf[0..pos];
}
