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
        prefetch_product_list: message.ProductList,
        prefetch_collection: ?message.ProductCollection,
        prefetch_collection_list: message.CollectionList,
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
            // Pair assertion: event tag must match what EventType prescribes
            // for this operation. Construction site is schema.zig; this is the
            // consumption site — catches mismatched event/operation pairing.
            assert(msg.event == msg.operation.event_tag());
            self.reset_prefetch_cache();

            const result: StorageResult = switch (msg.operation) {
                .get_product, .get_product_inventory => self.prefetch_read(msg.id),
                .list_products => self.prefetch_list_products(),
                .create_product => blk: {
                    const p = msg.event.product;
                    assert(p.id > 0);
                    assert(p.name_len > 0);
                    break :blk self.prefetch_read(p.id);
                },
                .update_product => blk: {
                    assert(msg.id > 0);
                    assert(msg.event.product.name_len > 0);
                    break :blk self.prefetch_read(msg.id);
                },
                .delete_product => self.prefetch_read(msg.id),
                .get_collection => self.prefetch_collection_with_products(msg.id),
                .list_collections => self.prefetch_list_all_collections(),
                .create_collection => blk: {
                    const col = msg.event.collection;
                    assert(col.id > 0);
                    assert(col.name_len > 0);
                    break :blk self.prefetch_collection_read(col.id);
                },
                .delete_collection => self.prefetch_collection_read(msg.id),
                .add_collection_member => blk: {
                    const product_id = msg.event.member_id;
                    // Read both collection and product to verify existence.
                    const r1 = self.prefetch_collection_read(msg.id);
                    if (r1 != .ok and r1 != .not_found) break :blk r1;
                    const r2 = self.prefetch_read(product_id);
                    if (r2 != .ok and r2 != .not_found) break :blk r2;
                    // Both must exist.
                    if (r1 == .not_found or r2 == .not_found) break :blk .not_found;
                    break :blk .ok;
                },
                .remove_collection_member => self.prefetch_collection_read(msg.id),
                .transfer_inventory => blk: {
                    const transfer = msg.event.transfer;
                    assert(msg.id > 0);
                    assert(transfer.target_id > 0);
                    assert(msg.id != transfer.target_id);
                    // Read both products into list slots — this is the multi-entity
                    // prefetch that stresses the cache. Slot 0 = source, slot 1 = target.
                    const r1 = self.storage.get(msg.id, &self.prefetch_product_list.items[0]);
                    if (r1 != .ok) break :blk r1;
                    const r2 = self.storage.get(transfer.target_id, &self.prefetch_product_list.items[1]);
                    if (r2 != .ok) break :blk r2;
                    self.prefetch_product_list.len = 2;
                    break :blk .ok;
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
        /// Uses inline dispatch to route operations to per-pattern handlers,
        /// following TigerBeetle's commit() pattern. The inline keyword makes
        /// each operation comptime-known inside the handler, enabling:
        /// - EventType(op) to extract typed events from the Event union
        /// - Comptime switches inside handlers that prune dead branches
        /// Must only be called after prefetch() returned true.
        pub fn execute(self: *StateMachine, msg: message.Message) message.MessageResponse {
            const result = self.prefetch_result.?;
            defer self.reset_prefetch();

            // Storage read error — return 503 regardless of operation.
            if (result == .err) return message.MessageResponse.storage_error;

            // Wrap the entire execute phase in a transaction so multi-write
            // operations (transfer_inventory, delete_collection) are atomic.
            // Single-write operations: no-op — SQLite skips the implicit
            // transaction when an explicit one is active.
            self.storage.begin();
            defer self.storage.commit();

            return switch (msg.operation) {
                inline .get_product,
                .get_product_inventory,
                .get_collection,
                => |comptime_op| self.execute_get(comptime_op, result),

                inline .list_products,
                .list_collections,
                => |comptime_op| self.execute_list(comptime_op, result),

                inline .create_product,
                .create_collection,
                => |comptime_op| self.execute_create(
                    comptime_op,
                    msg.event.unwrap(comptime_op.EventType()),
                    result,
                ),

                inline .delete_product,
                .delete_collection,
                => |comptime_op| self.execute_delete(comptime_op, msg.id, result),

                .update_product => self.execute_update_product(
                    msg.id,
                    msg.event.unwrap(message.Product),
                    result,
                ),

                .add_collection_member => self.execute_add_member(
                    msg.id,
                    msg.event.unwrap(u128),
                    result,
                ),

                .remove_collection_member => self.execute_remove_member(
                    msg.id,
                    msg.event.unwrap(u128),
                    result,
                ),

                .transfer_inventory => self.execute_transfer_inventory(
                    msg.event.unwrap(message.InventoryTransfer),
                    result,
                ),
            };
        }

        // --- Per-pattern execute handlers ---
        //
        // Operations are grouped by shared control flow, NOT by verb name.
        // If a future operation has different error handling (e.g., returns
        // a default instead of 404), it gets its own handler — don't force
        // it into an existing group just because it's a "get" or "delete."

        /// Get-by-ID pattern: check not_found, return cached entity.
        /// Shared by get_product, get_product_inventory, get_collection.
        fn execute_get(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);
            return .{
                .status = .ok,
                .result = switch (op) {
                    .get_product => .{ .product = self.prefetch_product.? },
                    .get_product_inventory => .{ .inventory = self.prefetch_product.?.inventory },
                    .get_collection => .{ .collection = .{
                        .collection = self.prefetch_collection.?,
                        .products = self.prefetch_product_list,
                    } },
                    else => unreachable,
                },
            };
        }

        /// List pattern: return cached list.
        /// Shared by list_products, list_collections.
        fn execute_list(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            assert(result == .ok);
            return .{
                .status = .ok,
                .result = switch (op) {
                    .list_products => .{ .product_list = self.prefetch_product_list },
                    .list_collections => .{ .collection_list = self.prefetch_collection_list },
                    else => unreachable,
                },
            };
        }

        /// Create pattern: check doesn't exist, write, return entity.
        /// Shared by create_product, create_collection. The event parameter
        /// type is resolved at comptime via op.EventType() — Product for
        /// create_product, ProductCollection for create_collection.
        fn execute_create(
            self: *StateMachine,
            comptime op: message.Operation,
            event: op.EventType(),
            result: StorageResult,
        ) message.MessageResponse {
            if (result == .ok) return message.MessageResponse.storage_error;
            assert(result == .not_found);

            const write_result = switch (op) {
                .create_product => self.storage.put(&event),
                .create_collection => self.storage.put_collection(&event),
                else => unreachable,
            };

            const ok_result: message.Result = switch (op) {
                .create_product => .{ .product = event },
                .create_collection => .{ .collection = .{
                    .collection = event,
                    .products = .{ .items = undefined, .len = 0 },
                } },
                else => unreachable,
            };

            return self.commit_write(write_result, ok_result);
        }

        /// Delete pattern: check exists, delete, return empty.
        /// Shared by delete_product, delete_collection.
        /// Prefetch proved the entity exists — delete is infallible.
        fn execute_delete(self: *StateMachine, comptime op: message.Operation, id: u128, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            assert(switch (op) {
                .delete_product => self.storage.delete(id),
                .delete_collection => self.storage.delete_collection(id),
                else => unreachable,
            } == .ok);

            return .{ .status = .ok, .result = .{ .empty = {} } };
        }

        /// Prefetch proved the product exists — update is infallible.
        fn execute_update_product(self: *StateMachine, id: u128, event: message.Product, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);
            var updated = event;
            updated.id = id;
            assert(self.storage.update(id, &updated) == .ok);
            return .{ .status = .ok, .result = .{ .product = updated } };
        }

        fn execute_add_member(self: *StateMachine, id: u128, product_id: u128, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);
            return self.commit_write(self.storage.add_to_collection(id, product_id), .{ .empty = {} });
        }

        fn execute_remove_member(self: *StateMachine, id: u128, product_id: u128, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);
            const write_result = self.storage.remove_from_collection(id, product_id);
            // remove_from_collection either finds the membership (.ok) or doesn't (.not_found).
            // No capacity concern (it's a delete), no fault injection on writes.
            assert(write_result == .ok or write_result == .not_found);
            if (write_result == .not_found) return message.MessageResponse.not_found;
            return message.MessageResponse.empty_ok;
        }

        /// Transfer inventory: two products in cache, cross-entity validation, two writes.
        /// Uses list slots for multi-entity prefetch — slot 0 is source, slot 1 is target.
        /// Writes are infallible after prefetch (TigerBeetle style): prefetch proved both
        /// products exist, so update() is a memcpy into an occupied slot.
        fn execute_transfer_inventory(self: *StateMachine, transfer: message.InventoryTransfer, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);
            assert(self.prefetch_product_list.len == 2);

            var source = self.prefetch_product_list.items[0];
            var target = self.prefetch_product_list.items[1];

            // Business logic: source must have enough inventory.
            if (source.inventory < transfer.quantity) {
                return .{ .status = .insufficient_inventory, .result = .{ .empty = {} } };
            }

            source.inventory -= transfer.quantity;
            target.inventory += transfer.quantity;

            // After this point, the transfer must succeed.
            assert(self.storage.update(source.id, &source) == .ok);
            assert(self.storage.update(target.id, &target) == .ok);

            self.prefetch_product_list.items[0] = source;
            self.prefetch_product_list.items[1] = target;
            return .{
                .status = .ok,
                .result = .{ .product_list = self.prefetch_product_list },
            };
        }

        /// Commit a storage write and translate the result to a response.
        /// On success, returns the provided result payload. On failure, returns 503.
        fn commit_write(_: *StateMachine, write_result: StorageResult, ok_result: message.Result) message.MessageResponse {
            return switch (write_result) {
                .ok => .{ .status = .ok, .result = ok_result },
                .busy, .err => message.MessageResponse.storage_error,
                .not_found => unreachable,
                .corruption => @panic("storage corruption in execute"),
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

    pub fn begin(_: *MemoryStorage) void {}
    pub fn commit(_: *MemoryStorage) void {}

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
        // No fault injection — writes are infallible (TigerBeetle style).
        // Prefetch validates; execute commits. If the machine is dying
        // (disk full, hardware failure), crash — don't try to handle it.
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
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.product = product.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn delete(self: *MemoryStorage, id: u128) StorageResult {
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.occupied = false;
                self.product_count -= 1;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list(self: *MemoryStorage, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            assert(out_len.* < message.list_max);
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

    pub fn list_collections(self: *MemoryStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.collections_store) |*entry| {
            if (!entry.occupied) continue;
            assert(out_len.* < message.list_max);
            out[out_len.*] = entry.collection;
            out_len.* += 1;
        }
        return .ok;
    }

    // --- Membership operations ---

    pub fn add_to_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
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
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == collection_id and m.product_id == product_id) {
                m.occupied = false;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_products_in_collection(self: *MemoryStorage, collection_id: u128, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.memberships) |*m| {
            if (!m.occupied or m.collection_id != collection_id) continue;
            // Look up the product.
            for (self.products) |*entry| {
                if (entry.occupied and entry.product.id == m.product_id) {
                    assert(out_len.* < message.list_max);
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
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Widget", 999) },
    });
    try std.testing.expectEqual(create_resp.status, .ok);
    const created = create_resp.result.product;
    try std.testing.expectEqual(created.id, test_id);
    try std.testing.expectEqualSlices(u8, created.name_slice(), "Widget");
    try std.testing.expectEqual(created.price_cents, 999);

    const get_resp = test_execute(&sm, .{
        .operation = .get_product,
        .id = test_id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(get_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, get_resp.result.product.name_slice(), "Widget");
}

test "get missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const resp = test_execute(&sm, .{
        .operation = .get_product,
        .id = 0x00000000000000000000000000000063,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "update" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x11111111111111111111111111111111;
    const create_resp = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Old Name", 100) },
    });
    const id = create_resp.result.product.id;

    const update_resp = test_execute(&sm, .{
        .operation = .update_product,
        .id = id,
        .event = .{ .product = make_test_product(0, "New Name", 200) },
    });
    try std.testing.expectEqual(update_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, update_resp.result.product.name_slice(), "New Name");
    try std.testing.expectEqual(update_resp.result.product.price_cents, 200);
    try std.testing.expectEqual(update_resp.result.product.id, id);
}

test "delete" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x22222222222222222222222222222222;
    const create_resp = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Doomed", 100) },
    });
    const id = create_resp.result.product.id;

    const del_resp = test_execute(&sm, .{
        .operation = .delete_product,
        .id = id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = test_execute(&sm, .{
        .operation = .get_product,
        .id = id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(get_resp.status, .not_found);
}

test "delete missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const resp = test_execute(&sm, .{
        .operation = .delete_product,
        .id = 0x00000000000000000000000000000063,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "list" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0xaaaa0000000000000000000000000001, "A", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0xaaaa0000000000000000000000000002, "B", 200) } });

    const resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[0].name_slice(), "A");
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[1].name_slice(), "B");
}

test "client-provided IDs" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id1: u128 = 0xaabbccddaabbccddaabbccddaabbccd1;
    const id2: u128 = 0xaabbccddaabbccddaabbccddaabbccd2;
    const r1 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id1, "A", 1) } });
    const r2 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id2, "B", 2) } });
    try std.testing.expectEqual(r1.result.product.id, id1);
    try std.testing.expectEqual(r2.result.product.id, id2);
}

test "transfer inventory — success" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Target", 0);
    prod_b.inventory = 20;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_b } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = id_a,
        .event = .{ .transfer = .{ .target_id = id_b, .quantity = 30 } },
    });
    try std.testing.expectEqual(resp.status, .ok);
    // Response contains both updated products.
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqual(resp.result.product_list.items[0].inventory, 70);
    try std.testing.expectEqual(resp.result.product_list.items[1].inventory, 50);

    // Verify storage was actually updated.
    const get_a = test_execute(&sm, .{ .operation = .get_product, .id = id_a, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_a.result.product.inventory, 70);
    const get_b = test_execute(&sm, .{ .operation = .get_product, .id = id_b, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_b.result.product.inventory, 50);
}

test "transfer inventory — insufficient stock" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Low", 0);
    prod_a.inventory = 5;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_b, "Other", 0) } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = id_a,
        .event = .{ .transfer = .{ .target_id = id_b, .quantity = 10 } },
    });
    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, .{ .operation = .get_product, .id = id_a, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_a.result.product.inventory, 5);
}

test "transfer inventory — source not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id_b: u128 = 0xcccc0000000000000000000000000002;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_b, "Target", 0) } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = 0xcccc0000000000000000000000000001,
        .event = .{ .transfer = .{ .target_id = id_b, .quantity = 1 } },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "transfer inventory — target not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const id_a: u128 = 0xdddd0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 50;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = id_a,
        .event = .{ .transfer = .{ .target_id = 0xdddd0000000000000000000000000002, .quantity = 1 } },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "duplicate ID rejected" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    const test_id: u128 = 0x33333333333333333333333333333333;
    const r1 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(test_id, "A", 1) } });
    try std.testing.expectEqual(r1.status, .ok);
    const r2 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(test_id, "B", 2) } });
    try std.testing.expectEqual(r2.status, .storage_error);
}

test "capacity exhaustion — returns storage_error" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage);

    // Fill storage to capacity.
    for (0..MemoryStorage.product_capacity) |i| {
        const id: u128 = @intCast(i + 1);
        const r = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id, "P", 1) } });
        try std.testing.expectEqual(r.status, .ok);
    }

    // One more should fail with storage_error.
    const overflow_id: u128 = MemoryStorage.product_capacity + 1;
    const r = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(overflow_id, "X", 1) } });
    try std.testing.expectEqual(r.status, .storage_error);
}
