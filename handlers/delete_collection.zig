const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { existing: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.delete_collection), t.Identity, Status);

// [route] .delete_collection
// match DELETE /collections/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .delete) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;
    return t.Message.init(.delete_collection, segments.id, 0, {});
}

// [prefetch] .delete_collection
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.CollectionRow,
        "SELECT id, name, active FROM collections WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .delete_collection
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    const row = ctx.prefetched.existing orelse
        return .{ .status = .not_found };
    if (!row.active)
        return .{ .status = .not_found };
    var entity = t.collectionFromRow(row);
    entity.flags = .{ .active = false };
    db.execute(
        t.sql.collections.update,
        .{ entity.id, entity.name[0..entity.name_len], entity.flags.active },
    );
    return .{};
}

// [render] .delete_collection
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .not_found => "<div class=\"error\">Collection not found</div>",
    };
}
