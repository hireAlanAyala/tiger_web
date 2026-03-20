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

pub const Prefetch = struct {
    product: ?ProductRow,
};

/// Product fields for display. Column order must match the SELECT in prefetch.
pub const ProductRow = struct {
    id: u128,
    name: [message.product_name_max]u8,
    description: [message.product_description_max]u8,
    price_cents: u32,
    inventory: u32,
    version: u32,
    description_len: u16,
    name_len: u8,
    active: bool,
};

const Context = handler.HandlerContext(Prefetch, message.Operation.EventType(.get_product), message.PrefetchIdentity);

// [route] .get_product
pub fn route(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const segments = parse.split_path(path) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;

    return message.Message.init(.get_product, segments.id, 0, {});
}

// [prefetch] .get_product
pub fn prefetch(storage: *Storage, msg: *const message.Message) ?Prefetch {
    const row = storage.query(
        ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.id},
    );
    return .{ .product = row };
}

// [handle] .get_product

// [render] .get_product
pub fn render(ctx: Context) effects.RenderResult {
    const product = ctx.prefetched.product orelse {
        return ctx.render(.{
            .{ "patch", "#content", @as([]const u8, "<div class=\"error\">Product not found</div>"), "inner" },
        });
    };

    if (!product.active) {
        return ctx.render(.{
            .{ "patch", "#content", @as([]const u8, "<div class=\"error\">Product not found</div>"), "inner" },
        });
    }

    var card_buf: [2048]u8 = undefined;
    const card_html = render_product_card(&card_buf, &product);

    return ctx.render(.{
        .{ "patch", "#content", card_html, "inner" },
    });
}

fn render_product_card(buf: []u8, p: *const ProductRow) []const u8 {
    var pos: usize = 0;
    pos += html.raw(buf[pos..], "<div class=\"card\"><strong>");
    pos += html.escaped(buf[pos..], p.name[0..p.name_len]);
    pos += html.raw(buf[pos..], "</strong> &mdash; ");
    pos += html.price(buf[pos..], p.price_cents);
    pos += html.raw(buf[pos..], " &mdash; inv: ");
    pos += html.u32_decimal(buf[pos..], p.inventory);
    pos += html.raw(buf[pos..], " &mdash; v");
    pos += html.u32_decimal(buf[pos..], p.version);

    if (!p.active) {
        pos += html.raw(buf[pos..], " <span class=\"error\">[inactive]</span>");
    }

    pos += html.raw(buf[pos..], "<div class=\"meta\">");
    pos += html.uuid(buf[pos..], p.id);
    pos += html.raw(buf[pos..], "</div>");

    if (p.description_len > 0) {
        pos += html.raw(buf[pos..], "<div class=\"meta\">");
        pos += html.escaped(buf[pos..], p.description[0..p.description_len]);
        pos += html.raw(buf[pos..], "</div>");
    }

    pos += html.raw(buf[pos..], "</div>");
    return buf[0..pos];
}
