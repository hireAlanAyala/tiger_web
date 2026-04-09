const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { existing: ?t.CollectionRow };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.delete_collection), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.delete_collection, fuzz.pick_or_random_id(prng, pools.collection_ids), prng.int(u128) | 1, {});
}

// [route] .delete_collection
// match DELETE /collections/:id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    return t.Message.init(.delete_collection, id, 0, {});
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
