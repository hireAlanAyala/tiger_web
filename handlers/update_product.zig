const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct {
    existing: ?t.Product,
};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.update_product), t.Identity);

// [route] .update_product
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .put) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id or segments.id == 0) return null;
    if (segments.sub_resource.len > 0) return null;
    if (body.len == 0) return null;
    const product = @import("create_product.zig").parse_product_json(body) orelse return null;
    return t.Message.init(.update_product, segments.id, 0, product);
}

// [prefetch] .update_product
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.Product,
        "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .update_product
pub fn handle(ctx: Context) t.ExecuteResult {
    const existing = ctx.prefetched.existing orelse
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    const event = ctx.body_val();

    // Version check for optimistic concurrency.
    if (event.version != 0 and event.version != existing.version)
        return t.ExecuteResult.read_only(.{ .status = .version_conflict, .result = .{ .empty = {} } });

    var entity = std.mem.zeroes(t.Product);
    entity.id = existing.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    if (event.description_len > 0)
        @memcpy(entity.description[0..event.description_len], event.description[0..event.description_len]);
    entity.description_len = event.description_len;
    entity.price_cents = event.price_cents;
    entity.inventory = event.inventory;
    entity.version = existing.version + 1;
    entity.flags = existing.flags;

    return t.ExecuteResult.single(
        .{ .status = .ok, .result = .{ .product = entity } },
        .{ .update_product = entity },
    );
}

// [render] .update_product
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
