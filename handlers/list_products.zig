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
// query cursor
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    // Reject if ?q= is present — search_products handles filtered queries.
    // Both share GET /products; disambiguation by query param presence.
    if (params.get("q") != null) return null;
    var lp = std.mem.zeroes(t.ListParams);
    if (params.get("cursor")) |c| {
        lp.cursor = t.stdx.parse_uuid(c) orelse return null;
    }
    return t.Message.init(.list_products, 0, 0, lp);
}

// [prefetch] .list_products
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const params = msg.body_as(t.ListParams);
    if (params.cursor != 0) {
        return .{ .products = storage.query_all(t.ProductRow, t.list_max,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id > ?1 ORDER BY id LIMIT ?2;",
            .{ params.cursor, @as(u32, t.list_max) }) };
    }
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
    const items = products_list.slice();
    var pos: usize = 0;
    var visible: usize = 0;
    for (items) |*p| {
        if (!p.active) continue;
        const card = get_product.render_product_card(ctx.render_buf[pos..], p);
        pos += card.len;
        visible += 1;
    }
    if (pos == 0) return "<div class=\"meta\">No products</div>";

    // Cursor pagination: if we got a full page, append a sentinel that
    // triggers the next fetch when the user scrolls to it (Datastar
    // data-on-intersect). See docs/guide/pagination.md.
    if (items.len == t.list_max) {
        const last_id = items[items.len - 1].id;
        pos += t.html.raw(ctx.render_buf[pos..],
            "<div data-on-intersect=\"@get('/products?cursor=");
        pos += t.html.uuid(ctx.render_buf[pos..], last_id);
        pos += t.html.raw(ctx.render_buf[pos..], "')\"></div>");
    }

    return ctx.render_buf[0..pos];
}
