const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Status = enum { ok };

pub const Prefetch = struct { products: ?t.BoundedList(t.ProductRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.search_products), t.Identity, Status);

// [route] .search_products
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
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 ORDER BY id;",
        .{}) };
}

// [handle] .search_products
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(.ok);
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
