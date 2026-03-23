const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");
const message = @import("../message.zig");

pub const Prefetch = struct {
    products: [t.order_items_max]?t.ProductRow,
    order_id: u128,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.create_order), t.Identity);

// [route] .create_order
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (segments.has_id) return null;
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
pub fn handle(ctx: Context) t.ExecuteResult {
    // TODO: validate inventory, build OrderResult, decrement inventory, return writes
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
}

// [render] .create_order
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }

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
