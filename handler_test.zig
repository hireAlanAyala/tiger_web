//! Integration test: wire get_product handler through AppType.
//! If this compiles, the handler's signatures pass comptime validation.

const std = @import("std");
const fw_handler = @import("framework/handler.zig");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const get_product = @import("handlers/get_product.zig");
const create_product = @import("handlers/create_product.zig");
const list_products = @import("handlers/list_products.zig");

// Wire one handler through AppType to prove the comptime pipeline works.
// This is intentionally incomplete — only get_product is registered.
// It won't pass exhaustiveness (missing 23 other operations), but it
// exercises ValidateHandler on a real handler file.
//
// For now, test the handler functions directly instead of through AppType.

test "get_product route matches GET /products/:id" {
    const result = get_product.route(.get, "/products/aabbccdd11223344aabbccdd11223344", "");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(message.Operation.get_product, result.?.operation);
}

test "get_product route rejects POST" {
    try std.testing.expect(get_product.route(.post, "/products/aabbccdd11223344aabbccdd11223344", "") == null);
}

test "get_product route rejects no id" {
    try std.testing.expect(get_product.route(.get, "/products", "") == null);
}

test "get_product route rejects sub-resource" {
    try std.testing.expect(get_product.route(.get, "/products/aabbccdd11223344aabbccdd11223344/inventory", "") == null);
}

test "get_product route rejects other collections" {
    try std.testing.expect(get_product.route(.get, "/orders/aabbccdd11223344aabbccdd11223344", "") == null);
}

test "get_product render not found" {
    const Context = fw_handler.HandlerContext(
        get_product.Prefetch,
        message.Operation.EventType(.get_product),
        message.PrefetchIdentity,
        message.Status,
    );

    var render_buf: [4096]u8 = undefined;
    const ctx = Context{
        .prefetched = .{ .product = null },
        .body = {},
        .identity = std.mem.zeroes(message.PrefetchIdentity),
        .render_buf = &render_buf,
    };

    const result = get_product.render(ctx);
    try std.testing.expectEqual(@as(u8, 1), result.len);
    const effect = result.slice()[0];
    try std.testing.expect(std.mem.eql(u8, "#content", effect.selector_slice()));
    const html = effect.content(&render_buf);
    try std.testing.expect(std.mem.indexOf(u8, html, "not found") != null);
}

test "get_product render product card" {
    const Context = fw_handler.HandlerContext(
        get_product.Prefetch,
        message.Operation.EventType(.get_product),
        message.PrefetchIdentity,
        message.Status,
    );

    var product = std.mem.zeroes(message.Product);
    product.id = 0xaabb;
    @memcpy(product.name[0..6], "Widget");
    product.name_len = 6;
    product.price_cents = 999;
    product.inventory = 42;
    product.version = 1;
    product.flags = .{ .active = true };

    var render_buf: [4096]u8 = undefined;
    const ctx = Context{
        .prefetched = .{ .product = product },
        .body = {},
        .identity = std.mem.zeroes(message.PrefetchIdentity),
        .render_buf = &render_buf,
    };

    const result = get_product.render(ctx);
    try std.testing.expectEqual(@as(u8, 1), result.len);
    const effect = result.slice()[0];
    const html = effect.content(&render_buf);
    try std.testing.expect(std.mem.indexOf(u8, html, "Widget") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "$9.99") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "inv: 42") != null);
}

// --- create_product tests ---

test "create_product route matches POST /products" {
    const body = "{\"id\":\"aabbccdd11223344aabbccdd11223344\",\"name\":\"Widget\"}";
    const result = create_product.route(.post, "/products", body);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(message.Operation.create_product, result.?.operation);
}

test "create_product route rejects GET" {
    try std.testing.expect(create_product.route(.get, "/products", "{}") == null);
}

test "create_product route rejects with id in path" {
    const body = "{\"id\":\"aabbccdd11223344aabbccdd11223344\",\"name\":\"Widget\"}";
    try std.testing.expect(create_product.route(.post, "/products/aabbccdd11223344aabbccdd11223344", body) == null);
}

test "create_product route rejects empty body" {
    try std.testing.expect(create_product.route(.post, "/products", "") == null);
}

test "create_product route rejects missing name" {
    try std.testing.expect(create_product.route(.post, "/products", "{\"id\":\"aabbccdd11223344aabbccdd11223344\"}") == null);
}

// --- list_products tests ---

test "list_products route matches GET /products" {
    const result = list_products.route(.get, "/products", "");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(message.Operation.list_products, result.?.operation);
}

test "list_products route rejects POST" {
    try std.testing.expect(list_products.route(.post, "/products", "") == null);
}

test "list_products route rejects with id" {
    try std.testing.expect(list_products.route(.get, "/products/aabbccdd11223344aabbccdd11223344", "") == null);
}

test "list_products route rejects search query" {
    try std.testing.expect(list_products.route(.get, "/products?q=widget", "") == null);
}
