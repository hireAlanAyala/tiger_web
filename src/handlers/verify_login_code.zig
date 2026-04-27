const std = @import("std");
const t = @import("../prelude.zig");
const message = @import("../message.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.verify_login_code), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    const fuzz = @import("../fuzz.zig");
    return t.Message.init(.verify_login_code, 0, prng.int(u128) | 1, fuzz.gen_login_verification(prng));
}

pub fn input_valid(msg: t.Message) bool {
    const ev = msg.body_as(message.LoginVerification);
    if (ev.email_len == 0 or ev.email_len > message.email_max) return false;
    if (!@import("std").unicode.utf8ValidateSlice(ev.email[0..ev.email_len])) return false;
    for (ev.code[0..message.code_length]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

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
