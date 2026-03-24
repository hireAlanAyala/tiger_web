const std = @import("std");
const t = @import("../prelude.zig");
const message = @import("../message.zig");

pub const Status = enum { ok, not_found };

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.complete_order), t.Identity, Status);

pub const route_method = t.http.Method.post;
pub const route_pattern = "/orders/:id/complete";

// [route] .complete_order
// match POST /orders/:id/complete
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    const params = t.match_route(raw_path, route_pattern) orelse return null;
    const id = t.stdx.parse_uuid(params.get("id").?) orelse return null;
    if (body.len == 0) return null;
    const completion = parse_completion_json(body) orelse return null;
    return t.Message.init(.complete_order, id, 0, completion);
}

// [prefetch] .complete_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .complete_order
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    // TODO: validate order pending, check timeout, set status, restore inventory if failed
    _ = ctx;
    _ = db;
    return .{ .status = .not_found };
}

// [render] .complete_order
pub fn render(ctx: Context, db: anytype) []const u8 {
    const h = t.html;
    var buf = ctx.render_buf;
    var pos: usize = 0;

    switch (ctx.status) {
        .not_found => return "<div class=\"error\">Order not found</div>",
        .ok => {},
    }

    // Query post-mutation order state — the order is now confirmed/failed.
    const order = db.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{ctx.prefetched.order.?.id},
    ) orelse return "<div class=\"error\">Order not found after completion</div>";

    pos += h.raw(buf[pos..], "<div class=\"card\">Order <strong>");
    pos += h.short_uuid(buf[pos..], order.id);
    pos += h.raw(buf[pos..], "...</strong> &mdash; ");
    pos += h.raw(buf[pos..], switch (order.status) {
        .pending => "Pending",
        .confirmed => "Confirmed",
        .failed => "Failed",
        .cancelled => "Cancelled",
    });
    pos += h.raw(buf[pos..], " &mdash; ");
    pos += h.price_u64(buf[pos..], order.total_cents);
    pos += h.raw(buf[pos..], "</div>");

    return buf[0..pos];
}

fn parse_completion_json(body: []const u8) ?t.OrderCompletion {
    const result_str = t.parse.json_string_field(body, "result") orelse return null;
    const result: t.OrderCompletion.OrderCompletionResult =
        if (std.mem.eql(u8, result_str, "confirmed")) .confirmed
        else if (std.mem.eql(u8, result_str, "failed")) .failed
        else return null;

    var completion = std.mem.zeroes(t.OrderCompletion);
    completion.result = result;

    if (t.parse.json_string_field(body, "payment_ref")) |ref| {
        if (ref.len > 0 and ref.len <= message.payment_ref_max) {
            @memcpy(completion.payment_ref[0..ref.len], ref);
            completion.payment_ref_len = @intCast(ref.len);
        }
    }

    return completion;
}
