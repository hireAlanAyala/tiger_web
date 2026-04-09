const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.get_order), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, pools: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.get_order, fuzz.pick_or_random_id(prng, pools.order_ids), prng.int(u128) | 1, {});
}

// [route] .get_order
// match GET /orders/:id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    return t.Message.init(.get_order, id, 0, {});
}

// [prefetch] .get_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .get_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = db;
    if (ctx.prefetched.order == null)
        return .{ .status = .not_found };
    return .{};
}


// [render] .get_order
pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {
        .not_found => "<div class=\"error\">Order not found</div>",
        .ok => "", // TODO: render order detail
    };
}
