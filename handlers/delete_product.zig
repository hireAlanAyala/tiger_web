const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { existing: ?t.ProductRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.delete_product), t.Identity, Status);

pub const route_method = t.http.Method.delete;
pub const route_pattern = "/products/:id";

// [route] .delete_product
// match DELETE /products/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    _ = body;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    return t.Message.init(.delete_product, id, 0, {});
}

// [prefetch] .delete_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .delete_product
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const row = ctx.prefetched.existing orelse
        return .{ .status = .not_found };
    if (!row.active)
        return .{ .status = .not_found };

    var entity = t.productFromRow(row);
    entity.version += 1;
    entity.flags = .{ .active = false };

    db.execute(
        t.sql.products.update,
        .{ entity.id, entity.name[0..entity.name_len], entity.description[0..entity.description_len], entity.price_cents, entity.inventory, entity.version, entity.flags.active },
    );
    return .{};
}

// [render] .delete_product
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Product not found</div>",
    };
}
