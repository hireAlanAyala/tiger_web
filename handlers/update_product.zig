const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found, version_conflict };

pub const Prefetch = struct {
    existing: ?t.ProductRow,
};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.update_product), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    const id = fuzz.pick_or_random_id(prng, pools.product_ids);
    return t.Message.init(.update_product, id, prng.int(u128) | 1, fuzz.gen_product_with_id(prng, id));
}

pub fn input_valid(msg: t.Message) bool {
    if (msg.id == 0) return false;
    const p = msg.body_as(t.Product);
    if (p.name_len == 0 or p.name_len > t.product_name_max) return false;
    if (p.description_len > t.product_description_max) return false;
    if (p.flags.padding != 0) return false;
    if (!@import("std").unicode.utf8ValidateSlice(p.name[0..p.name_len])) return false;
    if (!@import("std").unicode.utf8ValidateSlice(p.description[0..p.description_len])) return false;
    return true;
}

// [route] .update_product
// match PUT /products/:id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    if (id == 0) return null;
    if (body.len == 0) return null;
    const product = parse_update_json(body, id) orelse return null;
    return t.Message.init(.update_product, id, 0, product);
}

// [prefetch] .update_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .update_product
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const row = ctx.prefetched.existing orelse
        return .{ .status = .not_found };
    const event = ctx.body_val();

    // Version check for optimistic concurrency.
    if (event.version != 0 and event.version != row.version)
        return .{ .status = .version_conflict };

    var entity = std.mem.zeroes(t.Product);
    entity.id = row.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    if (event.description_len > 0)
        @memcpy(entity.description[0..event.description_len], event.description[0..event.description_len]);
    entity.description_len = event.description_len;
    entity.price_cents = event.price_cents;
    entity.inventory = event.inventory;
    entity.version = row.version + 1;
    entity.flags = .{ .active = row.active };

    db.execute(
        t.sql.products.update,
        .{ entity.id, entity.name[0..entity.name_len], entity.description[0..entity.description_len], entity.price_cents, entity.inventory, entity.version, entity.flags.active },
    );
    return .{};
}

// [render] .update_product
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Product not found</div>",
        .version_conflict => "<div class=\"error\">Version conflict</div>",
    };
}

fn parse_update_json(body: []const u8, path_id: u128) ?t.Product {
    var p = std.mem.zeroes(t.Product);
    p.id = path_id;

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
    p.version = t.parse.json_u32_field(body, "version") orelse 0;
    p.flags = .{ .active = t.parse.json_bool_field(body, "active") orelse true };

    return p;
}
