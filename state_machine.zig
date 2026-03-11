const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const Tracer = @import("tracer.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.state_machine));
const PRNG = @import("prng.zig");

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
        tracer: Tracer,

        // Prefetch cache — populated by prefetch(), consumed by commit().
        //
        // Two product caches for different access patterns:
        // - prefetch_product: single-entity lookup (get, create, update, delete)
        // - prefetch_product_list: list results (list_products, collection members)
        // - prefetch_products: multi-key lookup by ID (transfer_inventory, create_order)
        prefetch_product: ?message.Product,
        prefetch_product_list: message.ProductList,
        prefetch_products: [message.order_items_max]?message.Product,
        prefetch_collection: ?message.ProductCollection,
        prefetch_collection_list: message.CollectionList,
        prefetch_order: ?message.OrderResult,
        prefetch_order_list: message.OrderSummaryList,
        prefetch_result: ?StorageResult,

        pub fn init(storage: *Storage, log_trace: bool) StateMachine {
            return .{
                .storage = storage,
                .tracer = Tracer.init(log_trace),
                .prefetch_product = null,
                .prefetch_product_list = .{ .items = undefined, .len = 0 },
                .prefetch_products = [_]?message.Product{null} ** message.order_items_max,
                .prefetch_collection = null,
                .prefetch_collection_list = .{ .items = undefined, .len = 0 },
                .prefetch_order = null,
                .prefetch_order_list = .{ .items = undefined, .len = 0 },
                .prefetch_result = null,
            };
        }

        /// Returns whether the message is valid input for the state machine.
        /// Used by the fuzzer to filter random messages before calling prefetch/commit.
        pub fn input_valid(msg: message.Message) bool {
            if (msg.event != msg.operation.event_tag()) return false;

            switch (msg.operation) {
                .create_product => {
                    const p = msg.event.product;
                    if (p.id == 0) return false;
                    if (p.name_len == 0 or p.name_len > message.product_name_max) return false;
                    if (p.description_len > message.product_description_max) return false;
                },
                .update_product => {
                    if (msg.id == 0) return false;
                    const p = msg.event.product;
                    if (p.name_len == 0 or p.name_len > message.product_name_max) return false;
                    if (p.description_len > message.product_description_max) return false;
                },
                .create_collection => {
                    const col = msg.event.collection;
                    if (col.id == 0) return false;
                    if (col.name_len == 0 or col.name_len > message.collection_name_max) return false;
                },
                .transfer_inventory => {
                    const transfer = msg.event.transfer;
                    if (msg.id == 0) return false;
                    if (transfer.target_id == 0) return false;
                    if (msg.id == transfer.target_id) return false;
                },
                .create_order => {
                    const order = msg.event.order;
                    if (order.id == 0) return false;
                    if (order.items_len == 0) return false;
                    if (order.items_len > message.order_items_max) return false;
                    for (order.items_slice()) |item| {
                        if (item.product_id == 0) return false;
                        if (item.quantity == 0) return false;
                    }
                },
                .get_product,
                .get_product_inventory,
                .delete_product,
                .get_collection,
                .delete_collection,
                .get_order,
                => {},
                .add_collection_member,
                .remove_collection_member,
                => {},
                .list_products,
                .list_collections,
                .list_orders,
                => {
                    const lp = msg.event.list;
                    if (lp.name_prefix_len > message.product_name_max) return false;
                    // NUL bytes in the prefix would be treated as string
                    // terminators by SQLite's LIKE, silently matching everything.
                    for (lp.name_prefix[0..lp.name_prefix_len]) |b| {
                        if (b == 0) return false;
                    }
                },
            }
            return true;
        }

        /// Phase 1: read data from storage into cache slots. Never writes.
        /// Returns true if prefetch completed (success or error).
        /// Returns false if storage is busy — connection stays .ready, retried next tick.
        pub fn prefetch(self: *StateMachine, msg: message.Message) bool {
            assert(self.prefetch_result == null);
            // Pair assertion: event tag must match what EventType prescribes
            // for this operation. Construction site is codec.zig; this is the
            // consumption site — catches mismatched event/operation pairing.
            assert(msg.event == msg.operation.event_tag());
            self.reset_prefetch_cache();

            const result: StorageResult = switch (msg.operation) {
                .get_product, .get_product_inventory => self.prefetch_read(msg.id),
                .list_products => self.prefetch_list_products(msg.event.list),
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
                .list_collections => self.prefetch_list_all_collections(msg.event.list),
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
                .get_order => self.prefetch_order_read(msg.id),
                .list_orders => self.prefetch_list_all_orders(msg.event.list),
                .transfer_inventory => blk: {
                    const transfer = msg.event.transfer;
                    assert(msg.id > 0);
                    assert(transfer.target_id > 0);
                    assert(msg.id != transfer.target_id);
                    break :blk self.prefetch_multi(&.{ msg.id, transfer.target_id });
                },
                .create_order => blk: {
                    const order = msg.event.order;
                    assert(order.items_len > 0);
                    assert(order.items_len <= message.order_items_max);
                    assert(order.id > 0);
                    var ids: [message.order_items_max]u128 = undefined;
                    for (order.items_slice(), 0..) |item, i| {
                        assert(item.product_id > 0);
                        assert(item.quantity > 0);
                        ids[i] = item.product_id;
                    }
                    break :blk self.prefetch_multi(ids[0..order.items_len]);
                },
            };

            switch (result) {
                .busy => return false,
                .corruption => @panic("storage corruption in prefetch"),
                .ok, .not_found, .err => self.prefetch_result = result,
            }

            return true;
        }

        /// Phase 2: commit — single entry point for the execute phase.
        /// Handles cross-cutting concerns (transaction wrapping, status
        /// counting) so individual handlers don't have to.
        /// Follows TigerBeetle's commit() pattern. Must only be called
        /// after prefetch() returned true.
        pub fn commit(self: *StateMachine, msg: message.Message) message.MessageResponse {
            const result = self.prefetch_result.?;
            defer self.reset_prefetch();

            const resp = if (result == .err)
                // Storage read error — return 503 regardless of operation.
                message.MessageResponse.storage_error
            else resp: {
                // Wrap the execute phase in a transaction so multi-write
                // operations (transfer_inventory, delete_collection) are atomic.
                self.storage.begin();
                defer self.storage.commit();
                break :resp self.execute(msg, result);
            };

            // Cross-cutting: count every response status. No handler opts
            // in or out — the commit loop guarantees it.
            self.tracer.count(switch (resp.status) {
                .ok => .requests_ok,
                .not_found => .requests_not_found,
                .storage_error => .requests_storage_error,
                .insufficient_inventory => .requests_insufficient_inventory,
                .version_conflict => .requests_version_conflict,
            }, 1);

            return resp;
        }

        /// Dispatch to per-pattern handlers. Private — only called by commit().
        fn execute(self: *StateMachine, msg: message.Message, result: StorageResult) message.MessageResponse {
            return switch (msg.operation) {
                inline .get_product,
                .get_product_inventory,
                .get_collection,
                .get_order,
                => |comptime_op| self.execute_get(comptime_op, result),

                inline .list_products,
                .list_collections,
                .list_orders,
                => |comptime_op| self.execute_list(comptime_op, result),

                inline .create_product,
                .create_collection,
                => |comptime_op| self.execute_create(
                    comptime_op,
                    msg.event.unwrap(comptime_op.EventType()),
                    result,
                ),

                .delete_product => self.execute_soft_delete_product(msg.id, result),

                inline .delete_collection,
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
                    msg.id,
                    msg.event.unwrap(message.InventoryTransfer),
                    result,
                ),

                .create_order => self.execute_create_order(
                    msg.event.unwrap(message.OrderRequest),
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
        /// Shared by get_product, get_product_inventory, get_collection, get_order.
        /// Products use soft delete — inactive products return 404.
        fn execute_get(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            // Soft delete: inactive products are treated as not found.
            if (op == .get_product or op == .get_product_inventory) {
                if (!self.prefetch_product.?.flags.active) return message.MessageResponse.not_found;
            }

            return .{
                .status = .ok,
                .result = switch (op) {
                    .get_product => .{ .product = self.prefetch_product.? },
                    .get_product_inventory => .{ .inventory = self.prefetch_product.?.inventory },
                    .get_collection => .{ .collection = .{
                        .collection = self.prefetch_collection.?,
                        .products = self.prefetch_product_list,
                    } },
                    .get_order => .{ .order = self.prefetch_order.? },
                    else => unreachable,
                },
            };
        }

        /// List pattern: return cached list.
        /// Shared by list_products, list_collections, list_orders.
        fn execute_list(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            assert(result == .ok);
            return .{
                .status = .ok,
                .result = switch (op) {
                    .list_products => .{ .product_list = self.prefetch_product_list },
                    .list_collections => .{ .collection_list = self.prefetch_collection_list },
                    .list_orders => .{ .order_list = self.prefetch_order_list },
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

            // For products, set initial version.
            var entity = event;
            if (op == .create_product) {
                entity.version = 1;
            }

            const write_result = switch (op) {
                .create_product => self.storage.put(&entity),
                .create_collection => self.storage.put_collection(&entity),
                else => unreachable,
            };

            const ok_result: message.Result = switch (op) {
                .create_product => .{ .product = entity },
                .create_collection => .{ .collection = .{
                    .collection = entity,
                    .products = .{ .items = undefined, .len = 0 },
                } },
                else => unreachable,
            };

            return self.commit_write(write_result, ok_result);
        }

        /// Soft delete: set active = false, increment version.
        /// Already-inactive products return 404 (idempotent).
        fn execute_soft_delete_product(self: *StateMachine, id: u128, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            var product = self.prefetch_product.?;
            assert(product.id == id);

            if (!product.flags.active) return message.MessageResponse.not_found;

            product.flags.active = false;
            product.version += 1;
            assert(self.storage.update(id, &product) == .ok);

            return message.MessageResponse.empty_ok;
        }

        /// Hard delete: remove the entity from storage.
        /// Used by delete_collection (collections don't have soft delete).
        fn execute_delete(self: *StateMachine, comptime op: message.Operation, id: u128, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            assert(switch (op) {
                .delete_collection => self.storage.delete_collection(id),
                else => unreachable,
            } == .ok);

            return .{ .status = .ok, .result = .{ .empty = {} } };
        }

        /// Update with optimistic concurrency: client provides expected version,
        /// server rejects if it doesn't match. Version increments on success.
        fn execute_update_product(self: *StateMachine, id: u128, event: message.Product, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            const current = self.prefetch_product.?;
            assert(current.id == id);

            // Version 0 means "no version check" (backwards compatibility).
            if (event.version != 0 and event.version != current.version) {
                return .{ .status = .version_conflict, .result = .{ .empty = {} } };
            }

            var updated = event;
            updated.id = id;
            updated.version = current.version + 1;
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
            assert(write_result == .ok or write_result == .not_found);
            if (write_result == .not_found) return message.MessageResponse.not_found;
            return message.MessageResponse.empty_ok;
        }

        /// Transfer inventory: two products in cache, cross-entity validation, two writes.
        /// Writes are infallible after prefetch (TigerBeetle style): prefetch proved both
        /// products exist, so update() is a memcpy into an occupied slot.
        fn execute_transfer_inventory(self: *StateMachine, source_id: u128, transfer: message.InventoryTransfer, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            var source = self.prefetch_find(source_id).?;
            var target = self.prefetch_find(transfer.target_id).?;

            // Business logic: source must have enough inventory.
            if (source.inventory < transfer.quantity) {
                return .{ .status = .insufficient_inventory, .result = .{ .empty = {} } };
            }

            source.inventory -= transfer.quantity;
            target.inventory += transfer.quantity;

            // After this point, the transfer must succeed.
            assert(self.storage.update(source.id, &source) == .ok);
            assert(self.storage.update(target.id, &target) == .ok);

            // Return both updated products.
            var result_list = message.ProductList{ .items = undefined, .len = 2 };
            result_list.items[0] = source;
            result_list.items[1] = target;
            return .{
                .status = .ok,
                .result = .{ .product_list = result_list },
            };
        }

        /// Create order: N products in cache, validate all have sufficient inventory,
        /// decrement all inventories atomically, return order summary.
        /// Uses list slots for multi-entity prefetch — one slot per line item.
        fn execute_create_order(self: *StateMachine, order: message.OrderRequest, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            // Phase 1: validate all items have sufficient inventory.
            for (order.items_slice()) |item| {
                const product = self.prefetch_find(item.product_id).?;
                if (product.inventory < item.quantity) {
                    return .{ .status = .insufficient_inventory, .result = .{ .empty = {} } };
                }
            }

            // Phase 2: all validated — decrement inventories and build result.
            var order_result = std.mem.zeroes(message.OrderResult);
            order_result.id = order.id;
            order_result.items_len = order.items_len;

            for (order.items_slice(), 0..) |item, i| {
                var product = self.prefetch_find(item.product_id).?;
                product.inventory -= item.quantity;
                assert(self.storage.update(product.id, &product) == .ok);

                const line_total = @as(u64, product.price_cents) * @as(u64, item.quantity);
                order_result.items[i] = std.mem.zeroes(message.OrderResultItem);
                order_result.items[i].product_id = product.id;
                order_result.items[i].name = product.name;
                order_result.items[i].name_len = product.name_len;
                order_result.items[i].quantity = item.quantity;
                order_result.items[i].price_cents = product.price_cents;
                order_result.items[i].line_total_cents = line_total;
                order_result.total_cents +|= line_total;
            }

            // Persist the order.
            assert(self.storage.put_order(&order_result) == .ok);

            return .{ .status = .ok, .result = .{ .order = order_result } };
        }

        /// Commit a storage write and translate the result to a response.
        /// On success, returns the provided result payload. On failure, returns 503.
        // No capacity warnings here. MemoryStorage has fixed-size arrays but
        // that's a test constraint, not a production one. SqliteStorage grows
        // until the disk is full. Capacity monitoring belongs in infrastructure
        // (disk space alerts), not in the state machine.

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
            self.prefetch_products = [_]?message.Product{null} ** message.order_items_max;
            self.prefetch_collection = null;
            self.prefetch_collection_list.len = 0;
            self.prefetch_order = null;
            self.prefetch_order_list.len = 0;
            self.prefetch_result = null;
        }

        fn reset_prefetch_cache(self: *StateMachine) void {
            self.prefetch_product = null;
            self.prefetch_product_list.len = 0;
            self.prefetch_products = [_]?message.Product{null} ** message.order_items_max;
            self.prefetch_collection = null;
            self.prefetch_collection_list.len = 0;
            self.prefetch_order = null;
            self.prefetch_order_list.len = 0;
        }

        // --- Product prefetch helpers (read-only) ---

        fn prefetch_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var product: message.Product = undefined;
            const result = self.storage.get(id, &product);
            if (result == .ok) self.prefetch_product = product;
            return result;
        }

        fn prefetch_list_products(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list(&self.prefetch_product_list.items, &self.prefetch_product_list.len, params);
        }

        /// Multi-key prefetch: read N products by ID into the keyed cache.
        /// Execute retrieves them via prefetch_find(id), not by position.
        fn prefetch_multi(self: *StateMachine, ids: []const u128) StorageResult {
            assert(ids.len > 0);
            assert(ids.len <= message.order_items_max);
            for (ids, 0..) |id, i| {
                assert(id > 0);
                var product: message.Product = undefined;
                const r = self.storage.get(id, &product);
                if (r != .ok) return r;
                self.prefetch_products[i] = product;
            }
            return .ok;
        }

        /// Look up a prefetched product by ID. Returns null if not found.
        /// TB equivalent: grooves.accounts.get(id) — keyed lookup, not positional.
        fn prefetch_find(self: *StateMachine, id: u128) ?message.Product {
            for (&self.prefetch_products) |*slot| {
                const product = slot.* orelse continue;
                if (product.id == id) return product;
            }
            return null;
        }

        // --- Collection prefetch helpers (read-only) ---

        fn prefetch_collection_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var col: message.ProductCollection = undefined;
            const result = self.storage.get_collection(id, &col);
            if (result == .ok) self.prefetch_collection = col;
            return result;
        }

        fn prefetch_list_all_collections(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list_collections(&self.prefetch_collection_list.items, &self.prefetch_collection_list.len, params.cursor);
        }

        // --- Order prefetch helpers (read-only) ---

        fn prefetch_order_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var order: message.OrderResult = undefined;
            const result = self.storage.get_order(id, &order);
            if (result == .ok) self.prefetch_order = order;
            return result;
        }

        fn prefetch_list_all_orders(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list_orders(&self.prefetch_order_list.items, &self.prefetch_order_list.len, params.cursor);
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
    pub const order_capacity = 256;

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

    const OrderEntry = struct {
        order: message.OrderResult,
        occupied: bool,
    };

    const empty_product = ProductEntry{ .product = undefined, .occupied = false };
    const empty_collection = CollectionEntry{ .collection = undefined, .occupied = false };
    const empty_membership = MembershipEntry{ .collection_id = 0, .product_id = 0, .occupied = false };
    const empty_order = OrderEntry{ .order = undefined, .occupied = false };

    products: *[product_capacity]ProductEntry,
    product_count: u32,
    collections_store: *[collection_capacity]CollectionEntry,
    collection_count: u32,
    memberships: *[membership_capacity]MembershipEntry,
    orders: *[order_capacity]OrderEntry,
    order_count: u32,

    // Fault injection — PRNG-driven, same pattern as SimIO.
    prng: PRNG,
    busy_fault_probability: PRNG.Ratio,
    err_fault_probability: PRNG.Ratio,

    pub fn init(allocator: std.mem.Allocator) !MemoryStorage {
        const products = try allocator.create([product_capacity]ProductEntry);
        @memset(products, empty_product);
        const collections_store = try allocator.create([collection_capacity]CollectionEntry);
        @memset(collections_store, empty_collection);
        const memberships = try allocator.create([membership_capacity]MembershipEntry);
        @memset(memberships, empty_membership);
        const orders = try allocator.create([order_capacity]OrderEntry);
        @memset(orders, empty_order);
        return .{
            .products = products,
            .product_count = 0,
            .collections_store = collections_store,
            .collection_count = 0,
            .memberships = memberships,
            .orders = orders,
            .order_count = 0,
            .prng = PRNG.from_seed(0),
            .busy_fault_probability = PRNG.Ratio.zero(),
            .err_fault_probability = PRNG.Ratio.zero(),
        };
    }

    pub fn deinit(self: *MemoryStorage, allocator: std.mem.Allocator) void {
        allocator.destroy(self.products);
        allocator.destroy(self.collections_store);
        allocator.destroy(self.memberships);
        allocator.destroy(self.orders);
    }

    pub fn reset(self: *MemoryStorage) void {
        @memset(self.products, empty_product);
        self.product_count = 0;
        @memset(self.collections_store, empty_collection);
        self.collection_count = 0;
        @memset(self.memberships, empty_membership);
        @memset(self.orders, empty_order);
        self.order_count = 0;
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

    pub fn list(self: *MemoryStorage, out: *[message.list_max]message.Product, out_len: *u32, params: message.ListParams) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            if (entry.product.id <= params.cursor) continue;
            if (!match_product_filters(&entry.product, params)) continue;
            insert_sorted(message.Product, out, out_len, entry.product);
        }
        return .ok;
    }

    fn match_product_filters(product: *const message.Product, params: message.ListParams) bool {
        // Active filter.
        switch (params.active_filter) {
            .any => {},
            .active_only => if (!product.flags.active) return false,
            .inactive_only => if (product.flags.active) return false,
        }
        // Price range.
        if (params.price_min > 0 and product.price_cents < params.price_min) return false;
        if (params.price_max > 0 and product.price_cents > params.price_max) return false;
        // Name prefix.
        if (params.name_prefix_len > 0) {
            const prefix = params.name_prefix[0..params.name_prefix_len];
            if (product.name_len < params.name_prefix_len) return false;
            if (!std.mem.startsWith(u8, product.name[0..product.name_len], prefix)) return false;
        }
        return true;
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

    pub fn list_collections(self: *MemoryStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32, cursor: u128) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.collections_store) |*entry| {
            if (!entry.occupied) continue;
            if (entry.collection.id <= cursor) continue;
            insert_sorted(message.ProductCollection, out, out_len, entry.collection);
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
                    insert_sorted(message.Product, out, out_len, entry.product);
                    break;
                }
            }
        }
        return .ok;
    }

    // --- Order operations ---

    pub fn put_order(self: *MemoryStorage, order: *const message.OrderResult) StorageResult {
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == order.id) return .err;
        }
        for (self.orders) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .order = order.*, .occupied = true };
                self.order_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn get_order(self: *MemoryStorage, id: u128, out: *message.OrderResult) StorageResult {
        if (self.fault()) |f| return f;
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == id) {
                out.* = entry.order;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_orders(self: *MemoryStorage, out: *[message.list_max]message.OrderSummary, out_len: *u32, cursor: u128) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.orders) |*entry| {
            if (!entry.occupied) continue;
            if (entry.order.id <= cursor) continue;
            var summary = std.mem.zeroes(message.OrderSummary);
            summary.id = entry.order.id;
            summary.total_cents = entry.order.total_cents;
            summary.items_len = entry.order.items_len;
            insert_sorted(message.OrderSummary, out, out_len, summary);
        }
        return .ok;
    }

    /// Insert an entity into a sorted, bounded output buffer.
    /// Matches SqliteStorage's ORDER BY id LIMIT list_max — keeps
    /// the list_max entities with the smallest IDs, in ascending order.
    fn insert_sorted(comptime T: type, out: *[message.list_max]T, out_len: *u32, item: T) void {
        // Find insertion point (first element with id > item.id).
        var pos: u32 = 0;
        while (pos < out_len.*) : (pos += 1) {
            if (out[pos].id > item.id) break;
        }

        if (out_len.* < message.list_max) {
            // Buffer not full — shift right and insert.
            var i: u32 = out_len.*;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
            out_len.* += 1;
        } else if (pos < message.list_max) {
            // Buffer full but item belongs before the last element —
            // shift right from pos, dropping the last element.
            var i: u32 = message.list_max - 1;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
        }
        // else: item.id >= all current IDs and buffer is full — skip.
    }

    /// Roll PRNG against fault probabilities. Returns a fault result or null.
    fn fault(self: *MemoryStorage) ?StorageResult {
        if (self.prng.chance(self.busy_fault_probability)) {
            log.mark.debug("storage: busy fault injected", .{});
            return .busy;
        }
        if (self.prng.chance(self.err_fault_probability)) {
            log.mark.debug("storage: err fault injected", .{});
            return .err;
        }
        return null;
    }
};

// =====================================================================
// Tests
// =====================================================================

fn make_test_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = id;
    p.name_len = @intCast(name.len);
    p.price_cents = price;
    p.flags = .{ .active = true };
    @memcpy(p.name[0..name.len], name);
    return p;
}

const TestStateMachine = StateMachineType(MemoryStorage);

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

fn test_execute(sm: *TestStateMachine, msg: message.Message) message.MessageResponse {
    assert(sm.prefetch(msg));
    return sm.commit(msg);
}

test "create and get" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

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
    var sm = TestStateMachine.init(&storage, false);

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
    var sm = TestStateMachine.init(&storage, false);

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
    var sm = TestStateMachine.init(&storage, false);

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
    var sm = TestStateMachine.init(&storage, false);

    const resp = test_execute(&sm, .{
        .operation = .delete_product,
        .id = 0x00000000000000000000000000000063,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "soft delete preserves product in storage" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0x33333333333333333333333333333333;
    _ = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "SoftDel", 100) },
    });

    // Delete (soft).
    const del_resp = test_execute(&sm, .{
        .operation = .delete_product,
        .id = test_id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(del_resp.status, .ok);

    // GET returns 404.
    const get_resp = test_execute(&sm, .{
        .operation = .get_product,
        .id = test_id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(get_resp.status, .not_found);

    // Default list (active_only) excludes it.
    const list_resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params(.active_only) },
    });
    try std.testing.expectEqual(list_resp.result.product_list.len, 0);

    // List with inactive_only shows it.
    const list_inactive = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params(.inactive_only) },
    });
    try std.testing.expectEqual(list_inactive.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, list_inactive.result.product_list.items[0].name_slice(), "SoftDel");
    try std.testing.expectEqual(list_inactive.result.product_list.items[0].flags.active, false);
}

test "list" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0xaaaa0000000000000000000000000001, "A", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0xaaaa0000000000000000000000000002, "B", 200) } });

    const resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = std.mem.zeroes(message.ListParams) },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[0].name_slice(), "A");
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[1].name_slice(), "B");
}

test "list returns results sorted by ID regardless of insertion order" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    // Insert in descending ID order — the opposite of sorted.
    const id_high: u128 = 0xff;
    const id_mid: u128 = 0x80;
    const id_low: u128 = 0x01;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_high, "High", 300) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_low, "Low", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_mid, "Mid", 200) } });

    const resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = std.mem.zeroes(message.ListParams) },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 3);
    // Must be sorted by ID, not insertion order.
    try std.testing.expectEqual(resp.result.product_list.items[0].id, id_low);
    try std.testing.expectEqual(resp.result.product_list.items[1].id, id_mid);
    try std.testing.expectEqual(resp.result.product_list.items[2].id, id_high);
}

test "list pagination returns the smallest IDs when more than list_max exist" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    // Create list_max + 10 products with IDs from 1..list_max+10,
    // inserted in reverse order to stress the sort.
    const total = message.list_max + 10;
    for (0..total) |i| {
        const id: u128 = total - i; // descending insertion: total, total-1, ..., 1
        _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id, "P", 100) } });
    }

    const resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = std.mem.zeroes(message.ListParams) },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, message.list_max);
    // First page must be IDs 1..list_max, in order.
    for (0..message.list_max) |i| {
        try std.testing.expectEqual(resp.result.product_list.items[i].id, i + 1);
    }

    // Second page (cursor = list_max) must be the remaining 10.
    const resp2 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_cursor(message.list_max) },
    });
    try std.testing.expectEqual(resp2.status, .ok);
    try std.testing.expectEqual(resp2.result.product_list.len, 10);
    for (0..10) |i| {
        try std.testing.expectEqual(resp2.result.product_list.items[i].id, message.list_max + i + 1);
    }
}

test "list with cursor skips earlier items" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id1: u128 = 0x00000000000000000000000000000001;
    const id2: u128 = 0x00000000000000000000000000000002;
    const id3: u128 = 0x00000000000000000000000000000003;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id1, "A", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id2, "B", 200) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id3, "C", 300) } });

    // List with cursor = id1 should skip A, return B and C.
    const resp = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_cursor(id1) },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqual(resp.result.product_list.items[0].id, id2);
    try std.testing.expectEqual(resp.result.product_list.items[1].id, id3);

    // List with cursor = id2 should return only C.
    const resp2 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_cursor(id2) },
    });
    try std.testing.expectEqual(resp2.result.product_list.len, 1);
    try std.testing.expectEqual(resp2.result.product_list.items[0].id, id3);

    // List with cursor = id3 should return empty.
    const resp3 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_cursor(id3) },
    });
    try std.testing.expectEqual(resp3.result.product_list.len, 0);
}

test "list filters by active status" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    var active = make_test_product(0x01, "Active", 100);
    active.flags.active = true;
    var inactive = make_test_product(0x02, "Inactive", 200);
    inactive.flags.active = false;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = active } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = inactive } });

    // Filter active only.
    const r1 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params(.active_only) },
    });
    try std.testing.expectEqual(r1.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r1.result.product_list.items[0].name_slice(), "Active");

    // Filter inactive only.
    const r2 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params(.inactive_only) },
    });
    try std.testing.expectEqual(r2.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r2.result.product_list.items[0].name_slice(), "Inactive");

    // No filter — both returned.
    const r3 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = std.mem.zeroes(message.ListParams) },
    });
    try std.testing.expectEqual(r3.result.product_list.len, 2);
}

test "list filters by price range" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x01, "Cheap", 500) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x02, "Mid", 1500) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x03, "Expensive", 5000) } });

    // price_min only.
    const r1 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_price(1000, 0) },
    });
    try std.testing.expectEqual(r1.result.product_list.len, 2);

    // price_max only.
    const r2 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_price(0, 1000) },
    });
    try std.testing.expectEqual(r2.result.product_list.len, 1);

    // Both min and max.
    const r3 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = list_params_price(1000, 2000) },
    });
    try std.testing.expectEqual(r3.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r3.result.product_list.items[0].name_slice(), "Mid");
}

test "list filters by name prefix" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x01, "Widget A", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x02, "Widget B", 200) } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(0x03, "Gadget", 300) } });

    var params = std.mem.zeroes(message.ListParams);
    const prefix = "Widget";
    @memcpy(params.name_prefix[0..prefix.len], prefix);
    params.name_prefix_len = prefix.len;

    const r1 = test_execute(&sm, .{
        .operation = .list_products,
        .id = 0,
        .event = .{ .list = params },
    });
    try std.testing.expectEqual(r1.result.product_list.len, 2);
}

test "client-provided IDs" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

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
    var sm = TestStateMachine.init(&storage, false);

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
        .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 30 } },
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
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Low", 0);
    prod_a.inventory = 5;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_b, "Other", 0) } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = id_a,
        .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 10 } },
    });
    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, .{ .operation = .get_product, .id = id_a, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_a.result.product.inventory, 5);
}

test "transfer inventory — source not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_b: u128 = 0xcccc0000000000000000000000000002;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(id_b, "Target", 0) } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = 0xcccc0000000000000000000000000001,
        .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 1 } },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "transfer inventory — target not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xdddd0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 50;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });

    const resp = test_execute(&sm, .{
        .operation = .transfer_inventory,
        .id = id_a,
        .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = 0xdddd0000000000000000000000000002, .quantity = 1 } },
    });
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
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    var prod_b = make_test_product(id_b, "Gadget", 2500);
    prod_b.inventory = 30;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_b } });

    const order_id: u128 = 0xeeee0000000000000000000000000001;
    const resp = test_execute(&sm, .{
        .operation = .create_order,
        .id = order_id,
        .event = .{ .order = make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 2 },
            .{ .id = id_b, .qty = 3 },
        }) },
    });

    try std.testing.expectEqual(resp.status, .ok);
    const order = resp.result.order;
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 2);
    try std.testing.expectEqual(order.items[0].quantity, 2);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.items[0].line_total_cents, 2000);
    try std.testing.expectEqual(order.items[1].quantity, 3);
    try std.testing.expectEqual(order.items[1].line_total_cents, 7500);
    try std.testing.expectEqual(order.total_cents, 9500);

    // Verify inventories were decremented.
    const get_a = test_execute(&sm, .{ .operation = .get_product, .id = id_a, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_a.result.product.inventory, 48);
    const get_b = test_execute(&sm, .{ .operation = .get_product, .id = id_b, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_b.result.product.inventory, 27);
}

test "create order — insufficient inventory rolls back all" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Plenty", 100);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Scarce", 200);
    prod_b.inventory = 2;

    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_b } });

    const resp = test_execute(&sm, .{
        .operation = .create_order,
        .id = 0xeeee0000000000000000000000000002,
        .event = .{ .order = make_order_request(0xeeee0000000000000000000000000002, &.{
            .{ .id = id_a, .qty = 5 },
            .{ .id = id_b, .qty = 10 }, // insufficient
        }) },
    });

    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, .{ .operation = .get_product, .id = id_a, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_a.result.product.inventory, 100);
    const get_b = test_execute(&sm, .{ .operation = .get_product, .id = id_b, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_b.result.product.inventory, 2);
}

test "create order — product not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xcccc0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Exists", 100);
    prod_a.inventory = 10;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });

    const resp = test_execute(&sm, .{
        .operation = .create_order,
        .id = 0xeeee0000000000000000000000000003,
        .event = .{ .order = make_order_request(0xeeee0000000000000000000000000003, &.{
            .{ .id = id_a, .qty = 1 },
            .{ .id = 0xcccc0000000000000000000000000099, .qty = 1 }, // doesn't exist
        }) },
    });

    try std.testing.expectEqual(resp.status, .not_found);
}

test "create order — persisted and retrievable" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = prod_a } });

    const order_id: u128 = 0xeeee0000000000000000000000000010;
    const create_resp = test_execute(&sm, .{
        .operation = .create_order,
        .id = order_id,
        .event = .{ .order = make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 3 },
        }) },
    });
    try std.testing.expectEqual(create_resp.status, .ok);

    // Retrieve by ID.
    const get_resp = test_execute(&sm, .{
        .operation = .get_order,
        .id = order_id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(get_resp.status, .ok);
    const order = get_resp.result.order;
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 1);
    try std.testing.expectEqual(order.items[0].quantity, 3);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.total_cents, 3000);

    // List orders.
    const list_resp = test_execute(&sm, .{
        .operation = .list_orders,
        .id = 0,
        .event = .{ .list = std.mem.zeroes(message.ListParams) },
    });
    try std.testing.expectEqual(list_resp.status, .ok);
    try std.testing.expectEqual(list_resp.result.order_list.len, 1);
    try std.testing.expectEqual(list_resp.result.order_list.items[0].id, order_id);
    try std.testing.expectEqual(list_resp.result.order_list.items[0].total_cents, 3000);
}

test "get order — not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const resp = test_execute(&sm, .{
        .operation = .get_order,
        .id = 0x00000000000000000000000000000099,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqual(resp.status, .not_found);
}

test "create sets version to 1" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0xffff0000000000000000000000000001;
    const resp = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Versioned", 100) },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 1);
}

test "update increments version" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0xffff0000000000000000000000000002;
    _ = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "V1", 100) },
    });

    // Update with correct version.
    var update = make_test_product(0, "V2", 200);
    update.version = 1;
    const resp = test_execute(&sm, .{
        .operation = .update_product,
        .id = test_id,
        .event = .{ .product = update },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 2);
}

test "update with wrong version returns conflict" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0xffff0000000000000000000000000003;
    _ = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Original", 100) },
    });

    // Update with stale version.
    var update = make_test_product(0, "Stale", 999);
    update.version = 5; // current is 1
    const resp = test_execute(&sm, .{
        .operation = .update_product,
        .id = test_id,
        .event = .{ .product = update },
    });
    try std.testing.expectEqual(resp.status, .version_conflict);

    // Verify product was not modified.
    const get_resp = test_execute(&sm, .{
        .operation = .get_product,
        .id = test_id,
        .event = .{ .none = {} },
    });
    try std.testing.expectEqualSlices(u8, get_resp.result.product.name_slice(), "Original");
    try std.testing.expectEqual(get_resp.result.product.version, 1);
}

test "update with version 0 skips check" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0xffff0000000000000000000000000004;
    _ = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "NoCheck", 100) },
    });

    // Update without version (defaults to 0) — should succeed.
    var update = make_test_product(0, "Updated", 200);
    update.version = 0;
    const resp = test_execute(&sm, .{
        .operation = .update_product,
        .id = test_id,
        .event = .{ .product = update },
    });
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 2);
}

test "duplicate ID rejected" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const test_id: u128 = 0x33333333333333333333333333333333;
    const r1 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(test_id, "A", 1) } });
    try std.testing.expectEqual(r1.status, .ok);
    const r2 = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(test_id, "B", 2) } });
    try std.testing.expectEqual(r2.status, .storage_error);
}

test "capacity exhaustion — returns storage_error" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

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

fn make_test_collection(id: u128, name: []const u8) message.ProductCollection {
    var c = std.mem.zeroes(message.ProductCollection);
    c.id = id;
    c.name_len = @intCast(name.len);
    @memcpy(c.name[0..name.len], name);
    return c;
}

test "delete collection cascades memberships but not products" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);

    const product_id: u128 = 0xaaaa0000000000000000000000000001;
    const col_id: u128 = 0xcccc0000000000000000000000000001;

    // Create product and collection.
    _ = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = make_test_product(product_id, "Widget", 100) } });
    _ = test_execute(&sm, .{ .operation = .create_collection, .id = 0, .event = .{ .collection = make_test_collection(col_id, "Sale") } });

    // Add product to collection.
    const add_resp = test_execute(&sm, .{
        .operation = .add_collection_member,
        .id = col_id,
        .event = .{ .member_id = product_id },
    });
    try std.testing.expectEqual(add_resp.status, .ok);

    // Verify product is in collection.
    const get_col = test_execute(&sm, .{ .operation = .get_collection, .id = col_id, .event = .{ .none = {} } });
    try std.testing.expectEqual(get_col.status, .ok);
    try std.testing.expectEqual(get_col.result.collection.products.len, 1);

    // Delete the collection.
    const del_resp = test_execute(&sm, .{ .operation = .delete_collection, .id = col_id, .event = .{ .none = {} } });
    try std.testing.expectEqual(del_resp.status, .ok);

    // Collection is gone.
    const gone = test_execute(&sm, .{ .operation = .get_collection, .id = col_id, .event = .{ .none = {} } });
    try std.testing.expectEqual(gone.status, .not_found);

    // Product still exists.
    const product = test_execute(&sm, .{ .operation = .get_product, .id = product_id, .event = .{ .none = {} } });
    try std.testing.expectEqual(product.status, .ok);
    try std.testing.expectEqualSlices(u8, product.result.product.name_slice(), "Widget");

    // Re-create the collection — should have no members (memberships were cascaded).
    _ = test_execute(&sm, .{ .operation = .create_collection, .id = 0, .event = .{ .collection = make_test_collection(col_id + 1, "New") } });
    // Add the product to the new collection to confirm memberships were cleaned.
    // (If cascade failed, the old membership slot would still be occupied.)
    const add2 = test_execute(&sm, .{
        .operation = .add_collection_member,
        .id = col_id + 1,
        .event = .{ .member_id = product_id },
    });
    try std.testing.expectEqual(add2.status, .ok);
}

test "seeded: transfer inventory conserves total" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);
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
        const r = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = p } });
        try std.testing.expectEqual(r.status, .ok);
    }

    // Random transfers — some succeed, some fail with insufficient_inventory.
    for (0..500) |_| {
        const src_idx = prng.int_inclusive(u8, num_products - 1);
        var dst_idx = prng.int_inclusive(u8, num_products - 2);
        if (dst_idx >= src_idx) dst_idx += 1;

        const qty = prng.range_inclusive(u32, 1, 200);
        const resp = test_execute(&sm, .{
            .operation = .transfer_inventory,
            .id = ids[src_idx],
            .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = ids[dst_idx], .quantity = qty } },
        });

        // Only ok or insufficient_inventory — no storage errors (no fault injection).
        assert(resp.status == .ok or resp.status == .insufficient_inventory);

        // Conservation: sum of all inventories must be unchanged.
        var sum: u64 = 0;
        for (ids) |id| {
            const g = test_execute(&sm, .{ .operation = .get_product, .id = id, .event = .{ .none = {} } });
            assert(g.status == .ok);
            sum += g.result.product.inventory;
        }
        try std.testing.expectEqual(sum, total_inventory);
    }
}

test "seeded: create order arithmetic" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);
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
        const r = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = p } });
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

        const resp = test_execute(&sm, .{
            .operation = .create_order,
            .id = order_id,
            .event = .{ .order = order },
        });

        if (resp.status == .insufficient_inventory) {
            // No inventories changed.
            for (ids, inventories) |id, expected| {
                const g = test_execute(&sm, .{ .operation = .get_product, .id = id, .event = .{ .none = {} } });
                try std.testing.expectEqual(g.result.product.inventory, expected);
            }
            continue;
        }

        try std.testing.expectEqual(resp.status, .ok);
        const result = resp.result.order;
        try std.testing.expectEqual(result.id, order_id);
        try std.testing.expectEqual(result.items_len, @as(u8, @intCast(items_len)));

        // Arithmetic: line_total = price * qty, total = sum(line_totals).
        var expected_total: u64 = 0;
        for (result.items[0..result.items_len]) |item| {
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
            const g = test_execute(&sm, .{ .operation = .get_product, .id = id, .event = .{ .none = {} } });
            try std.testing.expectEqual(g.result.product.inventory, expected);
        }
    }
}

test "seeded: list filters match predicate" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);
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
        const r = test_execute(&sm, .{ .operation = .create_product, .id = 0, .event = .{ .product = p } });
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

        const resp = test_execute(&sm, .{
            .operation = .list_products,
            .id = 0,
            .event = .{ .list = params },
        });
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
        try std.testing.expectEqual(resp.result.product_list.len, capped);
    }
}

test "seeded: update versioning monotonicity" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false);
    var prng = PRNG.from_seed_testing();

    const test_id: u128 = 0xffff0000000000000000000000000099;
    _ = test_execute(&sm, .{
        .operation = .create_product,
        .id = 0,
        .event = .{ .product = make_test_product(test_id, "Seed", 100) },
    });

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

        const resp = test_execute(&sm, .{
            .operation = .update_product,
            .id = test_id,
            .event = .{ .product = update },
        });

        switch (strategy) {
            0, 2 => {
                // Correct version or version 0 — must succeed.
                try std.testing.expectEqual(resp.status, .ok);
                current_version += 1;
                try std.testing.expectEqual(resp.result.product.version, current_version);
            },
            1 => {
                // Stale version — must be rejected.
                try std.testing.expectEqual(resp.status, .version_conflict);
                // Version unchanged.
                const g = test_execute(&sm, .{ .operation = .get_product, .id = test_id, .event = .{ .none = {} } });
                try std.testing.expectEqual(g.result.product.version, current_version);
            },
            else => unreachable,
        }
    }
}

// =====================================================================
// TestEnv — thin helpers over test_execute for readable scenario tests.
//
// Each helper is a direct call to test_execute with compile-time type
// checking on all arguments. Optional assertion fields use Zig's
// anonymous struct defaults — null/0 = don't check.
// =====================================================================

const TestEnv = struct {
    sm: TestStateMachine,
    storage: MemoryStorage,

    fn init(self: *TestEnv) !void {
        self.storage = try MemoryStorage.init(std.testing.allocator);
        self.sm = TestStateMachine.init(&self.storage, false);
    }

    fn deinit(self: *TestEnv) void {
        self.storage.deinit(std.testing.allocator);
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
        const resp = test_execute(&self.sm, .{
            .operation = .create_product,
            .id = 0,
            .event = .{ .product = p },
        });
        assert(resp.status == .ok);
    }

    fn expect_product(self: *TestEnv, id: u128, expect: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        inventory: ?u32 = null,
        version: ?u32 = null,
        active: ?bool = null,
    }) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .get_product,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        const p = resp.result.product;
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
        const g = test_execute(&self.sm, .{ .operation = .get_product, .id = id, .event = .{ .none = {} } });
        assert(g.status == .ok);
        var p = g.result.product;

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, .{
            .operation = .update_product,
            .id = id,
            .event = .{ .product = p },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn update_product_expect(self: *TestEnv, id: u128, opts: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        version: u32 = 0,
    }, expected: message.Status) !void {
        const g = test_execute(&self.sm, .{ .operation = .get_product, .id = id, .event = .{ .none = {} } });
        assert(g.status == .ok);
        var p = g.result.product;

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, .{
            .operation = .update_product,
            .id = id,
            .event = .{ .product = p },
        });
        try std.testing.expectEqual(expected, resp.status);
    }

    fn delete_product(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .delete_product,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_inventory(self: *TestEnv, id: u128, expected: u32) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .get_product_inventory,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.inventory);
    }

    fn expect_product_count(self: *TestEnv, opts: struct {
        filter: message.ListParams.ActiveFilter = .any,
    }, expected: u32) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .list_products,
            .id = 0,
            .event = .{ .list = list_params(opts.filter) },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.product_list.len);
    }

    // --- Collections ---

    fn create_collection(self: *TestEnv, opts: struct {
        id: u128,
        name: []const u8,
    }) void {
        const col = make_test_collection(opts.id, opts.name);
        const resp = test_execute(&self.sm, .{
            .operation = .create_collection,
            .id = 0,
            .event = .{ .collection = col },
        });
        assert(resp.status == .ok);
    }

    fn expect_collection(self: *TestEnv, id: u128, expect: struct {
        product_count: ?u32 = null,
    }) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .get_collection,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.product_count) |v| try std.testing.expectEqual(v, resp.result.collection.products.len);
    }

    fn delete_collection(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .delete_collection,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_collection_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .list_collections,
            .id = 0,
            .event = .{ .list = std.mem.zeroes(message.ListParams) },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.collection_list.len);
    }

    fn add_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .add_collection_member,
            .id = collection_id,
            .event = .{ .member_id = product_id },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn remove_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .remove_collection_member,
            .id = collection_id,
            .event = .{ .member_id = product_id },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Transfers ---

    fn transfer(self: *TestEnv, source_id: u128, target_id: u128, quantity: u32) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .transfer_inventory,
            .id = source_id,
            .event = .{ .transfer = .{ .reserved = .{0} ** 12, .target_id = target_id, .quantity = quantity } },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Orders ---

    fn create_order(self: *TestEnv, id: u128, items: []const message.OrderItem) !message.OrderResult {
        var req = std.mem.zeroes(message.OrderRequest);
        req.id = id;
        req.items_len = @intCast(items.len);
        @memcpy(req.items[0..items.len], items);
        const resp = test_execute(&self.sm, .{
            .operation = .create_order,
            .id = 0,
            .event = .{ .order = req },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        return resp.result.order;
    }

    fn expect_order(self: *TestEnv, id: u128, expect: struct {
        total: ?u64 = null,
    }) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .get_order,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.total) |v| try std.testing.expectEqual(v, resp.result.order.total_cents);
    }

    fn expect_order_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, .{
            .operation = .list_orders,
            .id = 0,
            .event = .{ .list = std.mem.zeroes(message.ListParams) },
        });
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.order_list.len);
    }

    // --- Generic not-found assertions ---

    fn expect_not_found(self: *TestEnv, op: message.Operation, id: u128) !void {
        const resp = test_execute(&self.sm, .{
            .operation = op,
            .id = id,
            .event = .{ .none = {} },
        });
        try std.testing.expectEqual(message.Status.not_found, resp.status);
    }

    fn expect_status(self: *TestEnv, op: message.Operation, id: u128, event: message.Event, expected: message.Status) !void {
        const resp = test_execute(&self.sm, .{
            .operation = op,
            .id = id,
            .event = event,
        });
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

    try env.expect_status(.transfer_inventory, 1, .{ .transfer = .{ .target_id = 2, .quantity = 100, .reserved = .{0} ** 12 } }, .insufficient_inventory);

    try env.expect_inventory(1, 35); // unchanged
    try env.expect_inventory(2, 25);

    try env.expect_status(.transfer_inventory, 99, .{ .transfer = .{ .target_id = 2, .quantity = 1, .reserved = .{0} ** 12 } }, .not_found);
    try env.expect_status(.transfer_inventory, 1, .{ .transfer = .{ .target_id = 99, .quantity = 1, .reserved = .{0} ** 12 } }, .not_found);
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
    try env.expect_status(.create_order, 0, .{ .order = fail_req }, .insufficient_inventory);

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
    try env.expect_status(.add_collection_member, 99, .{ .member_id = 1 }, .not_found); // collection missing
    try env.expect_status(.add_collection_member, 1, .{ .member_id = 99 }, .not_found); // product missing

    try env.expect_collection(1, .{ .product_count = 2 });

    try env.remove_member(1, 1);

    try env.expect_collection(1, .{ .product_count = 1 }); // P2 remains

    try env.expect_status(.remove_collection_member, 1, .{ .member_id = 1 }, .not_found); // already removed
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
