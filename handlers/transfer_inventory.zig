const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");

pub const Prefetch = struct {
    source: ?t.Product,
    target: ?t.Product,
};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.transfer_inventory), t.Identity);

// [route] .transfer_inventory
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id or segments.id == 0) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "transfer-inventory")) return null;
    if (!segments.has_sub_id or segments.sub_id == 0) return null;
    if (segments.id == segments.sub_id) return null;
    if (body.len == 0) return null;
    const quantity = t.parse.json_u32_field(body, "quantity") orelse return null;
    if (quantity == 0) return null;
    return t.Message.init(.transfer_inventory, segments.id, 0, t.InventoryTransfer{
        .target_id = segments.sub_id,
        .quantity = quantity,
        .reserved = .{0} ** 12,
    });
}

// [prefetch] .transfer_inventory
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    const source = storage.query(t.Product,
        "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.id});
    const target = storage.query(t.Product,
        "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.body_as(t.InventoryTransfer).target_id});
    return .{ .source = source, .target = target };
}

// [handle] .transfer_inventory
pub fn handle(ctx: Context) t.ExecuteResult {
    var source = ctx.prefetched.source orelse
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    var target = ctx.prefetched.target orelse
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);

    const transfer = ctx.body_val();
    if (source.inventory < transfer.quantity)
        return t.ExecuteResult.read_only(.{ .status = .insufficient_inventory, .result = .{ .empty = {} } });

    source.inventory -= transfer.quantity;
    source.version += 1;
    target.inventory += transfer.quantity;
    target.version += 1;

    var result = t.ExecuteResult{
        .response = .{ .status = .ok, .result = .{ .empty = {} } },
        .writes = undefined,
        .writes_len = 2,
    };
    result.writes[0] = .{ .update_product = source };
    result.writes[1] = .{ .update_product = target };
    return result;
}

// [render] .transfer_inventory
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
