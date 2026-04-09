const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct {
    products: ?t.BoundedList(t.ProductRow, t.list_max),
    collections: ?t.BoundedList(t.CollectionRow, t.list_max),
    orders: ?t.BoundedList(t.OrderRow, t.list_max),
};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.page_load_dashboard), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    return t.Message.init(.page_load_dashboard, 0, prng.int(u128) | 1, {});
}

// [route] .page_load_dashboard
// match GET /
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params; _ = body;
    return t.Message.init(.page_load_dashboard, 0, 0, {});
}

// [prefetch] .page_load_dashboard
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{
        .products = storage.query_all(t.ProductRow, t.list_max,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
        .collections = storage.query_all(t.CollectionRow, t.list_max,
            "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
        .orders = storage.query_all(t.OrderRow, t.list_max,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
    };
}

// [handle] .page_load_dashboard
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .page_load_dashboard
pub fn render(ctx: Context) []const u8 {
    const h = t.html;
    var buf = ctx.render_buf;
    var pos: usize = 0;

    // --- Page shell ---
    pos += h.raw(buf[pos..],
        \\<!DOCTYPE html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>Tiger Web</title>
        \\<script type="module" src="https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js"></script>
        \\<style>
        \\* { box-sizing: border-box; margin: 0; padding: 0; }
        \\body { font-family: system-ui, sans-serif; background: #f5f5f5; color: #333; padding: 20px; }
        \\h1 { margin-bottom: 16px; font-size: 22px; }
        \\h2 { margin: 20px 0 8px; font-size: 16px; border-bottom: 1px solid #ccc; padding-bottom: 4px; }
        \\.card { background: #fff; border: 1px solid #ddd; border-radius: 4px; padding: 12px; margin: 8px 0; }
        \\.card .meta { font-size: 12px; color: #888; }
        \\.error { color: #f44; }
        \\table { border-collapse: collapse; width: 100%; }
        \\th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid #eee; font-size: 13px; }
        \\th { background: #f0f0f0; }
        \\section { margin-bottom: 24px; }
        \\.cols { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; }
        \\@media (max-width: 800px) { .cols { grid-template-columns: 1fr; } }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>Tiger Web</h1>
        \\<div class="cols">
        \\<div>
        \\
    );

    // --- Products section ---
    pos += h.raw(buf[pos..], "<section>\n<h2>Products</h2>\n<div id=\"product-list\">\n");
    if (ctx.prefetched.products) |products| {
        if (products.len == 0) {
            pos += h.raw(buf[pos..], "<div class=\"card\">No products</div>");
        } else {
            for (products.slice()) |*p| {
                pos += get_product.render_product_card(buf[pos..], p).len;
            }
        }
    } else {
        pos += h.raw(buf[pos..], "<div class=\"card\">No products</div>");
    }
    pos += h.raw(buf[pos..], "</div>\n</section>\n\n");

    pos += h.raw(buf[pos..], "</div>\n<div>\n\n");

    // --- Collections section ---
    pos += h.raw(buf[pos..], "<section>\n<h2>Collections</h2>\n<div id=\"collection-list\">\n");
    if (ctx.prefetched.collections) |collections| {
        if (collections.len == 0) {
            pos += h.raw(buf[pos..], "<div class=\"card\">No collections</div>");
        } else {
            for (collections.slice()) |*col| {
                pos += h.raw(buf[pos..], "<div class=\"card\"><strong>");
                pos += h.escaped(buf[pos..], std.mem.sliceTo(&col.name, 0));
                pos += h.raw(buf[pos..], "</strong><div class=\"meta\">");
                pos += h.uuid(buf[pos..], col.id);
                pos += h.raw(buf[pos..], "</div></div>");
            }
        }
    } else {
        pos += h.raw(buf[pos..], "<div class=\"card\">No collections</div>");
    }
    pos += h.raw(buf[pos..], "</div>\n</section>\n\n");

    // --- Orders section ---
    pos += h.raw(buf[pos..], "<section>\n<h2>Orders</h2>\n<div id=\"order-list\">\n");
    if (ctx.prefetched.orders) |orders| {
        if (orders.len == 0) {
            pos += h.raw(buf[pos..], "<div class=\"card\">No orders</div>");
        } else {
            for (orders.slice()) |*o| {
                pos += h.raw(buf[pos..], "<div class=\"card\">Order <strong>");
                pos += h.short_uuid(buf[pos..], o.id);
                pos += h.raw(buf[pos..], "...</strong> &mdash; ");
                pos += h.raw(buf[pos..], switch (o.status) {
                    .pending => "Pending",
                    .confirmed => "Confirmed",
                    .failed => "Failed",
                    .cancelled => "Cancelled",
                });
                pos += h.raw(buf[pos..], " &mdash; ");
                pos += h.price_u64(buf[pos..], o.total_cents);
                pos += h.raw(buf[pos..], " &mdash; ");
                pos += h.u8_decimal(buf[pos..], o.items_len);
                pos += h.raw(buf[pos..], " items</div>");
            }
        }
    } else {
        pos += h.raw(buf[pos..], "<div class=\"card\">No orders</div>");
    }
    pos += h.raw(buf[pos..], "</div>\n</section>\n\n");

    pos += h.raw(buf[pos..], "</div>\n</div>\n</body>\n</html>\n");

    return buf[0..pos];
}
