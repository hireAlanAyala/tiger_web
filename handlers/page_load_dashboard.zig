const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Prefetch = struct {
    products: ?t.BoundedList(t.ProductRow, t.list_max),
    collections: ?t.BoundedList(t.CollectionRow, t.list_max),
    orders: ?t.BoundedList(t.OrderRow, t.list_max),
};

pub const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.page_load_dashboard), t.Identity, t.Status);

// [route] .page_load_dashboard
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len != 1 or raw_path[0] != '/') return null;
    return t.Message.init(.page_load_dashboard, 0, 0, {});
}

// [prefetch] .page_load_dashboard
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{
        .products = storage.query_all(t.ProductRow, t.list_max,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
        .collections = storage.query_all(t.CollectionRow, t.list_max,
            "SELECT id, name, active FROM collections WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
        .orders = storage.query_all(t.OrderRow, t.list_max,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}),
    };
}

// [handle] .page_load_dashboard
pub fn handle(ctx: Context) t.ExecuteResult {
    _ = ctx;
    return t.ExecuteResult.read_only(t.HandlerResponse.ok);
}


// [render] .page_load_dashboard
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    // TODO: render full dashboard page with all three sections
    return "<div id=\"content\">Dashboard</div>";
}
