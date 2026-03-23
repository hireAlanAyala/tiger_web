const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { existing: ?t.CollectionRow };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.create_collection), t.Identity);

// [route] .create_collection
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (segments.has_id) return null;
    if (body.len == 0) return null;
    const col = parse_collection_json(body) orelse return null;
    if (col.id == 0) return null;
    return t.Message.init(.create_collection, col.id, 0, col);
}

// [prefetch] .create_collection
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .existing = storage.query(t.CollectionRow,
        "SELECT id, name, active FROM collections WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .create_collection
pub fn handle(ctx: Context) t.ExecuteResult {
    if (ctx.prefetched.existing != null)
        return t.ExecuteResult.read_only(.{ .status = .version_conflict, .result = .{ .empty = {} } });
    const event = ctx.body_val();
    var entity = std.mem.zeroes(t.ProductCollection);
    entity.id = event.id;
    @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
    entity.name_len = event.name_len;
    entity.flags = .{ .active = true };
    return t.ExecuteResult.single(
        .{ .status = .ok, .result = .{ .empty = {} } },
        .{ .put_collection = entity },
    );
}

// [render] .create_collection
pub fn render(ctx: Context) t.RenderResult { return ctx.render(.{}); }

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
