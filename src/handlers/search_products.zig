const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct { products: ?t.BoundedList(t.ProductRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.search_products), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.search_products, 0, prng.int(u128) | 1, fuzz.gen_search_query(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const msg_mod = @import("../message.zig");
    const sq = msg.body_as(msg_mod.SearchQuery);
    if (sq.query_len == 0 or sq.query_len > msg_mod.search_query_max) return false;
    if (!@import("std").unicode.utf8ValidateSlice(sq.query[0..sq.query_len])) return false;
    for (sq.query[0..sq.query_len]) |b| {
        if (b == 0) return false;
    }
    return true;
}

// [route] .search_products
// match GET /products
// query q
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const q = params.get("q") orelse return null;
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
