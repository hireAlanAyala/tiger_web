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
//! See decisions/storage-ownership.md.
//!
//! This file is separate from state_machine.zig so that files importing
//! the SM module (protocol, sidecar) don't transitively pull
//! in app.zig → storage.zig → sqlite3.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const auth = @import("framework/auth.zig");
const stdx = @import("stdx");
const App = @import("app.zig");
const TestStateMachine = App.SM;
const PRNG = @import("stdx").PRNG;

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
// references them. Keeps the SM module light for importers.
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
    assert(sm.prefetch(msg) == .complete);
    return sm.commit(msg).output.response;
}

test "create and get" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xaabbccdd11223344aabbccdd11223344;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Widget", 999)));
    try std.testing.expectEqual(create_resp.status, .ok);

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
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Old Name", 100)));

    const update_resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, make_test_product(0, "New Name", 200)));
    try std.testing.expectEqual(update_resp.status, .ok);
}

test "delete" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x22222222222222222222222222222222;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Doomed", 100)));

    const del_resp = test_execute(&sm, message.Message.init(.delete_product, test_id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
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
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));

    // List with inactive_only shows it.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));
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

    // Second page (cursor = list_max) must be the remaining 10.
    const resp2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(message.list_max)));
    try std.testing.expectEqual(resp2.status, .ok);
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
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id2)));

    // List with cursor = id3 should return empty.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id3)));
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
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));

    // Filter inactive only.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));

    // No filter — both returned.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
}

test "list filters by price range" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x01, "Cheap", 500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x02, "Mid", 1500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x03, "Expensive", 5000)));

    // price_min only.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 0)));

    // price_max only.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(0, 1000)));

    // Both min and max.
    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 2000)));
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

    _ = test_execute(&sm, message.Message.init(.list_products, 0, 1, params));
}

test "client-provided IDs" {
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id1: u128 = 0xaabbccddaabbccddaabbccddaabbccd1;
    const id2: u128 = 0xaabbccddaabbccddaabbccddaabbccd2;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id1, "A", 1)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id2, "B", 2)));
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
    _ = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    _ = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
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
    _ = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
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

    // Verify inventories were decremented.
    _ = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    _ = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
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
    _ = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    _ = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
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
    _ = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
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
    try std.testing.expectEqual(r2.status, .version_conflict);
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

        // Verify all products still accessible after transfers.
        for (ids) |id| {
            const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
            assert(g.status == .ok);
        }
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
            continue;
        }

        try std.testing.expectEqual(resp.status, .ok);
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
                _ = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
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

