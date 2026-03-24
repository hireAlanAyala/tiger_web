const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { collection: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.get_collection), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/collections/:id";

// [route] .get_collection
// match GET /collections/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    _ = body;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    return t.Message.init(.get_collection, id, 0, {});
}

// [prefetch] .get_collection
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .collection = storage.query(t.CollectionRow,
        "SELECT id, name, active FROM collections WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_collection
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
    const col = ctx.prefetched.collection orelse
        return .{ .status = .not_found };
    if (!col.active) return .{ .status = .not_found };
    return .{};
}


// [render] .get_collection
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .not_found => "Collection not found",
        .ok => render_ok(ctx),
    };
}

fn render_ok(ctx: Context) []const u8 {
    const col = ctx.prefetched.collection.?;
    var pos: usize = 0;
    pos += t.html.raw(ctx.render_buf[pos..], "<div class=\"card\"><strong>");
    pos += t.html.escaped(ctx.render_buf[pos..], std.mem.sliceTo(&col.name, 0));
    pos += t.html.raw(ctx.render_buf[pos..], "</strong><div class=\"meta\">");
    pos += t.html.uuid(ctx.render_buf[pos..], col.id);
    pos += t.html.raw(ctx.render_buf[pos..], "</div></div>");
    return ctx.render_buf[0..pos];
}

