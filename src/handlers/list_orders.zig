const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct { orders: ?t.BoundedList(t.OrderRow, t.list_max) };

pub const Context = t.HandlerContext(Prefetch, t.EventType(.list_orders), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.list_orders, 0, prng.int(u128) | 1, fuzz.gen_list_params(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const lp = msg.body_as(t.ListParams);
    if (lp.name_prefix_len > t.product_name_max) return false;
    const prefix = lp.name_prefix[0..lp.name_prefix_len];
    for (prefix) |b| { if (b == 0) return false; }
    if (!@import("std").unicode.utf8ValidateSlice(prefix)) return false;
    return true;
}

// [route] .list_orders
// match GET /orders
// query cursor
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = body;
    var lp = std.mem.zeroes(t.ListParams);
    if (params.get("cursor")) |c| {
        lp.cursor = t.stdx.parse_uuid(c) orelse return null;
    }
    return t.Message.init(.list_orders, 0, 0, lp);
}

// [prefetch] .list_orders
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    const params = msg.body_as(t.ListParams);
    if (params.cursor != 0) {
        return .{ .orders = storage.query_all(t.OrderRow, t.list_max,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id > ?1 ORDER BY id LIMIT ?2;",
            .{ params.cursor, @as(u32, t.list_max) }) };
    }
    return .{ .orders = storage.query_all(t.OrderRow, t.list_max,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1;",
        .{@as(u32, t.list_max)}) };
}

// [handle] .list_orders
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .list_orders
pub fn render(ctx: Context) []const u8 {
    const h = t.html;
    var buf = ctx.render_buf;

    const orders = (ctx.prefetched.orders orelse return "").slice();
    if (orders.len == 0) return "<div>No orders</div>";

    var pos: usize = 0;
    for (orders) |order| {
        pos += h.raw(buf[pos..], "<div class=\"card\">Order <strong>");
        pos += h.uuid(buf[pos..], order.id);
        pos += h.raw(buf[pos..], "</strong> &mdash; ");
        pos += h.raw(buf[pos..], switch (order.status) {
            .pending => "Pending",
            .confirmed => "Confirmed",
            .failed => "Failed",
            .cancelled => "Cancelled",
        });
        pos += h.raw(buf[pos..], " &mdash; ");
        pos += h.price_u64(buf[pos..], order.total_cents);
        pos += h.raw(buf[pos..], "</div>");
    }

    if (orders.len == t.list_max) {
        const last_id = orders[orders.len - 1].id;
        pos += h.raw(buf[pos..],
            "<div data-on-intersect=\"@get('/orders?cursor=");
        pos += h.uuid(buf[pos..], last_id);
        pos += h.raw(buf[pos..], "')\"></div>");
    }

    return buf[0..pos];
}
