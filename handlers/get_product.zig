const std = @import("std");
const assert = std.debug.assert;
const fw = @import("tiger_framework");
const http = fw.http;
const parse = fw.parse;
const effects = fw.effects;
const message = @import("../message.zig");
const Storage = @import("../storage.zig").SqliteStorage;

pub const Prefetch = struct {
    product: ?ProductRow,
};

/// Subset of product fields needed for display.
/// Column order must match the SELECT in prefetch.
const ProductRow = struct {
    id: u128,
    name: [message.product_name_max]u8,
    description: [message.product_description_max]u8,
    price_cents: u32,
    inventory: u32,
    version: u32,
    description_len: u16,
    name_len: u8,
    active: bool,
};

// [route] .get_product
pub fn route(method: http.Method, raw_path: []const u8, body: []const u8) ?message.Message {
    _ = body;
    if (method != .get) return null;
    if (raw_path.len == 0 or raw_path[0] != '/') return null;
    const path = raw_path[1..];

    const segments = parse.split_path(path) orelse return null;
    if (!std.mem.eql(u8, segments.collection, "products")) return null;
    if (!segments.has_id) return null;
    if (segments.sub_resource.len > 0) return null; // /products/:id/inventory is a different op

    return message.Message.init(.get_product, segments.id, 0, {});
}

// [prefetch] .get_product
pub fn prefetch(storage: *Storage, msg: *const message.Message) ?Prefetch {
    const row = storage.query(
        ProductRow,
        "SELECT id, name, description, price_cents, inventory, version, description_len, name_len, active FROM products WHERE id = ?1;",
        .{msg.id},
    );
    return .{ .product = row };
}

// [handle] .get_product

// [render] .get_product
// TODO: render returns RenderEffects once the render pipeline is wired.
// For now, this is the handler structure — the render body will be
// filled in when effects are connected to the server's send path.