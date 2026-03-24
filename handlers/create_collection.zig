const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, version_conflict };

pub const Prefetch = struct { existing: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.create_collection), t.Identity, Status);

pub const route_method = t.http.Method.post;
pub const route_pattern = "/collections";

// [route] .create_collection
// match POST /collections
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    if (t.match_route(raw_path, route_pattern) == null) return null;
    if (body.len == 0) return null;
    const col = parse_collection_json(body) orelse return null;
    if (col.id == 0) return null;
    return t.Message.init(.create_collection, col.id, 0, col);
}

// [prefetch] .create_collection
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const collection_id = msg.body_as(t.ProductCollection).id;
    return .{ .existing = storage.query(t.CollectionRow,
        "SELECT id, name, active FROM collections WHERE id = ?1;",
        .{collection_id}) };
}

// [handle] .create_collection
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    if (ctx.prefetched.existing != null)
        return .{ .status = .version_conflict };
    const event = ctx.body_val();
    var entity = std.mem.zeroes(t.ProductCollection);
    entity.id = event.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    entity.flags = .{ .active = true };
    db.execute(
        t.sql.collections.insert,
        .{ entity.id, entity.name[0..entity.name_len], entity.flags.active },
    );
    return .{};
}

// [render] .create_collection
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .ok => "",
        .version_conflict => "<div class=\"error\">Collection already exists</div>",
    };
}

pub fn parse_collection_json(body: []const u8) ?t.ProductCollection {
    var col = std.mem.zeroes(t.ProductCollection);
    const id_str = t.parse.json_string_field(body, "id") orelse return null;
    col.id = t.stdx.parse_uuid(id_str) orelse return null;
    const name = t.parse.json_string_field(body, "name") orelse return null;
    if (name.len == 0 or name.len > t.collection_name_max) return null;
    @memcpy(col.name[0..name.len], name);
    col.name_len = @intCast(name.len);
    return col;
}
