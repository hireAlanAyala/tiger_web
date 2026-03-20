//! Integration test: wire get_product handler through AppType.
//! If this compiles, the handler's signatures pass comptime validation.

const std = @import("std");
const fw = @import("tiger_framework");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const get_product = @import("handlers/get_product.zig");

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
    const Context = fw.handler.HandlerContext(
        get_product.Prefetch,
        message.Operation.EventType(.get_product),
        message.PrefetchIdentity,
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
    const Context = fw.handler.HandlerContext(
        get_product.Prefetch,
        message.Operation.EventType(.get_product),
        message.PrefetchIdentity,
    );

    var product = std.mem.zeroes(get_product.ProductRow);
    product.id = 0xaabb;
    @memcpy(product.name[0..6], "Widget");
    product.name_len = 6;
    product.price_cents = 999;
    product.inventory = 42;
    product.version = 1;
    product.active = true;

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
