const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { product: ?t.ProductRow };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.get_product_inventory), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.get_product_inventory, fuzz.pick_or_random_id(prng, pools.product_ids), prng.int(u128) | 1, {});
}

// [route] .get_product_inventory
// match GET /products/:id/inventory
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    return t.Message.init(.get_product_inventory, id, 0, {});
}

// [prefetch] .get_product_inventory
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .product = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_product_inventory
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
    const product = ctx.prefetched.product orelse
        return .{ .status = .not_found };
    if (!product.active) return .{ .status = .not_found };
    return .{};
}


// [render] .get_product_inventory
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .not_found => "Product not found",
        .ok => render_ok(ctx),
    };
}

fn render_ok(ctx: Context) []const u8 {
    const product = ctx.prefetched.product.?;
    var pos: usize = 0;
    pos += t.html.raw(ctx.render_buf[pos..], "inventory: ");
    pos += t.html.u32_decimal(ctx.render_buf[pos..], product.inventory);
    return ctx.render_buf[0..pos];
}
