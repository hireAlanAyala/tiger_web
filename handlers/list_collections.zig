const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct { collections: ?t.BoundedList(t.CollectionRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.list_collections), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.list_collections, 0, prng.int(u128) | 1, fuzz.gen_list_params(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const lp = msg.body_as(t.ListParams);
    if (lp.name_prefix_len > t.product_name_max) return false;
    const prefix = lp.name_prefix[0..lp.name_prefix_len];
    for (prefix) |b| { if (b == 0) return false; }
    if (!@import("std").unicode.utf8ValidateSlice(prefix)) return false;
    return true;
}

// [route] .list_collections
// match GET /collections
// query cursor
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    var lp = std.mem.zeroes(t.ListParams);
    if (params.get("cursor")) |c| {
        lp.cursor = t.stdx.parse_uuid(c) orelse return null;
    }
    return t.Message.init(.list_collections, 0, 0, lp);
}

// [prefetch] .list_collections
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const params = msg.body_as(t.ListParams);
    if (params.cursor != 0) {
        return .{ .collections = storage.query_all(t.CollectionRow, t.list_max,
            "SELECT id, name, active FROM collections WHERE active = 1 AND id > ?1 ORDER BY id LIMIT ?2;",
            .{ params.cursor, @as(u32, t.list_max) }) };
    }
    return .{ .collections = storage.query_all(t.CollectionRow, t.list_max,
        "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .list_collections
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .list_collections
pub fn render(ctx: Context) []const u8 {
    const collections = ctx.prefetched.collections orelse
        return "<div class=\"meta\">No collections</div>";
    const items = collections.slice();
    var pos: usize = 0;
    for (items) |*col| {
        if (!col.active) continue;
        pos += t.html.raw(ctx.render_buf[pos..], "<div class=\"card\"><strong>");
        pos += t.html.escaped(ctx.render_buf[pos..], std.mem.sliceTo(&col.name, 0));
        pos += t.html.raw(ctx.render_buf[pos..], "</strong><div class=\"meta\">");
        pos += t.html.uuid(ctx.render_buf[pos..], col.id);
        pos += t.html.raw(ctx.render_buf[pos..], "</div></div>");
    }
    if (pos == 0) return "<div class=\"meta\">No collections</div>";

    if (items.len == t.list_max) {
        const last_id = items[items.len - 1].id;
        pos += t.html.raw(ctx.render_buf[pos..],
            "<div data-on-intersect=\"@get('/collections?cursor=");
        pos += t.html.uuid(ctx.render_buf[pos..], last_id);
        pos += t.html.raw(ctx.render_buf[pos..], "')\"></div>");
    }

    return ctx.render_buf[0..pos];
}
