const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");
const message = @import("../message.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found, insufficient_inventory };

pub const Prefetch = struct {
    products: [t.order_items_max]?t.ProductRow,
    order_id: u128,
};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.create_order), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    if (pools.product_ids.len == 0) return null;
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.create_order, 0, prng.int(u128) | 1, fuzz.gen_order(prng, pools.product_ids));
}

pub fn input_valid(msg: t.Message) bool {
    const order = msg.body_as(t.OrderRequest);
    if (order.id == 0) return false;
    if (msg.id != 0 and msg.id != order.id) return false;
    if (order.items_len == 0) return false;
    if (order.items_len > t.order_items_max) return false;
    for (order.items_slice()) |item| {
        if (item.product_id == 0) return false;
        if (item.quantity == 0) return false;
    }
    return true;
}

// [route] .create_order
// match POST /orders
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params;
    if (body.len == 0) return null;
    const order = parse_order_json(body) orelse return null;
    return t.Message.init(.create_order, order.id, 0, order);
}

// [prefetch] .create_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const order = msg.body_as(t.OrderRequest);
    var result = Prefetch{ .products = .{null} ** t.order_items_max, .order_id = order.id };
    for (order.items_slice(), 0..) |item, i| {
        result.products[i] = storage.query(t.ProductRow,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
            .{item.product_id});
    }
    return result;
}

// [handle] .create_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const order = ctx.body_val();

    // Validate all products exist.
    for (ctx.prefetched.products[0..order.items_len]) |maybe_product| {
        if (maybe_product == null)
            return .{ .status = .not_found };
    }

    // Validate all have sufficient inventory.
    for (order.items_slice(), ctx.prefetched.products[0..order.items_len]) |item, maybe_product| {
        const product = maybe_product.?;
        if (product.inventory < item.quantity)
            return .{ .status = .insufficient_inventory };
    }

    // All validated — build order result and decrement inventories.
    var order_result = std.mem.zeroes(message.OrderResult);
    order_result.id = order.id;
    order_result.items_len = order.items_len;
    order_result.status = .pending;
    assert(ctx.fw.now > 0);
    order_result.timeout_at = @intCast(ctx.fw.now + message.order_timeout_seconds);

    for (order.items_slice(), ctx.prefetched.products[0..order.items_len], 0..) |item, maybe_product, i| {
        var product = t.productFromRow(maybe_product.?);
        product.inventory -= item.quantity;

        db.execute(
            t.sql.products.update,
            .{ product.id, product.name[0..product.name_len], product.description[0..product.description_len], product.price_cents, product.inventory, product.version, product.flags.active },
        );

        const line_total = @as(u64, product.price_cents) * @as(u64, item.quantity);
        order_result.items[i] = std.mem.zeroes(message.OrderResultItem);
        order_result.items[i].product_id = product.id;
        order_result.items[i].name = product.name;
        order_result.items[i].name_len = product.name_len;
        order_result.items[i].quantity = item.quantity;
        order_result.items[i].price_cents = product.price_cents;
        order_result.items[i].line_total_cents = line_total;
        order_result.total_cents +|= line_total;
    }

    db.execute(
        t.sql.orders.insert,
        .{ order_result.id, order_result.total_cents, @as(u32, order_result.items_len), @intFromEnum(order_result.status), @as(u64, order_result.timeout_at) },
    );

    for (order_result.items[0..order_result.items_len]) |item| {
        db.execute(
            t.sql.orders.insert_item,
            .{ order_result.id, item.product_id, item.name[0..item.name_len], item.quantity, item.price_cents, item.line_total_cents },
        );
    }

    return .{};
}

// [render] .create_order
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "<div>Order created — Pending</div>",
        .not_found => "<div class=\"error\">Product not found</div>",
        .insufficient_inventory => "<div class=\"error\">Insufficient inventory</div>",
    };
}

fn parse_order_json(body: []const u8) ?t.OrderRequest {
    var order = std.mem.zeroes(t.OrderRequest);

    const id_str = t.parse.json_string_field(body, "id") orelse return null;
    order.id = t.stdx.parse_uuid(id_str) orelse return null;
    if (order.id == 0) return null;

    const items_start = std.mem.indexOf(u8, body, "\"items\"") orelse return null;
    const bracket_start = std.mem.indexOfPos(u8, body, items_start, "[") orelse return null;
    const bracket_end = std.mem.indexOf(u8, body[bracket_start..], "]") orelse return null;
    const items_body = body[bracket_start + 1 .. bracket_start + bracket_end];

    var pos: usize = 0;
    while (pos < items_body.len) {
        const obj_start = std.mem.indexOfPos(u8, items_body, pos, "{") orelse break;
        const obj_end = std.mem.indexOfPos(u8, items_body, obj_start, "}") orelse return null;
        const obj = items_body[obj_start .. obj_end + 1];

        if (order.items_len >= t.order_items_max) return null;

        const pid_str = t.parse.json_string_field(obj, "product_id") orelse return null;
        const pid = t.stdx.parse_uuid(pid_str) orelse return null;
        if (pid == 0) return null;
        const qty = t.parse.json_u32_field(obj, "quantity") orelse return null;
        if (qty == 0) return null;

        for (order.items[0..order.items_len]) |existing| {
            if (existing.product_id == pid) return null;
        }

        order.items[order.items_len] = .{
            .product_id = pid,
            .quantity = qty,
            .reserved = .{0} ** 12,
        };
        order.items_len += 1;
        pos = obj_end + 1;
    }

    if (order.items_len == 0) return null;
    return order;
}
