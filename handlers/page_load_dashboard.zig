const std = @import("std");
const t = @import("../prelude.zig");
const get_product = @import("get_product.zig");

pub const Prefetch = struct {
    products: t.BoundedList(t.Product, t.list_max),
    collections: t.BoundedList(t.ProductCollection, t.list_max),
    orders: t.BoundedList(t.OrderSummary, t.list_max),
};

const Context = t.HandlerContext(Prefetch, t.Operation.EventType(.page_load_dashboard), t.Identity);

// [route] .page_load_dashboard
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len != 1 or raw_path[0] != '/') return null;
    return t.Message.init(.page_load_dashboard, 0, 0, {});
}

// [prefetch] .page_load_dashboard
pub fn prefetch(storage: *t.Storage, msg: *const t.Message) ?Prefetch {
    _ = msg;
    return .{
        .products = storage.query_all(t.Product, t.list_max,
            "SELECT id, description, name, price_cents, inventory, version, description_len, name_len, active FROM products WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}) orelse .{},
        .collections = storage.query_all(t.ProductCollection, t.list_max,
            "SELECT id, name, active, name_len FROM product_collections WHERE active = 1 ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}) orelse .{},
        .orders = storage.query_all(t.OrderSummary, t.list_max,
            "SELECT id, status, total_cents, items_len FROM orders ORDER BY id LIMIT ?1;",
            .{@as(u32, t.list_max)}) orelse .{},
    };
}

// [handle] .page_load_dashboard

// [render] .page_load_dashboard
pub fn render(ctx: Context) t.RenderResult {
    // TODO: render full dashboard page with all three sections
    return ctx.render(.{
        .{ "patch", "#content", "<div>Dashboard</div>", "inner" },
    });
}
