const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.state_machine));

/// Storage result type — shared by all storage backends.
pub const StorageResult = enum { ok, not_found, err, busy, corruption };

/// State machine parameterized on a Storage backend.
/// In production, Storage is SqliteStorage. In simulation, Storage is MemoryStorage.
///
/// Request processing is split into two phases (TigerBeetle style):
/// - `prefetch(msg)` reads from storage into cache slots. Read-only — never mutates
///   storage. Returns false if storage is busy (retry next tick).
/// - `execute(msg)` decides from cache slots, then writes mutations to storage.
pub fn StateMachineType(comptime Storage: type) type {
    return struct {
        const StateMachine = @This();

        storage: *Storage,

        // Prefetch cache — populated by prefetch(), consumed by execute().
        prefetch_product: ?message.Product,
        prefetch_product_list: message.MessageResponse.ProductList,
        prefetch_collection: ?message.ProductCollection,
        prefetch_collection_list: message.MessageResponse.CollectionList,
        prefetch_result: ?StorageResult,

        pub fn init(storage: *Storage) StateMachine {
            return .{
                .storage = storage,
                .prefetch_product = null,
                .prefetch_product_list = .{ .items = undefined, .len = 0 },
                .prefetch_collection = null,
                .prefetch_collection_list = .{ .items = undefined, .len = 0 },
                .prefetch_result = null,
            };
        }

        /// Phase 1: read data from storage into cache slots. Never writes.
        /// Returns true if prefetch completed (success or error).
        /// Returns false if storage is busy — connection stays .ready, retried next tick.
        pub fn prefetch(self: *StateMachine, msg: message.Message) bool {
            assert(self.prefetch_result == null);
            self.reset_prefetch_cache();

            const result: StorageResult = switch (msg.body) {
                .products => |product| switch (msg.operation) {
                    .get, .get_inventory => self.prefetch_read(msg.id),
                    .list => self.prefetch_list_products(),
                    .create => blk: {
                        const p = product.?;
                        assert(p.id > 0);
                        assert(p.name_len > 0);
                        break :blk self.prefetch_read(p.id);
                    },
                    .update => blk: {
                        assert(msg.id > 0);
                        assert(product.?.name_len > 0);
                        break :blk self.prefetch_read(msg.id);
                    },
                    .delete => self.prefetch_read(msg.id),
                    .add_member, .remove_member => unreachable,
                },
                .collections => |payload| switch (msg.operation) {
                    .get => self.prefetch_collection_with_products(msg.id),
                    .list => self.prefetch_list_all_collections(),
                    .create => blk: {
                        const col = payload.?.create;
                        assert(col.id > 0);
                        assert(col.name_len > 0);
                        break :blk self.prefetch_collection_read(col.id);
                    },
                    .delete => self.prefetch_collection_read(msg.id),
                    .add_member => blk: {
                        const product_id = payload.?.member;
                        // Read both collection and product to verify existence.
                        const r1 = self.prefetch_collection_read(msg.id);
                        if (r1 != .ok and r1 != .not_found) break :blk r1;
                        const r2 = self.prefetch_read(product_id);
                        if (r2 != .ok and r2 != .not_found) break :blk r2;
                        // Both must exist. Encode as: ok if both found,
                        // not_found if either missing.
                        if (r1 == .not_found or r2 == .not_found) break :blk .not_found;
                        break :blk .ok;
                    },
                    .remove_member => blk: {
                        // Just verify the collection exists.
                        break :blk self.prefetch_collection_read(msg.id);
                    },
                    .get_inventory, .update => unreachable,
                },
            };

            switch (result) {
                .busy => return false,
                .corruption => @panic("storage corruption in prefetch"),
                .ok, .not_found, .err => self.prefetch_result = result,
            }

            return true;
        }

        /// Phase 2: make decisions from cache slots, apply writes to storage.
        /// Reads only from prefetch cache for decisions. Writes go to storage here.
        /// Write failures (busy/err) return 503 — the client retries.
        /// Must only be called after prefetch() returned true.
        pub fn execute(self: *StateMachine, msg: message.Message) message.MessageResponse {
            const result = self.prefetch_result.?;
            defer self.reset_prefetch();

            // Storage read error — return 503 regardless of operation.
            if (result == .err) return switch (msg.body) {
                .products => storage_error_response(.products),
                .collections => storage_error_response(.collections),
            };

            return switch (msg.body) {
                .products => self.execute_products(msg, result),
                .collections => self.execute_collections(msg, result),
            };
        }

        fn execute_products(self: *StateMachine, msg: message.Message, result: StorageResult) message.MessageResponse {
            switch (msg.operation) {
                .get => {
                    if (result == .not_found) return message.MessageResponse.product_not_found;
                    assert(result == .ok);
                    return .{
                        .status = .ok,
                        .body = .{ .products = .{ .single = self.prefetch_product.? } },
                    };
                },
                .get_inventory => {
                    if (result == .not_found) return message.MessageResponse.product_not_found;
                    assert(result == .ok);
                    return .{
                        .status = .ok,
                        .body = .{ .products = .{ .inventory = self.prefetch_product.?.inventory } },
                    };
                },
                .list => {
                    assert(result == .ok);
                    return .{
                        .status = .ok,
                        .body = .{ .products = .{ .list = self.prefetch_product_list } },
                    };
                },
                .create => {
                    if (result == .ok) return storage_error_response(.products);
                    assert(result == .not_found);

                    const product = msg.body.products.?;
                    return self.commit_product_write(self.storage.put(&product), product);
                },
                .update => {
                    if (result == .not_found) return message.MessageResponse.product_not_found;
                    assert(result == .ok);

                    var updated = msg.body.products.?;
                    updated.id = msg.id;
                    return self.commit_product_write(self.storage.update(msg.id, &updated), updated);
                },
                .delete => {
                    if (result == .not_found) return message.MessageResponse.product_not_found;
                    assert(result == .ok);

                    return switch (self.storage.delete(msg.id)) {
                        .ok => message.MessageResponse.product_empty_ok,
                        .busy, .err => storage_error_response(.products),
                        .not_found => unreachable,
                        .corruption => @panic("storage corruption in execute"),
                    };
                },
                .add_member, .remove_member => unreachable,
            }
        }

        fn execute_collections(self: *StateMachine, msg: message.Message, result: StorageResult) message.MessageResponse {
            switch (msg.operation) {
                .get => {
                    if (result == .not_found) return message.MessageResponse.collection_not_found;
                    assert(result == .ok);
                    return .{
                        .status = .ok,
                        .body = .{ .collections = .{ .single = .{
                            .collection = self.prefetch_collection.?,
                            .products = self.prefetch_product_list,
                        } } },
                    };
                },
                .list => {
                    assert(result == .ok);
                    return .{
                        .status = .ok,
                        .body = .{ .collections = .{ .list = self.prefetch_collection_list } },
                    };
                },
                .create => {
                    if (result == .ok) return storage_error_response(.collections);
                    assert(result == .not_found);

                    const col = msg.body.collections.?.create;
                    return self.commit_collection_write(self.storage.put_collection(&col), col);
                },
                .delete => {
                    if (result == .not_found) return message.MessageResponse.collection_not_found;
                    assert(result == .ok);

                    return switch (self.storage.delete_collection(msg.id)) {
                        .ok => message.MessageResponse.collection_empty_ok,
                        .busy, .err => storage_error_response(.collections),
                        .not_found => unreachable,
                        .corruption => @panic("storage corruption in execute"),
                    };
                },
                .add_member => {
                    if (result == .not_found) return message.MessageResponse.collection_not_found;
                    assert(result == .ok);

                    const product_id = msg.body.collections.?.member;
                    return switch (self.storage.add_to_collection(msg.id, product_id)) {
                        .ok => message.MessageResponse.collection_empty_ok,
                        .busy, .err => storage_error_response(.collections),
                        .not_found => unreachable,
                        .corruption => @panic("storage corruption in execute"),
                    };
                },
                .remove_member => {
                    if (result == .not_found) return message.MessageResponse.collection_not_found;
                    assert(result == .ok);

                    const product_id = msg.body.collections.?.member;
                    return switch (self.storage.remove_from_collection(msg.id, product_id)) {
                        .ok => message.MessageResponse.collection_empty_ok,
                        .busy, .err => storage_error_response(.collections),
                        .not_found => message.MessageResponse.collection_not_found,
                        .corruption => @panic("storage corruption in execute"),
                    };
                },
                .get_inventory, .update => unreachable,
            }
        }

        fn commit_product_write(_: *StateMachine, write_result: StorageResult, product: message.Product) message.MessageResponse {
            return switch (write_result) {
                .ok => .{
                    .status = .ok,
                    .body = .{ .products = .{ .single = product } },
                },
                .busy, .err => storage_error_response(.products),
                .not_found => unreachable,
                .corruption => @panic("storage corruption in execute"),
            };
        }

        fn commit_collection_write(_: *StateMachine, write_result: StorageResult, col: message.ProductCollection) message.MessageResponse {
            return switch (write_result) {
                .ok => .{
                    .status = .ok,
                    .body = .{ .collections = .{ .single = .{
                        .collection = col,
                        .products = .{ .items = undefined, .len = 0 },
                    } } },
                },
                .busy, .err => storage_error_response(.collections),
                .not_found => unreachable,
                .corruption => @panic("storage corruption in execute"),
            };
        }

        fn storage_error_response(comptime collection: message.Collection) message.MessageResponse {
            return .{
                .status = .storage_error,
                .body = switch (collection) {
                    .products => .{ .products = .{ .empty = {} } },
                    .collections => .{ .collections = .{ .empty = {} } },
                },
            };
        }

        fn reset_prefetch(self: *StateMachine) void {
            self.prefetch_product = null;
            self.prefetch_product_list.len = 0;
            self.prefetch_collection = null;
            self.prefetch_collection_list.len = 0;
            self.prefetch_result = null;
        }

        fn reset_prefetch_cache(self: *StateMachine) void {
            self.prefetch_product = null;
            self.prefetch_product_list.len = 0;
            self.prefetch_collection = null;
            self.prefetch_collection_list.len = 0;
        }

        // --- Product prefetch helpers (read-only) ---

        fn prefetch_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var product: message.Product = undefined;
            const result = self.storage.get(id, &product);
            if (result == .ok) self.prefetch_product = product;
            return result;
        }

        fn prefetch_list_products(self: *StateMachine) StorageResult {
            return self.storage.list(&self.prefetch_product_list.items, &self.prefetch_product_list.len);
        }

        // --- Collection prefetch helpers (read-only) ---

        fn prefetch_collection_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var col: message.ProductCollection = undefined;
            const result = self.storage.get_collection(id, &col);
            if (result == .ok) self.prefetch_collection = col;
            return result;
        }

        fn prefetch_list_all_collections(self: *StateMachine) StorageResult {
            return self.storage.list_collections(&self.prefetch_collection_list.items, &self.prefetch_collection_list.len);
        }

        /// Prefetch both the collection and its member products.
        /// This is the multi-read that stresses the prefetch cache —
        /// two different entity types fetched in one prefetch phase.
        fn prefetch_collection_with_products(self: *StateMachine, collection_id: u128) StorageResult {
            assert(collection_id > 0);
            const r1 = self.prefetch_collection_read(collection_id);
            if (r1 != .ok) return r1;
            return self.storage.list_products_in_collection(
                collection_id,
                &self.prefetch_product_list.items,
                &self.prefetch_product_list.len,
            );
        }
    };
}

// =====================================================================
// In-memory storage — used for unit tests and sim tests.
// =====================================================================

pub const MemoryStorage = struct {
    pub const product_capacity = 1024;
    pub const collection_capacity = 256;
    pub const membership_capacity = 1024;

    const ProductEntry = struct {
        product: message.Product,
        occupied: bool,
    };

    const CollectionEntry = struct {
        collection: message.ProductCollection,
        occupied: bool,
    };

    const MembershipEntry = struct {
        collection_id: u128,
        product_id: u128,
        occupied: bool,
    };

    const empty_product = ProductEntry{ .product = undefined, .occupied = false };
    const empty_collection = CollectionEntry{ .collection = undefined, .occupied = false };
    const empty_membership = MembershipEntry{ .collection_id = 0, .product_id = 0, .occupied = false };

    products: *[product_capacity]ProductEntry,
    product_count: u32,
    collections_store: *[collection_capacity]CollectionEntry,
    collection_count: u32,
    memberships: *[membership_capacity]MembershipEntry,

    // Fault injection — PRNG-driven, same pattern as SimIO.
    prng_state: u64,
    busy_fault_probability: u8,
    err_fault_probability: u8,

    pub fn init(allocator: std.mem.Allocator) !MemoryStorage {
        const products = try allocator.create([product_capacity]ProductEntry);
        @memset(products, empty_product);
        const collections_store = try allocator.create([collection_capacity]CollectionEntry);
        @memset(collections_store, empty_collection);
        const memberships = try allocator.create([membership_capacity]MembershipEntry);
        @memset(memberships, empty_membership);
        return .{
            .products = products,
            .product_count = 0,
            .collections_store = collections_store,
            .collection_count = 0,
            .memberships = memberships,
            .prng_state = 0,
            .busy_fault_probability = 0,
            .err_fault_probability = 0,
        };
    }

    pub fn deinit(self: *MemoryStorage, allocator: std.mem.Allocator) void {
        allocator.destroy(self.products);
        allocator.destroy(self.collections_store);
        allocator.destroy(self.memberships);
    }

    pub fn reset(self: *MemoryStorage) void {
        @memset(self.products, empty_product);
        self.product_count = 0;
        @memset(self.collections_store, empty_collection);
        self.collection_count = 0;
        @memset(self.memberships, empty_membership);
    }

    pub fn get(self: *MemoryStorage, id: u128, out: *message.Product) StorageResult {
        if (self.fault()) |f| return f;
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                out.* = entry.product;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put(self: *MemoryStorage, product: *const message.Product) StorageResult {
        if (self.fault()) |f| return f;
        // Reject duplicates.
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == product.id) return .err;
        }
        for (self.products) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .product = product.*, .occupied = true };
                self.product_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn update(self: *MemoryStorage, id: u128, product: *const message.Product) StorageResult {
        if (self.fault()) |f| return f;
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.product = product.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn delete(self: *MemoryStorage, id: u128) StorageResult {
        if (self.fault()) |f| return f;
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.occupied = false;
                self.product_count -= 1;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list(self: *MemoryStorage, out: *[message.MessageResponse.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            assert(out_len.* < message.MessageResponse.list_max);
            out[out_len.*] = entry.product;
            out_len.* += 1;
        }
        return .ok;
    }

    // --- Collection operations ---

    pub fn get_collection(self: *MemoryStorage, id: u128, out: *message.ProductCollection) StorageResult {
        if (self.fault()) |f| return f;
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == id) {
                out.* = entry.collection;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_collection(self: *MemoryStorage, col: *const message.ProductCollection) StorageResult {
        if (self.fault()) |f| return f;
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == col.id) return .err;
        }
        for (self.collections_store) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .collection = col.*, .occupied = true };
                self.collection_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn delete_collection(self: *MemoryStorage, id: u128) StorageResult {
        if (self.fault()) |f| return f;
        var found = false;
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == id) {
                entry.occupied = false;
                self.collection_count -= 1;
                found = true;
                break;
            }
        }
        if (!found) return .not_found;
        // Cascade: remove memberships for this collection.
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == id) {
                m.occupied = false;
            }
        }
        return .ok;
    }

    pub fn list_collections(self: *MemoryStorage, out: *[message.MessageResponse.list_max]message.ProductCollection, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.collections_store) |*entry| {
            if (!entry.occupied) continue;
            assert(out_len.* < message.MessageResponse.list_max);
            out[out_len.*] = entry.collection;
            out_len.* += 1;
        }
        return .ok;
    }

    // --- Membership operations ---

    pub fn add_to_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        if (self.fault()) |f| return f;
        // Check for duplicate membership.
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == collection_id and m.product_id == product_id) return .ok;
        }
        for (self.memberships) |*m| {
            if (!m.occupied) {
                m.* = .{ .collection_id = collection_id, .product_id = product_id, .occupied = true };
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn remove_from_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        if (self.fault()) |f| return f;
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == collection_id and m.product_id == product_id) {
                m.occupied = false;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_products_in_collection(self: *MemoryStorage, collection_id: u128, out: *[message.MessageResponse.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.memberships) |*m| {
            if (!m.occupied or m.collection_id != collection_id) continue;
            // Look up the product.
            for (self.products) |*entry| {
                if (entry.occupied and entry.product.id == m.product_id) {
                    assert(out_len.* < message.MessageResponse.list_max);
                    out[out_len.*] = entry.product;
                    out_len.* += 1;
                    break;
                }
            }
        }
        return .ok;
    }

    /// Roll PRNG against fault probabilities. Returns a fault result or null.
    fn fault(self: *MemoryStorage) ?StorageResult {
        if (self.busy_fault_probability > 0) {
            if (self.prng_next() % 100 < self.busy_fault_probability) {
                log.mark.debug("storage: busy fault injected", .{});
                return .busy;
            }
        }
        if (self.err_fault_probability > 0) {
            if (self.prng_next() % 100 < self.err_fault_probability) {
                log.mark.debug("storage: err fault injected", .{});
                return .err;
            }
        }
        return null;
    }

    fn prng_next(self: *MemoryStorage) u64 {
        return splitmix64(&self.prng_state);
    }
};

/// SplitMix64 — same as TigerBeetle's PRNG seed expansion.
fn splitmix64(state: *u64) u64 {
    state.* +%= 0x9e3779b97f4a7c15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

// =====================================================================
// Tests
// =====================================================================

fn make_test_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = message.Product{
        .id = id,
        .name = undefined,
        .name_len = @intCast(name.len),
        .description = undefined,
        .description_len = 0,
        .price_cents = price,
        .inventory = 0,
        .active = true,
    };
    @memcpy(p.name[0..name.len], name);
    return p;
}

const TestStateMachine = StateMachineType(MemoryStorage);

fn test_execute(sm: *TestStateMachine, msg: message.Message) message.MessageResponse {
    assert(sm.prefetch(msg));
    return sm.execute(msg);
}

test "create and get" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0xaabbccdd11223344aabbccdd11223344;
    const create_resp = test_execute(&sm, .{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product(test_id, "Widget", 999) },
    });
    try std.testing.expectEqual(create_resp.status, .ok);
    const created = create_resp.body.products.single;
    try std.testing.expectEqual(created.id, test_id);
    try std.testing.expectEqualSlices(u8, created.name_slice(), "Widget");
    try std.testing.expectEqual(created.price_cents, 999);

    const get_resp = test_execute(&sm, .{
        .operation = .get,
        .id = test_id,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(get_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, get_resp.body.products.single.name_slice(), "Widget");
}

test "get missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const resp = test_execute(&sm, .{
        .operation = .get,
        .id = 0x00000000000000000000000000000063,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "update" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x11111111111111111111111111111111;
    const create_resp = test_execute(&sm, .{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product(test_id, "Old Name", 100) },
    });
    const id = create_resp.body.products.single.id;

    const update_resp = test_execute(&sm, .{
        .operation = .update,
        .id = id,
        .body = .{ .products = make_test_product(0, "New Name", 200) },
    });
    try std.testing.expectEqual(update_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, update_resp.body.products.single.name_slice(), "New Name");
    try std.testing.expectEqual(update_resp.body.products.single.price_cents, 200);
    try std.testing.expectEqual(update_resp.body.products.single.id, id);
}

test "delete" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x22222222222222222222222222222222;
    const create_resp = test_execute(&sm, .{
        .operation = .create,
        .id = 0,
        .body = .{ .products = make_test_product(test_id, "Doomed", 100) },
    });
    const id = create_resp.body.products.single.id;

    const del_resp = test_execute(&sm, .{
        .operation = .delete,
        .id = id,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = test_execute(&sm, .{
        .operation = .get,
        .id = id,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(get_resp.status, .not_found);
}

test "delete missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const resp = test_execute(&sm, .{
        .operation = .delete,
        .id = 0x00000000000000000000000000000063,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "list" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    _ = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(0xaaaa0000000000000000000000000001, "A", 100) } });
    _ = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(0xaaaa0000000000000000000000000002, "B", 200) } });

    const resp = test_execute(&sm, .{
        .operation = .list,
        .id = 0,
        .body = .{ .products = null },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.body.products.list.len, 2);
    try std.testing.expectEqualSlices(u8, resp.body.products.list.items[0].name_slice(), "A");
    try std.testing.expectEqualSlices(u8, resp.body.products.list.items[1].name_slice(), "B");
}

test "client-provided IDs" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id1: u128 = 0xaabbccddaabbccddaabbccddaabbccd1;
    const id2: u128 = 0xaabbccddaabbccddaabbccddaabbccd2;
    const r1 = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(id1, "A", 1) } });
    const r2 = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(id2, "B", 2) } });
    try std.testing.expectEqual(r1.body.products.single.id, id1);
    try std.testing.expectEqual(r2.body.products.single.id, id2);
}

test "duplicate ID rejected" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x33333333333333333333333333333333;
    const r1 = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(test_id, "A", 1) } });
    try std.testing.expectEqual(r1.status, .ok);
    const r2 = test_execute(&sm, .{ .operation = .create, .id = 0, .body = .{ .products = make_test_product(test_id, "B", 2) } });
    try std.testing.expectEqual(r2.status, .storage_error);
}
