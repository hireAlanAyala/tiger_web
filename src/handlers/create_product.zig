const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, version_conflict };

pub const Prefetch = struct {
    existing: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.create_product), t.Identity, Status);

const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.create_product, 0, prng.int(u128) | 1, fuzz.gen_product(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const p = msg.body_as(t.Product);
    if (p.id == 0) return false;
    if (msg.id != 0 and msg.id != p.id) return false;
    if (p.name_len == 0 or p.name_len > t.product_name_max) return false;
    if (p.description_len > t.product_description_max) return false;
    if (p.flags.padding != 0) return false;
    if (!std.unicode.utf8ValidateSlice(p.name[0..p.name_len])) return false;
    if (!std.unicode.utf8ValidateSlice(p.description[0..p.description_len])) return false;
    return true;
}

// [route] .create_product
// match POST /products
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params;
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

    db.execute(
        t.sql.products.insert,
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
