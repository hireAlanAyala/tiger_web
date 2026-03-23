const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.logout), t.Identity);

// [route] .logout
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    if (!std.mem.eql(u8, raw_path[1..], "logout")) return null;
    return t.Message.init(.logout, 0, 0, {});
}

// [prefetch] .logout
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .logout
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(.{ .status = .ok, .session_action = .clear });
}


// [render] .logout
pub fn render(ctx: Context) t.RenderResult {
    return ctx.render(.{
        .{ "script", "window.location.href='/login'" },
    });
}
