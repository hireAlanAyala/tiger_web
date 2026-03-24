const std = @import("std");
const t = @import("../prelude.zig");

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.request_login_code), t.Identity, Status);

// [route] .request_login_code
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    if (method != .post) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    if (!std.mem.eql(u8, raw_path[1..], "login/code")) return null;
    if (body.len == 0) return null;
    const email = t.parse.json_string_field(body, "email") orelse return null;
    if (email.len == 0 or std.mem.indexOf(u8, email, "@") == null) return null;

    var req = std.mem.zeroes(t.LoginCodeRequest);
    @memcpy(req.email[0..email.len], email);
    req.email_len = @intCast(email.len);
    return t.Message.init(.request_login_code, 0, 0, req);
}

// [prefetch] .request_login_code
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .request_login_code
pub fn handle(ctx: Context) t.ExecuteResult {
    // TODO: generate login code, write to storage
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}

// [render] .request_login_code
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<form id=\"login-box\"><input name=\"code\" placeholder=\"Enter code\"/><button>Verify</button></form>";
}
