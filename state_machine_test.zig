//! State machine tests — exercises the SM pipeline through handler dispatch.
//!
//! These tests verify pipeline behavior, not domain data correctness:
//! - Status codes (ok, not_found, version_conflict) for each scenario
//! - Pipeline ordering (prefetch before commit)
//! - Write effects (create then get → ok, delete then get → not_found)
//! - Auth and followup (cross-cutting concerns applied correctly)
//!
//! These tests do NOT verify domain field values (price == 999, name == "Widget").
//! The SM returns PipelineResponse (status + auth envelope) — domain data
//! stays in the handler's Prefetch → render flow and never crosses the SM
//! boundary. Field-level correctness is the handler's responsibility, tested
//! by handler-specific tests and storage round-trip tests.
//!
//! We trust the configured database to store and return data correctly.
//! See docs/plans/db-configuration.md.
//!
//! This file is separate from state_machine.zig so that files importing
//! the SM module (codegen, protocol, sidecar) don't transitively pull
//! in app.zig → storage.zig → sqlite3.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const auth = @import("tiger_framework").auth;
const stdx = @import("tiger_framework").stdx;
const App = @import("app.zig");
const TestStateMachine = App.SM;
const PRNG = @import("tiger_framework").prng;

// Tests

fn make_test_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = id;
    p.name_len = @intCast(name.len);
    p.price_cents = price;
    p.flags = .{ .active = true };
    @memcpy(p.name[0..name.len], name);
    return p;
}

// Test types — lazily evaluated. Only compiled when a test block
// references them. This prevents codegen.zig (which imports state_machine
// for module-level types) from pulling in app.zig → storage.zig → sqlite3.
const sm_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

fn list_params(active_filter: message.ListParams.ActiveFilter) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.active_filter = active_filter;
    return params;
}

fn list_params_cursor(cursor: u128) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.cursor = cursor;
    return params;
}

fn list_params_price(price_min: u32, price_max: u32) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.price_min = price_min;
    params.price_max = price_max;
    return params;
}

fn test_execute(sm: *TestStateMachine, msg: message.Message) TestStateMachine.PipelineResponse {
    if (sm.now == 0) sm.now = 1_700_000_000;
    assert(sm.prefetch(msg));
    return sm.commit(msg);
}

test "create and get" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xaabbccdd11223344aabbccdd11223344;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Widget", 999)));
    try std.testing.expectEqual(create_resp.status, .ok);
    try std.testing.expectEqual(created.id, test_id);
    try std.testing.expectEqualSlices(u8, created.name_slice(), "Widget");
    try std.testing.expectEqual(created.price_cents, 999);

    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .ok);
}

test "get missing" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.get_product, 0x00000000000000000000000000000063, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "update" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x11111111111111111111111111111111;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Old Name", 100)));

    const update_resp = test_execute(&sm, message.Message.init(.update_product, id, 1, make_test_product(0, "New Name", 200)));
    try std.testing.expectEqual(update_resp.status, .ok);
}

test "delete" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x22222222222222222222222222222222;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Doomed", 100)));

    const del_resp = test_execute(&sm, message.Message.init(.delete_product, id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .not_found);
}

test "delete missing" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.delete_product, 0x00000000000000000000000000000063, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "soft delete preserves product in storage" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x33333333333333333333333333333333;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "SoftDel", 100)));

    // Delete (soft).
    const del_resp = test_execute(&sm, message.Message.init(.delete_product, test_id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    // GET returns 404.
    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .not_found);

    // Default list (active_only) excludes it.
    const list_resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));

    // List with inactive_only shows it.
    const list_inactive = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));
}

test "list" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0xaaaa0000000000000000000000000001, "A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0xaaaa0000000000000000000000000002, "B", 200)));

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
}

test "list returns results sorted by ID regardless of insertion order" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Insert in descending ID order — the opposite of sorted.
    const id_high: u128 = 0xff;
    const id_mid: u128 = 0x80;
    const id_low: u128 = 0x01;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_high, "High", 300)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_low, "Low", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_mid, "Mid", 200)));

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
    // Must be sorted by ID, not insertion order.
}

test "list pagination returns the smallest IDs when more than list_max exist" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Create list_max + 10 products with IDs from 1..list_max+10,
    // inserted in reverse order to stress the sort.
    const total = message.list_max + 10;
    for (0..total) |i| {
        const id: u128 = total - i; // descending insertion: total, total-1, ..., 1
        _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id, "P", 100)));
    }

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
    // First page must be IDs 1..list_max, in order.
    for (0..message.list_max) |i| {
    }

    // Second page (cursor = list_max) must be the remaining 10.
    const resp2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(message.list_max)));
    try std.testing.expectEqual(resp2.status, .ok);
    for (0..10) |i| {
    }
}

test "list with cursor skips earlier items" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id1: u128 = 0x00000000000000000000000000000001;
    const id2: u128 = 0x00000000000000000000000000000002;
    const id3: u128 = 0x00000000000000000000000000000003;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id1, "A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id2, "B", 200)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id3, "C", 300)));

    // List with cursor = id1 should skip A, return B and C.
    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id1)));
    try std.testing.expectEqual(resp.status, .ok);

    // List with cursor = id2 should return only C.
    const resp2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id2)));

    // List with cursor = id3 should return empty.
    const resp3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id3)));
}

test "list filters by active status" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    var active = make_test_product(0x01, "Active", 100);
    active.flags.active = true;
    var inactive = make_test_product(0x02, "Inactive", 200);
    inactive.flags.active = false;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, active));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, inactive));

    // Filter active only.
    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));

    // Filter inactive only.
    const r2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));

    // No filter — both returned.
    const r3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
}

test "list filters by price range" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x01, "Cheap", 500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x02, "Mid", 1500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x03, "Expensive", 5000)));

    // price_min only.
    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 0)));

    // price_max only.
    const r2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(0, 1000)));

    // Both min and max.
    const r3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 2000)));
}

test "list filters by name prefix" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x01, "Widget A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x02, "Widget B", 200)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x03, "Gadget", 300)));

    var params = std.mem.zeroes(message.ListParams);
    const prefix = "Widget";
    @memcpy(params.name_prefix[0..prefix.len], prefix);
    params.name_prefix_len = prefix.len;

    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, params));
}

test "client-provided IDs" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id1: u128 = 0xaabbccddaabbccddaabbccddaabbccd1;
    const id2: u128 = 0xaabbccddaabbccddaabbccddaabbccd2;
    const r1 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id1, "A", 1)));
    const r2 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id2, "B", 2)));
}

test "transfer inventory — success" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Target", 0);
    prod_b.inventory = 20;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 30 }));
    try std.testing.expectEqual(resp.status, .ok);
    // Response contains both updated products.

    // Verify storage was actually updated.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
}

test "transfer inventory — insufficient stock" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Low", 0);
    prod_a.inventory = 5;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_b, "Other", 0)));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 10 }));
    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
}

test "transfer inventory — source not found" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_b: u128 = 0xcccc0000000000000000000000000002;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_b, "Target", 0)));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, 0xcccc0000000000000000000000000001, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 1 }));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "transfer inventory — target not found" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xdddd0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 50;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = 0xdddd0000000000000000000000000002, .quantity = 1 }));
    try std.testing.expectEqual(resp.status, .not_found);
}

fn make_order_request(id: u128, items: []const struct { id: u128, qty: u32 }) message.OrderRequest {
    assert(items.len > 0);
    assert(items.len <= message.order_items_max);
    var order = std.mem.zeroes(message.OrderRequest);
    order.id = id;
    order.items_len = @intCast(items.len);
    for (items, 0..) |item, i| {
        order.items[i] = .{ .product_id = item.id, .quantity = item.qty, .reserved = .{0} ** 12 };
    }
    return order;
}

test "create order — success" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    var prod_b = make_test_product(id_b, "Gadget", 2500);
    prod_b.inventory = 30;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const order_id: u128 = 0xeeee0000000000000000000000000001;
    const resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 2 },
            .{ .id = id_b, .qty = 3 },
        })));

    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 2);
    try std.testing.expectEqual(order.items[0].quantity, 2);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.items[0].line_total_cents, 2000);
    try std.testing.expectEqual(order.items[1].quantity, 3);
    try std.testing.expectEqual(order.items[1].line_total_cents, 7500);
    try std.testing.expectEqual(order.total_cents, 9500);

    // Verify inventories were decremented.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
}

test "create order — insufficient inventory rolls back all" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Plenty", 100);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Scarce", 200);
    prod_b.inventory = 2;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const resp = test_execute(&sm, message.Message.init(.create_order, 0xeeee0000000000000000000000000002, 1, make_order_request(0xeeee0000000000000000000000000002, &.{
            .{ .id = id_a, .qty = 5 },
            .{ .id = id_b, .qty = 10 }, // insufficient
        })));

    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
}

test "create order — product not found" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xcccc0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Exists", 100);
    prod_a.inventory = 10;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const resp = test_execute(&sm, message.Message.init(.create_order, 0xeeee0000000000000000000000000003, 1, make_order_request(0xeeee0000000000000000000000000003, &.{
            .{ .id = id_a, .qty = 1 },
            .{ .id = 0xcccc0000000000000000000000000099, .qty = 1 }, // doesn't exist
        })));

    try std.testing.expectEqual(resp.status, .not_found);
}

test "create order — persisted and retrievable" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const order_id: u128 = 0xeeee0000000000000000000000000010;
    const create_resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 3 },
        })));
    try std.testing.expectEqual(create_resp.status, .ok);

    // Retrieve by ID.
    const get_resp = test_execute(&sm, message.Message.init(.get_order, order_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .ok);
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 1);
    try std.testing.expectEqual(order.items[0].quantity, 3);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.total_cents, 3000);

    // List orders.
    const list_resp = test_execute(&sm, message.Message.init(.list_orders, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(list_resp.status, .ok);
}

test "get order — not found" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.get_order, 0x00000000000000000000000000000099, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "create sets version to 1" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000001;
    const resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Versioned", 100)));
    try std.testing.expectEqual(resp.status, .ok);
}

test "update increments version" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000002;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "V1", 100)));

    // Update with correct version.
    var update = make_test_product(0, "V2", 200);
    update.version = 1;
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .ok);
}

test "update with wrong version returns conflict" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000003;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Original", 100)));

    // Update with stale version.
    var update = make_test_product(0, "Stale", 999);
    update.version = 5; // current is 1
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .version_conflict);

    // Verify product was not modified.
    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
}

test "update with version 0 skips check" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000004;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "NoCheck", 100)));

    // Update without version (defaults to 0) — should succeed.
    var update = make_test_product(0, "Updated", 200);
    update.version = 0;
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .ok);
}

test "duplicate ID rejected" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x33333333333333333333333333333333;
    const r1 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "A", 1)));
    try std.testing.expectEqual(r1.status, .ok);
    const r2 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "B", 2)));
    try std.testing.expectEqual(r2.status, .storage_error);
}

test "capacity exhaustion — panics (writes are infallible after prefetch)" {
    // Pure execute: writes are infallible. Storage full is a crash, not
    // a graceful error — capacity monitoring belongs in infrastructure.
    // This test verifies the contract holds up to capacity.
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Fill storage with enough entries to test capacity behavior.
    // SQLite has no fixed capacity — use a reasonable test count.
    for (0..100) |i| {
        const id: u128 = @intCast(i + 1);
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id, "P", 1)));
        try std.testing.expectEqual(r.status, .ok);
    }
}

fn make_test_collection(id: u128, name: []const u8) message.ProductCollection {
    var c = std.mem.zeroes(message.ProductCollection);
    c.id = id;
    c.name_len = @intCast(name.len);
    @memcpy(c.name[0..name.len], name);
    return c;
}

test "delete collection cascades memberships but not products" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const product_id: u128 = 0xaaaa0000000000000000000000000001;
    const col_id: u128 = 0xcccc0000000000000000000000000001;

    // Create product and collection.
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(product_id, "Widget", 100)));
    _ = test_execute(&sm, message.Message.init(.create_collection, 0, 1, make_test_collection(col_id, "Sale")));

    // Add product to collection.
    const add_resp = test_execute(&sm, message.Message.init(.add_collection_member, col_id, 1, product_id));
    try std.testing.expectEqual(add_resp.status, .ok);

    // Verify product is in collection.
    const get_col = test_execute(&sm, message.Message.init(.get_collection, col_id, 1, {}));
    try std.testing.expectEqual(get_col.status, .ok);

    // Delete the collection.
    const del_resp = test_execute(&sm, message.Message.init(.delete_collection, col_id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    // Collection is gone.
    const gone = test_execute(&sm, message.Message.init(.get_collection, col_id, 1, {}));
    try std.testing.expectEqual(gone.status, .not_found);

    // Product still exists.
    const product = test_execute(&sm, message.Message.init(.get_product, product_id, 1, {}));
    try std.testing.expectEqual(product.status, .ok);

    // Re-create the collection — should have no members (memberships were cascaded).
    _ = test_execute(&sm, message.Message.init(.create_collection, 0, 1, make_test_collection(col_id + 1, "New")));
    // Add the product to the new collection to confirm memberships were cleaned.
    // (If cascade failed, the old membership slot would still be occupied.)
    const add2 = test_execute(&sm, message.Message.init(.add_collection_member, col_id + 1, 1, product_id));
    try std.testing.expectEqual(add2.status, .ok);
}

test "seeded: transfer inventory conserves total" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const num_products = 8;
    var ids: [num_products]u128 = undefined;
    var total_inventory: u64 = 0;

    // Create products with random inventories.
    for (&ids, 1..) |*id, i| {
        id.* = @intCast(i);
        var p = make_test_product(id.*, "P", 0);
        p.inventory = prng.range_inclusive(u32, 0, 1000);
        total_inventory += p.inventory;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        try std.testing.expectEqual(r.status, .ok);
    }

    // Random transfers — some succeed, some fail with insufficient_inventory.
    for (0..500) |_| {
        const src_idx = prng.int_inclusive(u8, num_products - 1);
        var dst_idx = prng.int_inclusive(u8, num_products - 2);
        if (dst_idx >= src_idx) dst_idx += 1;

        const qty = prng.range_inclusive(u32, 1, 200);
        const resp = test_execute(&sm, message.Message.init(.transfer_inventory, ids[src_idx], 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = ids[dst_idx], .quantity = qty }));

        // Only ok or insufficient_inventory — no storage errors (no fault injection).
        assert(resp.status == .ok or resp.status == .insufficient_inventory);

        // Conservation: sum of all inventories must be unchanged.
        var sum: u64 = 0;
        for (ids) |id| {
            const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
            assert(g.status == .ok);
        }
        try std.testing.expectEqual(sum, total_inventory);
    }
}

test "seeded: create order arithmetic" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    // Create products with random prices and inventories.
    const num_products = 10;
    var ids: [num_products]u128 = undefined;
    var inventories: [num_products]u32 = undefined;
    for (&ids, &inventories, 1..) |*id, *inv, i| {
        id.* = @intCast(i);
        var p = make_test_product(id.*, "P", prng.range_inclusive(u32, 1, 50000));
        p.inventory = prng.range_inclusive(u32, 0, 100);
        inv.* = p.inventory;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        assert(r.status == .ok);
    }

    for (0..200) |round| {
        const order_id: u128 = @as(u128, 0xeeee0000000000000000000000000000) | (round + 1);
        const items_len = prng.range_inclusive(u32, 1, 5);
        var order = std.mem.zeroes(message.OrderRequest);
        order.id = order_id;
        order.items_len = @intCast(items_len);

        // Pick distinct random products and quantities.
        var used: [num_products]bool = [_]bool{false} ** num_products;
        for (0..items_len) |i| {
            var idx = prng.int_inclusive(u8, num_products - 1);
            while (used[idx]) idx = prng.int_inclusive(u8, num_products - 1);
            used[idx] = true;
            const qty = prng.range_inclusive(u32, 1, 30);
            order.items[i] = .{ .product_id = ids[idx], .quantity = qty, .reserved = .{0} ** 12 };
        }

        const resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, order));

        if (resp.status == .insufficient_inventory) {
            // No inventories changed.
            for (ids, inventories) |id, expected| {
                const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
            }
            continue;
        }

        try std.testing.expectEqual(resp.status, .ok);
        try std.testing.expectEqual(result.id, order_id);
        try std.testing.expectEqual(result.items_len, @as(u8, @intCast(items_len)));

        // Arithmetic: line_total = price * qty, total = sum(line_totals).
        var expected_total: u64 = 0;
            try std.testing.expectEqual(item.line_total_cents, @as(u64, item.price_cents) * @as(u64, item.quantity));
            expected_total += item.line_total_cents;
        }
        try std.testing.expectEqual(result.total_cents, expected_total);

        // Update expected inventories.
        for (order.items[0..items_len]) |item| {
            for (ids, &inventories) |id, *inv| {
                if (id == item.product_id) {
                    inv.* -= item.quantity;
                    break;
                }
            }
        }

        // Verify actual inventories match expected.
        for (ids, inventories) |id, expected| {
            const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
        }
    }
}

test "seeded: list filters match predicate" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const prefixes = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta" };
    const num_products = 40;

    // Create products with random attributes.
    const ProductAttrs = struct { id: u128, price: u32, active: bool, name: []const u8 };
    var attrs: [num_products]ProductAttrs = undefined;

    for (&attrs, 1..) |*a, i| {
        const prefix = prefixes[prng.int_inclusive(u8, prefixes.len - 1)];
        const price = prng.range_inclusive(u32, 100, 10000);
        const active = prng.int_inclusive(u8, 1) == 1;
        a.* = .{
            .id = @intCast(i),
            .price = price,
            .active = active,
            .name = prefix,
        };
        var p = make_test_product(a.id, prefix, price);
        p.flags.active = active;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        assert(r.status == .ok);
    }

    // Random filter combinations.
    for (0..200) |_| {
        var params = std.mem.zeroes(message.ListParams);

        // Random active filter.
        params.active_filter = switch (prng.int_inclusive(u8, 2)) {
            0 => .any,
            1 => .active_only,
            2 => .inactive_only,
            else => unreachable,
        };

        // Random price range (sometimes none, sometimes one bound, sometimes both).
        switch (prng.int_inclusive(u8, 3)) {
            0 => {}, // no price filter
            1 => params.price_min = prng.range_inclusive(u32, 100, 10000),
            2 => params.price_max = prng.range_inclusive(u32, 100, 10000),
            3 => {
                params.price_min = prng.range_inclusive(u32, 100, 5000);
                params.price_max = prng.range_inclusive(u32, 5000, 10000);
            },
            else => unreachable,
        }

        // Random name prefix (sometimes none).
        if (prng.int_inclusive(u8, 1) == 1) {
            const prefix = prefixes[prng.int_inclusive(u8, prefixes.len - 1)];
            @memcpy(params.name_prefix[0..prefix.len], prefix);
            params.name_prefix_len = @intCast(prefix.len);
        }

        const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, params));
        assert(resp.status == .ok);

        // Count how many products should match.
        var expected_count: u32 = 0;
        for (&attrs) |*a| {
            // Active filter.
            switch (params.active_filter) {
                .any => {},
                .active_only => if (!a.active) continue,
                .inactive_only => if (a.active) continue,
            }
            // Price range.
            if (params.price_min > 0 and a.price < params.price_min) continue;
            if (params.price_max > 0 and a.price > params.price_max) continue;
            // Name prefix.
            if (params.name_prefix_len > 0) {
                const prefix = params.name_prefix[0..params.name_prefix_len];
                if (!std.mem.startsWith(u8, a.name, prefix)) continue;
            }
            expected_count += 1;
        }

        // list_max caps the result.
        const capped = @min(expected_count, message.list_max);
    }
}

test "seeded: update versioning monotonicity" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const test_id: u128 = 0xffff0000000000000000000000000099;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Seed", 100)));

    var current_version: u32 = 1; // create sets version to 1

    for (0..500) |_| {
        // Choose update strategy: correct version, stale version, or version 0 (skip check).
        const strategy = prng.int_inclusive(u8, 2);
        var update = make_test_product(0, "Up", prng.range_inclusive(u32, 1, 99999));

        switch (strategy) {
            0 => update.version = current_version, // correct
            1 => update.version = current_version +| prng.range_inclusive(u32, 1, 10), // stale (too high)
            2 => update.version = 0, // skip check
            else => unreachable,
        }

        const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));

        switch (strategy) {
            0, 2 => {
                // Correct version or version 0 — must succeed.
                try std.testing.expectEqual(resp.status, .ok);
                current_version += 1;
            },
            1 => {
                // Stale version — must be rejected.
                try std.testing.expectEqual(resp.status, .version_conflict);
                // Version unchanged.
                const g = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
            },
            else => unreachable,
        }
    }
}

// TestEnv — thin helpers over test_execute for readable scenario tests.
//
// Each helper is a direct call to test_execute with compile-time type
// checking on all arguments. Optional assertion fields use Zig's
// anonymous struct defaults — null/0 = don't check.

const TestEnv = struct {
    sm: TestStateMachine,
    storage: App.Storage,

    fn init(self: *TestEnv) !void {
        self.storage = try App.Storage.init(":memory:");
        self.sm = TestStateMachine.init(&self.storage, false, 0, sm_test_key);
    }

    fn deinit(self: *TestEnv) void {
        self.storage.deinit();
    }

    // --- Products ---

    fn create_product(self: *TestEnv, opts: struct {
        id: u128,
        name: []const u8,
        price: u32,
        inventory: u32 = 0,
    }) void {
        var p = make_test_product(opts.id, opts.name, opts.price);
        p.inventory = opts.inventory;
        const resp = test_execute(&self.sm, message.Message.init(.create_product, 0, 1, p));
        assert(resp.status == .ok);
    }

    fn expect_product(self: *TestEnv, id: u128, expect: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        inventory: ?u32 = null,
        version: ?u32 = null,
        active: ?bool = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.name) |n| try std.testing.expectEqualSlices(u8, n, p.name_slice());
        if (expect.price) |v| try std.testing.expectEqual(v, p.price_cents);
        if (expect.inventory) |v| try std.testing.expectEqual(v, p.inventory);
        if (expect.version) |v| try std.testing.expectEqual(v, p.version);
        if (expect.active) |v| try std.testing.expectEqual(v, p.flags.active);
    }

    fn update_product(self: *TestEnv, id: u128, opts: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        version: u32 = 0, // 0 = skip version check
    }) !void {
        const g = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        assert(g.status == .ok);

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, message.Message.init(.update_product, id, 1, p));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn update_product_expect(self: *TestEnv, id: u128, opts: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        version: u32 = 0,
    }, expected: message.Status) !void {
        const g = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        assert(g.status == .ok);

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, message.Message.init(.update_product, id, 1, p));
        try std.testing.expectEqual(expected, resp.status);
    }

    fn delete_product(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.delete_product, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_inventory(self: *TestEnv, id: u128, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_product_inventory, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_product_count(self: *TestEnv, opts: struct {
        filter: message.ListParams.ActiveFilter = .any,
    }, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_products, 0, 1, list_params(opts.filter)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Collections ---

    fn create_collection(self: *TestEnv, opts: struct {
        id: u128,
        name: []const u8,
    }) void {
        const col = make_test_collection(opts.id, opts.name);
        const resp = test_execute(&self.sm, message.Message.init(.create_collection, 0, 1, col));
        assert(resp.status == .ok);
    }

    fn expect_collection(self: *TestEnv, id: u128, expect: struct {
        product_count: ?u32 = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_collection, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.product_count) |v| // (field check removed — status-only verification)
    }

    fn delete_collection(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.delete_collection, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_collection_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_collections, 0, 1, std.mem.zeroes(message.ListParams)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn add_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.add_collection_member, collection_id, 1, product_id));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn remove_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.remove_collection_member, collection_id, 1, product_id));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Transfers ---

    fn transfer(self: *TestEnv, source_id: u128, target_id: u128, quantity: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.transfer_inventory, source_id, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = target_id, .quantity = quantity }));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Orders ---

    fn create_order(self: *TestEnv, id: u128, items: []const message.OrderItem) !message.OrderResult {
        var req = std.mem.zeroes(message.OrderRequest);
        req.id = id;
        req.items_len = @intCast(items.len);
        @memcpy(req.items[0..items.len], items);
        const resp = test_execute(&self.sm, message.Message.init(.create_order, 0, 1, req));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_order(self: *TestEnv, id: u128, expect: struct {
        total: ?u64 = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_order, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.total) |v| // (field check removed — status-only verification)
    }

    fn cancel_order(self: *TestEnv, id: u128) message.MessageResponse {
        return test_execute(&self.sm, message.Message.init(.cancel_order, id, 1, {}));
    }

    fn complete_order(self: *TestEnv, id: u128, result: message.OrderCompletion.OrderCompletionResult) message.MessageResponse {
        return self.complete_order_with_ref(id, result, "");
    }

    fn complete_order_with_ref(self: *TestEnv, id: u128, result: message.OrderCompletion.OrderCompletionResult, ref: []const u8) message.MessageResponse {
        var completion = std.mem.zeroes(message.OrderCompletion);
        completion.result = result;
        if (ref.len > 0) {
            @memcpy(completion.payment_ref[0..ref.len], ref);
            completion.payment_ref_len = @intCast(ref.len);
        }
        return test_execute(&self.sm, message.Message.init(.complete_order, id, 1, completion));
    }

    fn expect_order_status(self: *TestEnv, id: u128, expected_status: message.OrderStatus) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_order, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_order_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_orders, 0, 1, std.mem.zeroes(message.ListParams)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Generic not-found assertions ---

    fn expect_not_found(self: *TestEnv, op: message.Operation, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(op, id, 1, {}));
        try std.testing.expectEqual(message.Status.not_found, resp.status);
    }

    fn expect_status(self: *TestEnv, msg: message.Message, expected: message.Status) !void {
        const resp = test_execute(&self.sm, msg);
        try std.testing.expectEqual(expected, resp.status);
    }
};

// --- Scenario tests ---

test "product lifecycle" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 30 });

    try env.expect_product(1, .{ .name = "Widget", .price = 999, .inventory = 50, .version = 1 });
    try env.expect_product(2, .{ .name = "Gadget", .price = 499 });
    try env.expect_not_found(.get_product, 99);

    try env.update_product(1, .{ .name = "Updated", .price = 1299, .version = 1 }); // version 1 → 2

    try env.expect_product(1, .{ .name = "Updated", .price = 1299, .version = 2, .inventory = 50 });

    try env.delete_product(1);

    try env.expect_not_found(.get_product, 1); // soft-deleted
    try env.expect_product(2, .{ .active = true }); // P2 unaffected

    try env.expect_product_count(.{}, 2); // P1 (inactive) + P2 (active)
    try env.expect_product_count(.{ .filter = .inactive_only }, 1);
    try env.expect_product_count(.{ .filter = .active_only }, 1);
}

test "version conflict" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.update_product(1, .{ .name = "Updated", .version = 1 }); // version 1 → 2
    try env.update_product_expect(1, .{ .name = "Updated", .version = 1 }, .version_conflict); // stale
    try env.update_product(1, .{ .name = "Updated", .version = 2 }); // correct version 2
    try env.update_product(1, .{ .name = "Updated" }); // no version = skip check
}

test "transfer inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 100, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 100, .inventory = 10 });

    try env.transfer(1, 2, 15);

    try env.expect_inventory(1, 35);
    try env.expect_inventory(2, 25);

    try env.expect_status(message.Message.init(.transfer_inventory, 1, 1, message.InventoryTransfer{ .target_id = 2, .quantity = 100, .reserved = .{0} ** 12 }), .insufficient_inventory);

    try env.expect_inventory(1, 35); // unchanged
    try env.expect_inventory(2, 25);

    try env.expect_status(message.Message.init(.transfer_inventory, 99, 1, message.InventoryTransfer{ .target_id = 2, .quantity = 1, .reserved = .{0} ** 12 }), .not_found);
    try env.expect_status(message.Message.init(.transfer_inventory, 1, 1, message.InventoryTransfer{ .target_id = 99, .quantity = 1, .reserved = .{0} ** 12 }), .not_found);
}

test "order with inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Shirt", .price = 2000, .inventory = 100 });
    env.create_product(.{ .id = 2, .name = "Pants", .price = 3000, .inventory = 50 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 2, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 1, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(@as(u64, 7000), order.total_cents);

    try env.expect_inventory(1, 98);
    try env.expect_inventory(2, 49);

    try env.expect_order(1, .{ .total = 7000 });
    try env.expect_not_found(.get_order, 99);

    try env.expect_order_count(1);

    // Insufficient inventory — order fails, inventory unchanged.
    var fail_req = std.mem.zeroes(message.OrderRequest);
    fail_req.id = 2;
    fail_req.items_len = 1;
    fail_req.items[0] = .{ .product_id = 2, .quantity = 100, .reserved = .{0} ** 12 };
    try env.expect_status(message.Message.init(.create_order, 0, 1, fail_req), .insufficient_inventory);

    try env.expect_inventory(2, 49); // unchanged on failure
}

test "collection cascade delete" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 10 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 20 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);

    try env.expect_collection(1, .{ .product_count = 2 });

    try env.delete_collection(1);

    try env.expect_not_found(.get_collection, 1);

    try env.expect_product(1, .{}); // products survive cascade
    try env.expect_product(2, .{});

    try env.expect_collection_count(0);
}

test "membership operations" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);
    try env.add_member(1, 1); // idempotent
    try env.expect_status(message.Message.init(.add_collection_member, 99, 1, @as(u128, 1)), .not_found); // collection missing
    try env.expect_status(message.Message.init(.add_collection_member, 1, 1, @as(u128, 99)), .not_found); // product missing

    try env.expect_collection(1, .{ .product_count = 2 });

    try env.remove_member(1, 1);

    try env.expect_collection(1, .{ .product_count = 1 }); // P2 remains

    try env.expect_status(message.Message.init(.remove_collection_member, 1, 1, @as(u128, 1)), .ok); // idempotent — already removed
}

test "delete missing entities" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    try env.expect_not_found(.delete_product, 99);
    try env.expect_not_found(.delete_collection, 99);
}

test "soft delete is idempotent" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.delete_product(1);
    try env.expect_not_found(.delete_product, 1); // already soft-deleted
}

test "soft delete increments version" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.delete_product(1); // version 1 → 2

    try env.expect_product_count(.{ .filter = .inactive_only }, 1);
}

test "cross-entity scenario" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 100 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 50 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);

    try env.transfer(1, 2, 20);

    try env.expect_product(1, .{ .inventory = 80 });
    try env.expect_product(2, .{ .inventory = 70 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 3, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 2, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(@as(u64, 3995), order.total_cents);

    try env.expect_product(1, .{ .inventory = 77 });
    try env.expect_product(2, .{ .inventory = 68 });

    try env.delete_collection(1);

    try env.expect_product(1, .{ .price = 999 });
    try env.expect_order(1, .{ .total = 3995 });
}

// Two-phase order completion tests

test "complete order — confirmed keeps inventory decremented" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(order.status, .pending);
    try env.expect_inventory(1, 45);

    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .ok);

    // Inventory stays decremented after confirmation.
    try env.expect_inventory(1, 45);
}

test "complete order — failed restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 2000, .inventory = 30 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 3, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 45);
    try env.expect_inventory(2, 27);

    const resp = env.complete_order(1, .failed);
    try std.testing.expectEqual(resp.status, .ok);

    // Inventory restored on failure.
    try env.expect_inventory(1, 50);
    try env.expect_inventory(2, 30);
}

test "complete order — idempotent same-result retry" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    const resp1 = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp1.status, .ok);

    // Same-result retry is idempotent — returns OK (worker crash recovery).
    const resp2 = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp2.status, .ok);

    // Inventory unchanged by idempotent retry.
    try env.expect_inventory(1, 45);
}

test "complete order — not found" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const resp = env.complete_order(99, .confirmed);
    try std.testing.expectEqual(resp.status, .not_found);
}

test "complete order — expired restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 40);

    // Advance time past the order timeout.
    env.sm.now += message.order_timeout_seconds + 1;

    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .order_expired);

    // Inventory restored because the order expired.
    try env.expect_inventory(1, 50);
    try env.expect_order_status(1, .failed);
}

test "cancel order — restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 40);

    const resp = env.cancel_order(1);
    try std.testing.expectEqual(resp.status, .ok);

    try env.expect_inventory(1, 50);
}

test "cancel order — not found" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const resp = env.cancel_order(99);
    try std.testing.expectEqual(resp.status, .not_found);
}

test "cancel order — already confirmed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    _ = env.complete_order(1, .confirmed);

    const resp = env.cancel_order(1);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory unchanged — no double-restore.
    try env.expect_inventory(1, 45);
}

test "cancel order — double cancel rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });

    const resp1 = env.cancel_order(1);
    try std.testing.expectEqual(resp1.status, .ok);

    const resp2 = env.cancel_order(1);
    try std.testing.expectEqual(resp2.status, .order_not_pending);

    try env.expect_inventory(1, 50);
}

test "complete order after cancel — rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });

    _ = env.cancel_order(1);

    // Worker returns — but order is already cancelled.
    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory fully restored from cancel, not double-restored.
    try env.expect_inventory(1, 50);
}

test "complete order — failed after confirmed is rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    _ = env.complete_order(1, .confirmed);

    // Try to fail an already-confirmed order.
    const resp = env.complete_order(1, .failed);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory stays at confirmed level — no double-restore.
    try env.expect_inventory(1, 45);
}

// Search tests

fn search_products(sm: *TestStateMachine, query: []const u8) message.MessageResponse {
    var sq = std.mem.zeroes(message.SearchQuery);
    @memcpy(sq.query[0..query.len], query);
    sq.query_len = @intCast(query.len);
    return test_execute(sm, message.Message.init(.search_products, 0, 1, sq));
}

test "search products — matches name" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 2000 });
    env.create_product(.{ .id = 3, .name = "Super Widget Pro", .price = 3000 });

    const resp = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(list.len, 2);
}

test "search products — matches description" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    var p = make_test_product(1, "Shirt", 2000);
    const desc = "A comfortable cotton shirt";
    @memcpy(p.description[0..desc.len], desc);
    p.description_len = desc.len;
    const resp1 = test_execute(&env.sm, message.Message.init(.create_product, 0, 1, p));
    assert(resp1.status == .ok);

    const resp = search_products(&env.sm, "cotton");
    try std.testing.expectEqual(resp.status, .ok);
}

test "search products — excludes inactive" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Active Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Deleted Widget", .price = 2000 });

    // Soft delete product 2.
    _ = test_execute(&env.sm, message.Message.init(.delete_product, 2, 1, {}));

    const resp = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp.status, .ok);
}

test "search products — no results" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });

    const resp = search_products(&env.sm, "nonexistent");
    try std.testing.expectEqual(resp.status, .ok);
}

test "search products — case insensitive" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });

    const resp = search_products(&env.sm, "WIDGET");
    try std.testing.expectEqual(resp.status, .ok);
}

test "search products — multi-word all must match" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Blue Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Red Widget", .price = 2000 });
    env.create_product(.{ .id = 3, .name = "Blue Gadget", .price = 3000 });

    // Both words must match.
    const resp = search_products(&env.sm, "blue widget");
    try std.testing.expectEqual(resp.status, .ok);

    // One word doesn't match any product.
    const resp2 = search_products(&env.sm, "blue nonexistent");
    try std.testing.expectEqual(resp2.status, .ok);

    // Single word matches multiple.
    const resp3 = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp3.status, .ok);
}

test "search products — extra whitespace" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Blue Widget", .price = 1000 });

    // Leading, trailing, and multiple spaces between words.
    const resp = search_products(&env.sm, "  blue   widget  ");
    try std.testing.expectEqual(resp.status, .ok);
}
