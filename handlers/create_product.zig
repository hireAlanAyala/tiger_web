const std = @import("std");
const assert = std.debug.assert;
const t = @import("../prelude.zig");

pub const Status = enum { ok, version_conflict };

pub const Prefetch = struct {
    existing: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.create_product), t.Identity, Status);

// [route] .create_product
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const segments = t.parse.split_path(path) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (segments.has_id) return null;

    if (body.len == 0) return null;
    const product = parse_product_json(body) orelse return null;
    if (product.id == 0) return null;

    return t.Message.init(.create_product, product.id, 0, product);
}

// [prefetch] .create_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    // Product ID is always in the body — msg.id may be 0 for creates.
    const product_id = msg.body_as(t.Product).id;
    return .{ .existing = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{product_id}) };
}

// [handle] .create_product
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    if (ctx.prefetched.existing != null) {
        return .{ .status = .version_conflict };
    }

    const event = ctx.body_val();

    var entity = std.mem.zeroes(t.Product);
    entity.id = event.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    if (event.description_len > 0) {
        @memcpy(entity.description[0..event.description_len], event.description[0..event.description_len]);
    }
    entity.description_len = event.description_len;
    entity.price_cents = event.price_cents;
    entity.inventory = event.inventory;
    entity.version = 1;
    entity.flags = .{ .active = true };

    _ = db.execute(
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
        .{ entity.id, entity.name[0..entity.name_len], entity.description[0..entity.description_len], entity.price_cents, entity.inventory, entity.version, entity.flags.active },
    );
    return .{};
}

// [render] .create_product
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .version_conflict => "<div class=\"error\">Product already exists</div>",
    };
}

pub fn parse_product_json(body: []const u8) ?t.Product {
    var p = std.mem.zeroes(t.Product);

    const id_str = t.parse.json_string_field(body, "id") orelse return null;
    p.id = t.stdx.parse_uuid(id_str) orelse return null;

    const name = t.parse.json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > t.product_name_max) return null;
    @memcpy(p.name[0..name.len], name);
    p.name_len = @intCast(name.len);

    if (t.parse.json_string_field(body, "description")) |desc| {
        if (desc.len > t.product_description_max) return null;
        @memcpy(p.description[0..desc.len], desc);
        p.description_len = @intCast(desc.len);
    }

    p.price_cents = t.parse.json_u32_field(body, "price_cents") orelse 0;
    p.inventory = t.parse.json_u32_field(body, "inventory") orelse 0;
    p.flags = .{ .active = t.parse.json_bool_field(body, "active") orelse true };

    return p;
}
