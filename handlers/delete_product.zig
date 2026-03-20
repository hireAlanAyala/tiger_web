const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { existing: ?t.Product };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.delete_product), t.Identity);

// [route] .delete_product
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .delete) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;
    return t.Message.init(.delete_product, segments.id, 0, {});
}

// [prefetch] .delete_product
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.Product,
        "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .delete_product
pub fn handle(ctx: Context) t.ExecuteResult {
    var product = ctx.prefetched.existing orelse
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    if (!product.flags.active)
        return t.ExecuteResult.read_only(t.Message.MessageResponse.not_found);
    product.flags.active = false;
    product.version += 1;
    return t.ExecuteResult.single(
        .{ .status = .ok, .result = .{ .empty = {} } },
        .{ .update_product = product },
    );
}

// [render] .delete_product
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }
