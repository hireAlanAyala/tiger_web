const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok };

pub const Prefetch = struct { collections: ?t.BoundedList(t.CollectionRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.list_collections), t.Identity, Status);

// [route] .list_collections
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "collections")) return null;
    if (segments.has_id) return null;
    return t.Message.init(.list_collections, 0, 0, std.mem.zeroes(t.ListParams));
}

// [prefetch] .list_collections
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{ .collections = storage.query_all(t.CollectionRow, t.list_max,
        "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .list_collections
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}


// [render] .list_collections
pub fn render(ctx: Context) []const u8 {
    const collections = ctx.prefetched.collections orelse
        return "<div class=\"meta\">No collections</div>";
    var pos: usize = 0;
    for (collections.slice()) |*col| {
        if (!col.active) continue;
        pos += t.html.raw(ctx.render_buf[pos..], "<div class=\"card\"><strong>");
        pos += t.html.escaped(ctx.render_buf[pos..], std.mem.sliceTo(&col.name, 0));
        pos += t.html.raw(ctx.render_buf[pos..], "</strong><div class=\"meta\">");
        pos += t.html.uuid(ctx.render_buf[pos..], col.id);
        pos += t.html.raw(ctx.render_buf[pos..], "</div></div>");
    }
    if (pos == 0) return "<div class=\"meta\">No collections</div>";
    return ctx.render_buf[0..pos];
}
