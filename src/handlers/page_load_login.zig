const t = @import("../prelude.zig");
const fuzz_lib = @import("../fuzz_lib.zig");
const PRNG = @import("stdx").PRNG;

pub const Status = enum { ok };

pub const Prefetch = struct {};

pub const Context = t.HandlerContext(Prefetch, t.EventType(.page_load_login), t.Identity, Status);

pub fn gen_fuzz_message(prng: *PRNG, _: fuzz_lib.IdPools) ?t.Message {
    return t.Message.init(.page_load_login, 0, prng.int(u128) | 1, {});
}

// [route] .page_load_login
// match GET /login
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    _ = params; _ = body;
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
