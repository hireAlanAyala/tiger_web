const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.request_login_code), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.request_login_code, 0, prng.int(u128) | 1, fuzz.gen_login_code_request(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const msg_mod = @import("../message.zig");
    const ev = msg.body_as(msg_mod.LoginCodeRequest);
    if (ev.email_len == 0 or ev.email_len > msg_mod.email_max) return false;
    if (!@import("std").unicode.utf8ValidateSlice(ev.email[0..ev.email_len])) return false;
    return true;
}

// [route] .request_login_code
// match POST /login/code
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params;
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
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    // TODO: generate login code, write to storage
    _ = ctx;
    _ = db;
    return .{};
}

// [render] .request_login_code
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<form id=\"login-box\"><input name=\"code\" placeholder=\"Enter code\"/><button>Verify</button></form>";
}
