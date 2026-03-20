const std = @import("std");
const assert = std.debug.assert;
const fw = @import("tiger_framework");
const http = fw.http;
const parse = fw.parse;
const effects = fw.effects;
const handler = fw.handler;
const message = @import("../message.zig");
const Storage = @import("../storage.zig").SqliteStorage;

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
        // Not found — patch error message.
        return ctx.render(.{
            .{ "patch", "#content", @as([]const u8, "<div class=\"error\">Product not found</div>"), "inner" },
        });
    };

    if (!product.active) {
        return ctx.render(.{
            .{ "patch", "#content", @as([]const u8, "<div class=\"error\">Product not found</div>"), "inner" },
        });
    }

    // Build product card HTML into the render buffer.
    var card_buf: [2048]u8 = undefined;
    const card_html = render_product_card(&card_buf, &product);

    return ctx.render(.{
        .{ "patch", "#content", card_html, "inner" },
    });
}

/// Render a product card into a buffer. Returns the written slice.
fn render_product_card(buf: []u8, p: *const ProductRow) []const u8 {
    var pos: usize = 0;

    pos += write(buf[pos..], "<div class=\"card\"><strong>");
    pos += write_escaped(buf[pos..], p.name[0..p.name_len]);
    pos += write(buf[pos..], "</strong> &mdash; $");
    pos += write_price(buf[pos..], p.price_cents);
    pos += write(buf[pos..], " &mdash; inv: ");
    pos += write_u32(buf[pos..], p.inventory);
    pos += write(buf[pos..], " &mdash; v");
    pos += write_u32(buf[pos..], p.version);

    if (!p.active) {
        pos += write(buf[pos..], " <span class=\"error\">[inactive]</span>");
    }

    pos += write(buf[pos..], "<div class=\"meta\">");
    pos += write_uuid(buf[pos..], p.id);
    pos += write(buf[pos..], "</div>");

    if (p.description_len > 0) {
        pos += write(buf[pos..], "<div class=\"meta\">");
        pos += write_escaped(buf[pos..], p.description[0..p.description_len]);
        pos += write(buf[pos..], "</div>");
    }

    pos += write(buf[pos..], "</div>");

    return buf[0..pos];
}

// --- Minimal HTML helpers (no HtmlWriter dependency) ---

fn write(buf: []u8, s: []const u8) usize {
    assert(s.len <= buf.len);
    @memcpy(buf[0..s.len], s);
    return s.len;
}

fn write_escaped(buf: []u8, s: []const u8) usize {
    var pos: usize = 0;
    for (s) |c| {
        switch (c) {
            '<' => pos += write(buf[pos..], "&lt;"),
            '>' => pos += write(buf[pos..], "&gt;"),
            '&' => pos += write(buf[pos..], "&amp;"),
            '"' => pos += write(buf[pos..], "&quot;"),
            else => {
                buf[pos] = c;
                pos += 1;
            },
        }
    }
    return pos;
}

fn write_u32(buf: []u8, val: u32) usize {
    var tmp: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&tmp, "{d}", .{val}) catch unreachable;
    return write(buf, s);
}

fn write_price(buf: []u8, cents: u32) usize {
    var pos: usize = 0;
    pos += write_u32(buf[pos..], cents / 100);
    pos += write(buf[pos..], ".");
    var frac_buf: [2]u8 = undefined;
    const frac = cents % 100;
    if (frac < 10) {
        frac_buf[0] = '0';
        frac_buf[1] = '0' + @as(u8, @intCast(frac));
    } else {
        frac_buf[0] = '0' + @as(u8, @intCast(frac / 10));
        frac_buf[1] = '0' + @as(u8, @intCast(frac % 10));
    }
    pos += write(buf[pos..], &frac_buf);
    return pos;
}

fn write_uuid(buf: []u8, id: u128) usize {
    const hex = "0123456789abcdef";
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(u128, &bytes, id, .big);
    var pos: usize = 0;
    for (bytes) |b| {
        buf[pos] = hex[b >> 4];
        buf[pos + 1] = hex[b & 0xf];
        pos += 2;
    }
    return pos; // 32 hex chars
}
