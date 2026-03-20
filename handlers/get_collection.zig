const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct { collection: ?t.ProductCollection };

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_collection), t.Identity);

// [route] .get_collection
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null;
    return t.Message.init(.get_collection, segments.id, 0, {});
}

// [prefetch] .get_collection
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    return .{ .collection = storage.query(t.ProductCollection,
        "SELECT id, name, active, name_len FROM product_collections WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_collection

// [render] .get_collection
pub fn render(ctx: Context) t.RenderResult {
    const col = ctx.prefetched.collection orelse
        return ctx.render(.{ .{ "patch", "#content", "Collection not found", "inner" } });
    if (!col.flags.active)
        return ctx.render(.{ .{ "patch", "#content", "Collection not found", "inner" } });
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    pos += t.html.raw(buf[pos..], "<div class=\"card\"><strong>");
    pos += t.html.escaped(buf[pos..], col.name[0..col.name_len]);
    pos += t.html.raw(buf[pos..], "</strong><div class=\"meta\">");
    pos += t.html.uuid(buf[pos..], col.id);
    pos += t.html.raw(buf[pos..], "</div></div>");
    return ctx.render(.{ .{ "patch", "#content", buf[0..pos], "inner" } });
}
