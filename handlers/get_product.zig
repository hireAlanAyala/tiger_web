const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct {
    product: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_product), t.Identity, Status);

// [route] .get_product
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const segments = t.parse.split_path(path) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;

    return t.Message.init(.get_product, segments.id, 0, {});
}

// [prefetch] .get_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .product = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_product
pub fn handle(ctx: Context, writes: *t.WriteQueue) t.HandleResult {
    _ = writes;
    if (ctx.prefetched.product == null)
        return .{ .status = .not_found };
    if (!ctx.prefetched.product.?.active)
        return .{ .status = .not_found };
    return .{};
}

// [render] .get_product
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => render_product_card(ctx.render_buf, &ctx.prefetched.product.?),
        .not_found => "<div class=\"error\">Product not found</div>",
    };
}

pub fn render_product_card(buf: []u8, p: *const t.ProductRow) []const u8 {
    var pos: usize = 0;
    pos += t.html.raw(buf[pos..], "<div class=\"card\"><strong>");
    pos += t.html.escaped(buf[pos..], std.mem.sliceTo(&p.name, 0));
    pos += t.html.raw(buf[pos..], "</strong> &mdash; ");
    pos += t.html.price(buf[pos..], p.price_cents);
    pos += t.html.raw(buf[pos..], " &mdash; inv: ");
    pos += t.html.u32_decimal(buf[pos..], p.inventory);
    pos += t.html.raw(buf[pos..], " &mdash; v");
    pos += t.html.u32_decimal(buf[pos..], p.version);

    if (!p.active) {
        pos += t.html.raw(buf[pos..], " <span class=\"error\">[inactive]</span>");
    }

    pos += t.html.raw(buf[pos..], "<div class=\"meta\">");
    pos += t.html.uuid(buf[pos..], p.id);
    pos += t.html.raw(buf[pos..], "</div>");

    const desc = std.mem.sliceTo(&p.description, 0);
    if (desc.len > 0) {
        pos += t.html.raw(buf[pos..], "<div class=\"meta\">");
        pos += t.html.escaped(buf[pos..], desc);
        pos += t.html.raw(buf[pos..], "</div>");
    }

    pos += t.html.raw(buf[pos..], "</div>");
    return buf[0..pos];
}
