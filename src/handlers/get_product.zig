const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found };

pub const Prefetch = struct {
    product: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.get_product), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.get_product, fuzz.pick_or_random_id(prng, pools.product_ids), prng.int(u128) | 1, {});
}

// [route] .get_product
// match GET /products/:id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    return t.Message.init(.get_product, id, 0, {});
}

// [prefetch] .get_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .product = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_product
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
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
