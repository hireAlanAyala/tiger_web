const std = @import("std");
const t = @import("../prelude.zig");
const message = @import("../message.zig");

pub const Prefetch = struct { order: ?t.OrderRow };

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.complete_order), t.Identity, t.Status);

// [route] .complete_order
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const segments = t.parse.split_path(raw_path[1..]) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "orders")) return null;
    if (!segments.has_id) return null;
    if (!std.mem.eql(u8, segments.sub_resource, "complete")) return null;
    if (body.len == 0) return null;
    const completion = parse_completion_json(body) orelse return null;
    return t.Message.init(.complete_order, segments.id, 0, completion);
}

// [prefetch] .complete_order
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .order = storage.query(t.OrderRow,
        "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        .{msg.id}) };
}

// [handle] .complete_order
pub fn handle(ctx: Context) t.ExecuteResult {
    // TODO: validate order pending, check timeout, set status, restore inventory if failed
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
}

// [render] .complete_order
pub fn render(ctx: Context) []const u8 { _ = ctx; return ""; }

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
