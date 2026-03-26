const std = @import("std");
const t = @import("../prelude.zig");
const message = @import("../message.zig");

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.verify_login_code), t.Identity, Status);

// [route] .verify_login_code
// match POST /login/verify
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params;
    if (body.len == 0) return null;

    const email = t.parse.json_string_field(body, "email") orelse return null;
    const code = t.parse.json_string_field(body, "code") orelse return null;
    if (email.len == 0 or std.mem.indexOf(u8, email, "@") == null) return null;
    if (code.len != message.code_length) return null;
    for (code) |c| { if (c < '0' or c > '9') return null; }

    var req = std.mem.zeroes(t.LoginVerification);
    @memcpy(req.email[0..email.len], email);
    req.email_len = @intCast(email.len);
    @memcpy(req.code[0..code.len], code);
    return t.Message.init(.verify_login_code, 0, 0, req);
}

// [prefetch] .verify_login_code
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .verify_login_code
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    // TODO: validate code, create session
    _ = ctx;
    _ = db;
    return .{};
}

// [render] .verify_login_code
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<script>window.location.href='/'</script>";
}
