const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.page_load_login), t.Identity, Status);

pub const route_method = t.http.Method.get;
pub const route_pattern = "/login";

// [route] .page_load_login
// match GET /login
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method; _ = body;
    if (t.match_route(raw_path, route_pattern) == null) return null;
    return t.Message.init(.page_load_login, 0, 0, {});
}

// [prefetch] .page_load_login
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .page_load_login
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{};
}


// [render] .page_load_login
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<form id=\"login-box\"><input name=\"email\" placeholder=\"Email\"/><button>Send Login Code</button></form>";
}
