const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found, insufficient_inventory };

pub const Prefetch = struct {
    source: ?t.ProductRow,
    target: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.transfer_inventory), t.Identity, Status);

pub const route_method = t.http.Method.post;
pub const route_pattern = "/products/:id/transfer-inventory/:sub_id";

// [route] .transfer_inventory
// match POST /products/:id/transfer-inventory/:sub_id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    const sub_id = t.stdx.parse_uuid(params.get("sub_id").?) orelse return null;
    if (id == 0 or sub_id == 0) return null;
    if (id == sub_id) return null;
    if (body.len == 0) return null;
    const quantity = t.parse.json_u32_field(body, "quantity") orelse return null;
    if (quantity == 0) return null;
    return t.Message.init(.transfer_inventory, id, 0, t.InventoryTransfer{
        .target_id = sub_id,
        .quantity = quantity,
        .reserved = .{0} ** 12,
    });
}

// [prefetch] .transfer_inventory
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{
        .source = storage.query(t.ProductRow,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
            .{msg.id}),
        .target = storage.query(t.ProductRow,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
            .{msg.body_as(t.InventoryTransfer).target_id}),
    };
}

// [handle] .transfer_inventory
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const source_row = ctx.prefetched.source orelse
        return .{ .status = .not_found };
    const target_row = ctx.prefetched.target orelse
        return .{ .status = .not_found };

    const transfer = ctx.body_val();
    if (source_row.inventory < transfer.quantity)
        return .{ .status = .insufficient_inventory };

    var source = t.productFromRow(source_row);
    source.inventory -= transfer.quantity;
    source.version += 1;

    var target = t.productFromRow(target_row);
    target.inventory += transfer.quantity;
    target.version += 1;

    db.execute(
        t.sql.products.update,
        .{ source.id, source.name[0..source.name_len], source.description[0..source.description_len], source.price_cents, source.inventory, source.version, source.flags.active },
    );
    db.execute(
        t.sql.products.update,
        .{ target.id, target.name[0..target.name_len], target.description[0..target.description_len], target.price_cents, target.inventory, target.version, target.flags.active },
    );
    return .{};
}

// [render] .transfer_inventory
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Product not found</div>",
        .insufficient_inventory => "<div class=\"error\">Insufficient inventory</div>",
    };
}
