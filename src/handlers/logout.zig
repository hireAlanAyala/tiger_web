const std = @import("std");
const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.logout), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    return t.Message.init(.logout, 0, prng.int(u128) | 1, {});
}

// [route] .logout
// match POST /logout
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params; _ = body;
    return t.Message.init(.logout, 0, 0, {});
}

// [prefetch] .logout
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = storage; _ = msg;
    return .{};
}

// [handle] .logout
pub fn handle(ctx: Context, db: anytype) t.HandleResult {
    _ = ctx;
    _ = db;
    return .{ .session_action = .clear };
}


// [render] .logout
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<script>window.location.href='/login'</script>";
}
