const std = @import("std");
const assert = std.debug.assert;
const fw = @import("tiger_framework");
const http = fw.http;
const parse = fw.parse;
const effects = fw.effects;
const handler = fw.handler;
const message = @import("../message.zig");
const Storage = @import("../storage.zig").SqliteStorage;
const html = @import("../html.zig");
const get_product = @import("get_product.zig");

pub const Prefetch = struct {
    products: Storage.BoundedList(get_product.ProductRow, message.list_max),
};

const Context = handler.HandlerContext(Prefetch, message.Operation.EventType(.list_products), message.PrefetchIdentity);

// [route] .list_products
pub fn route(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    // Split path from query string.
    const query_sep = std.mem.indexOf(u8, path, "?");
    const path_clean = if (query_sep) |q| path[0..q] else path;
    const query_string = if (query_sep) |q| path[q + 1 ..] else "";

    const segments = parse.split_path(path_clean) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (segments.has_id) return null; // GET /products, not /products/:id

    // Not a search (that's a different operation).
    if (parse.query_param(query_string, "q") != null) return null;

    const list_params = parse_list_params(query_string);
    return message.Message.init(.list_products, 0, 0, list_params);
}

// [prefetch] .list_products
pub fn prefetch(storage: *Storage, msg: *const message.Message) ?Prefetch {
    const params = msg.body_as(message.ListParams);
    const products = storage.query_all(
        get_product.ProductRow,
        message.list_max,
        "SELECT id, name, description, price_cents, inventory, version, description_len, name_len, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
        .{@as(u32, message.list_max)},
    ) orelse return null;
    _ = params; // TODO: apply cursor, price filters, active filter
    return .{ .products = products };
}

// [handle] .list_products

// [render] .list_products
pub fn render(ctx: Context) effects.RenderResult {
    var buf: [32 * 1024]u8 = undefined;
    var pos: usize = 0;

    for (ctx.prefetched.products.slice()) |*p| {
        if (!p.active) continue;
        pos += html.raw(buf[pos..], "<div class=\"card\"><strong>");
        pos += html.escaped(buf[pos..], p.name[0..p.name_len]);
        pos += html.raw(buf[pos..], "</strong> &mdash; ");
        pos += html.price(buf[pos..], p.price_cents);
        pos += html.raw(buf[pos..], " &mdash; inv: ");
        pos += html.u32_decimal(buf[pos..], p.inventory);
        pos += html.raw(buf[pos..], "</div>");
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

fn parse_list_params(query_string: []const u8) message.ListParams {
    _ = query_string;
    return std.mem.zeroes(message.ListParams);
}
