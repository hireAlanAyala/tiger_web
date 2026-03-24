const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { existing: ?t.ProductRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.delete_product), t.Identity, Status);

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
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .delete_product
pub fn handle(ctx: Context) t.ExecuteResult {
    const row = ctx.prefetched.existing orelse
        return t.ExecuteResult.read_only(.not_found);
    if (!row.active)
        return t.ExecuteResult.read_only(.not_found);

    var entity = t.productFromRow(row);
    entity.version += 1;
    entity.flags = .{ .active = false };

    return t.ExecuteResult.single(
        .ok,
        .{ .update_product = entity },
    );
}

// [render] .delete_product
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Product not found</div>",
    };
}
