const std = @import("std");
const t = @import("../prelude.zig");

pub const Prefetch = struct {};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.page_load_login), t.Identity);

// [route] .page_load_login
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    if (!std.mem.eql(u8, raw_path[1..], "login")) return null;
    return t.Message.init(.page_load_login, 0, 0, {});
}

// [prefetch] .page_load_login
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .page_load_login

// [render] .page_load_login
pub fn render(ctx: Context) t.RenderResult {
    return ctx.render(.{
        .{ "patch", "#content", "<form><input name=\"email\" placeholder=\"Email\"/><button>Send Login Code</button></form>", "inner" },
    });
}
