//! Auditor — reference model that tracks expected state and validates
//! state machine responses. Follows TigerBeetle's auditor.zig pattern.
//!
//! Maintains a shadow copy of all entity state (products, collections,
//! memberships, orders). After each commit, validates the response
//! against its model and updates the model. Catches bugs in execute
//! handlers that storage backends wouldn't catch.
//!
//! Storage errors are ignored — they indicate injected faults, not
//! logic bugs. All other responses are validated exhaustively.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const MemoryStorage = state_machine.MemoryStorage;
const stdx = @import("tiger_framework").stdx;
const gen = @import("fuzz.zig");

const product_capacity = MemoryStorage.product_capacity;
const collection_capacity = MemoryStorage.collection_capacity;
const membership_capacity = MemoryStorage.membership_capacity;
const order_capacity = MemoryStorage.order_capacity;
const login_code_capacity = MemoryStorage.login_code_capacity;
const user_capacity = MemoryStorage.user_capacity;
const id_pool_capacity = gen.id_pool_capacity;

const Membership = struct { collection_id: u128, product_id: u128, removed: bool };

const AuditorLoginCode = struct {
    email: [message.email_max]u8,
    email_len: u8,
    code: [message.code_length]u8,
    expires_at: i64,
};

const AuditorUser = struct {
    user_id: u128,
    email: [message.email_max]u8,
    email_len: u8,
};

pub const Auditor = struct {
    products: *[product_capacity]?message.Product,
    product_count: u32,

    collections: *[collection_capacity]?message.ProductCollection,
    collection_count: u32,

    memberships: *[membership_capacity]?Membership,
    membership_count: u32,

    orders: *[order_capacity]?message.OrderResult,
    order_count: u32,

    login_codes: [login_code_capacity]?AuditorLoginCode,
    users: [user_capacity]?AuditorUser,

    // ID pools for gen_message — bounded sample of known IDs.
    product_ids: [id_pool_capacity]u128,
    product_id_count: u32,
    collection_ids: [id_pool_capacity]u128,
    collection_id_count: u32,
    order_ids: [id_pool_capacity]u128,
    order_id_count: u32,

    pub fn init(allocator: std.mem.Allocator) !Auditor {
        const products = try allocator.create([product_capacity]?message.Product);
        @memset(products, null);
        const collections = try allocator.create([collection_capacity]?message.ProductCollection);
        @memset(collections, null);
        const memberships = try allocator.create([membership_capacity]?Membership);
        @memset(memberships, null);
        const orders = try allocator.create([order_capacity]?message.OrderResult);
        @memset(orders, null);

        return .{
            .products = products,
            .product_count = 0,
            .collections = collections,
            .collection_count = 0,
            .memberships = memberships,
            .membership_count = 0,
            .orders = orders,
            .order_count = 0,
            .login_codes = [_]?AuditorLoginCode{null} ** login_code_capacity,
            .users = [_]?AuditorUser{null} ** user_capacity,
            .product_ids = undefined,
            .product_id_count = 0,
            .collection_ids = undefined,
            .collection_id_count = 0,
            .order_ids = undefined,
            .order_id_count = 0,
        };
    }

    pub fn deinit(self: *Auditor, allocator: std.mem.Allocator) void {
        allocator.destroy(self.orders);
        allocator.destroy(self.memberships);
        allocator.destroy(self.collections);
        allocator.destroy(self.products);
    }

    pub fn id_pools(self: *const Auditor) gen.IdPools {
        return .{
            .product_ids = self.product_ids[0..self.product_id_count],
            .collection_ids = self.collection_ids[0..self.collection_id_count],
            .order_ids = self.order_ids[0..self.order_id_count],
        };
    }

    /// Exhaustive capacity check — adding a new Operation variant forces
    /// the developer to decide whether it has capacity constraints.
    /// Returns true if MemoryStorage is near capacity for this operation.
    pub fn at_capacity(self: *const Auditor, operation: message.Operation) bool {
        return switch (operation) {
            .root => unreachable,
            .create_product => self.product_count >= capacity_threshold(product_capacity),
            .create_collection => self.collection_count >= capacity_threshold(collection_capacity),
            .create_order => self.order_count >= capacity_threshold(order_capacity),
            .add_collection_member => self.membership_count >= capacity_threshold(membership_capacity),
            .get_product,
            .get_product_inventory,
            .update_product,
            .delete_product,
            .get_collection,
            .delete_collection,
            .remove_collection_member,
            .get_order,
            .complete_order,
            .cancel_order,
            .list_products,
            .search_products,
            .list_collections,
            .list_orders,
            .transfer_inventory,
            .page_load_dashboard,
            .page_load_login,
            .request_login_code,
            .verify_login_code,
            .logout,
            => false,
        };
    }

    /// Conservative threshold below MemoryStorage capacity. Leaves headroom
    /// for the ~10% random messages that bypass gen_message's switch.
    fn capacity_threshold(comptime capacity: u32) u32 {
        return capacity - capacity / 8;
    }

    /// Validate the response and update the model.
    /// Called after every successful prefetch+commit.
    pub fn on_commit(self: *Auditor, msg: message.Message, resp: message.MessageResponse) void {
        // Storage errors indicate injected faults — no state change,
        // nothing to validate.
        if (resp.status == .storage_error) return;

        switch (msg.operation) {
            .root => unreachable,
            .create_product => self.on_create_product(msg.body_as(message.Product).*, resp),
            .get_product => self.on_get_product(msg.id, resp),
            .get_product_inventory => self.on_get_inventory(msg.id, resp),
            .update_product => self.on_update_product(msg.id, msg.body_as(message.Product).*, resp),
            .delete_product => self.on_delete_product(msg.id, resp),
            .transfer_inventory => self.on_transfer_inventory(msg.id, msg.body_as(message.InventoryTransfer).*, resp),
            .create_order => self.on_create_order(msg.body_as(message.OrderRequest).*, resp),
            .complete_order => self.on_complete_order(msg.id, msg.body_as(message.OrderCompletion).*, resp),
            .cancel_order => self.on_cancel_order(msg.id, resp),
            .get_order => self.on_get_order(msg.id, resp),
            .create_collection => self.on_create_collection(msg.body_as(message.ProductCollection).*, resp),
            .get_collection => self.on_get_collection(msg.id, resp),
            .delete_collection => self.on_delete_collection(msg.id, resp),
            .add_collection_member => self.on_add_member(msg.id, msg.body_as(u128).*, resp),
            .remove_collection_member => self.on_remove_member(msg.id, msg.body_as(u128).*, resp),
            .list_products => self.on_list_products(resp),
            .search_products => self.on_search_products(msg.body_as(message.SearchQuery).*, resp),
            .list_collections => self.on_list_collections(resp),
            .list_orders => self.on_list_orders(resp),
            .page_load_dashboard => self.on_page_load_dashboard(resp),
            .page_load_login => assert(resp.status == .ok),
            .logout => {
                assert(resp.status == .ok);
                assert(resp.session_action == .clear);
            },
            .request_login_code => self.on_request_login_code(msg, resp),
            .verify_login_code => self.on_verify_login_code(msg, resp),
        }
    }

    // =================================================================
    // Product handlers
    // =================================================================

    fn on_create_product(self: *Auditor, input: message.Product, resp: message.MessageResponse) void {
        if (self.find_product(input.id) != null) {
            assert(resp.status == .storage_error);
            return;
        }

        assert(resp.status == .ok);

        // Validate returned product matches input semantically.
        // The state machine reconstructs canonical storage (zeroed trailing
        // bytes), so byte-wise comparison against the input would fail.
        const returned = resp.result.product;
        assert(returned.id == input.id);
        assert(returned.name_len == input.name_len);
        assert(std.mem.eql(u8, returned.name[0..returned.name_len], input.name[0..input.name_len]));
        assert(returned.description_len == input.description_len);
        assert(std.mem.eql(u8, returned.description[0..returned.description_len], input.description[0..input.description_len]));
        assert(returned.price_cents == input.price_cents);
        assert(returned.inventory == input.inventory);
        assert(returned.version == 1);
        assert(returned.flags.active == input.flags.active);

        // Update model with the canonical returned value.
        const slot = self.find_empty_product_slot();
        self.products[slot] = returned;
        self.product_count += 1;

        if (self.product_id_count < id_pool_capacity) {
            self.product_ids[self.product_id_count] = input.id;
            self.product_id_count += 1;
        }
    }

    fn on_get_product(self: *const Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_product(id);
        if (idx == null or !self.products[idx.?].?.flags.active) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);
        assert_product_equal(&self.products[idx.?].?, &resp.result.product);
    }

    fn on_get_inventory(self: *const Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_product(id);
        if (idx == null or !self.products[idx.?].?.flags.active) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);
        assert(resp.result.inventory == self.products[idx.?].?.inventory);
    }

    fn on_update_product(self: *Auditor, id: u128, input: message.Product, resp: message.MessageResponse) void {
        const idx = self.find_product(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        const current = self.products[idx].?;

        // Version check: 0 = no check, else must match.
        if (input.version != 0 and input.version != current.version) {
            assert(resp.status == .version_conflict);
            return;
        }

        assert(resp.status == .ok);

        // Validate returned product matches input semantically.
        const returned = resp.result.product;
        assert(returned.id == id);
        assert(returned.name_len == input.name_len);
        assert(std.mem.eql(u8, returned.name[0..returned.name_len], input.name[0..input.name_len]));
        assert(returned.description_len == input.description_len);
        assert(std.mem.eql(u8, returned.description[0..returned.description_len], input.description[0..input.description_len]));
        assert(returned.price_cents == input.price_cents);
        assert(returned.inventory == input.inventory);
        assert(returned.version == current.version + 1);
        assert(returned.flags.active == input.flags.active);

        // Update model with the canonical returned value.
        self.products[idx] = returned;
    }

    fn on_delete_product(self: *Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_product(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        if (!self.products[idx].?.flags.active) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);

        // Update model: soft delete.
        var p = self.products[idx].?;
        p.flags.active = false;
        p.version += 1;
        self.products[idx] = p;

        // Remove from ID pool.
        self.remove_product_id(id);
    }

    fn on_transfer_inventory(self: *Auditor, source_id: u128, transfer: message.InventoryTransfer, resp: message.MessageResponse) void {
        const src_idx = self.find_product(source_id) orelse {
            assert(resp.status == .not_found);
            return;
        };
        const tgt_idx = self.find_product(transfer.target_id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        if (self.products[src_idx].?.inventory < transfer.quantity) {
            assert(resp.status == .insufficient_inventory);
            return;
        }

        assert(resp.status == .ok);

        // Update model.
        var source = self.products[src_idx].?;
        var target = self.products[tgt_idx].?;
        source.inventory -= transfer.quantity;
        target.inventory += transfer.quantity;
        self.products[src_idx] = source;
        self.products[tgt_idx] = target;

        // Validate returned products.
        const result_list = resp.result.product_list;
        assert(result_list.len == 2);
        assert_product_equal(&source, &result_list.items[0]);
        assert_product_equal(&target, &result_list.items[1]);
    }

    // =================================================================
    // Order handlers
    // =================================================================

    fn on_create_order(self: *Auditor, order: message.OrderRequest, resp: message.MessageResponse) void {
        // Check all products exist.
        for (order.items_slice()) |item| {
            if (self.find_product(item.product_id) == null) {
                assert(resp.status == .not_found);
                return;
            }
        }

        // Check all have sufficient inventory.
        for (order.items_slice()) |item| {
            const product = self.products[self.find_product(item.product_id).?].?;
            if (product.inventory < item.quantity) {
                assert(resp.status == .insufficient_inventory);
                return;
            }
        }

        assert(resp.status == .ok);

        const result = resp.result.order;
        assert(result.id == order.id);
        assert(result.items_len == order.items_len);

        // Validate each line item and update model.
        var expected_total: u64 = 0;
        for (order.items_slice(), 0..) |item, i| {
            const idx = self.find_product(item.product_id).?;
            const product = self.products[idx].?;

            // Validate line item.
            const result_item = result.items[i];
            assert(result_item.product_id == item.product_id);
            assert(result_item.quantity == item.quantity);
            assert(result_item.price_cents == product.price_cents);
            const expected_line = @as(u64, product.price_cents) * @as(u64, item.quantity);
            assert(result_item.line_total_cents == expected_line);

            expected_total +|= expected_line;

            // Update model: deduct inventory.
            var p = self.products[idx].?;
            p.inventory -= item.quantity;
            self.products[idx] = p;
        }

        assert(result.total_cents == expected_total);
        assert(result.status == .pending);
        assert(result.timeout_at > 0);

        // Add order to model.
        const order_slot = self.find_empty_order_slot();
        self.orders[order_slot] = result;
        self.order_count += 1;

        if (self.order_id_count < id_pool_capacity) {
            self.order_ids[self.order_id_count] = order.id;
            self.order_id_count += 1;
        }
    }

    fn on_complete_order(self: *Auditor, id: u128, completion: message.OrderCompletion, resp: message.MessageResponse) void {
        const idx = self.find_order(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        var order = self.orders[idx].?;

        if (order.status != .pending) {
            // Idempotent: matching terminal state returns OK.
            if (order.status == .confirmed and completion.result == .confirmed) {
                assert(resp.status == .ok);
                return;
            }
            if (order.status == .failed and completion.result == .failed) {
                assert(resp.status == .ok);
                return;
            }
            assert(resp.status == .order_not_pending);
            return;
        }

        // We can't check timeout precisely because the fuzz doesn't
        // control time deterministically vs the state machine's `now`.
        // Accept ok, order_expired, or order_not_pending.
        if (resp.status == .order_expired) {
            order.status = .failed;
            self.orders[idx] = order;
            // Restore inventory in model.
            for (order.items[0..order.items_len]) |item| {
                if (self.find_product(item.product_id)) |pidx| {
                    var p = self.products[pidx].?;
                    p.inventory += item.quantity;
                    self.products[pidx] = p;
                }
            }
            return;
        }

        assert(resp.status == .ok);

        switch (completion.result) {
            .confirmed => {
                order.status = .confirmed;
                order.payment_ref = completion.payment_ref;
                order.payment_ref_len = completion.payment_ref_len;
                self.orders[idx] = order;
            },
            .failed => {
                order.status = .failed;
                self.orders[idx] = order;
                // Restore inventory in model.
                for (order.items[0..order.items_len]) |item| {
                    if (self.find_product(item.product_id)) |pidx| {
                        var p = self.products[pidx].?;
                        p.inventory += item.quantity;
                        self.products[pidx] = p;
                    }
                }
            },
        }
    }

    fn on_cancel_order(self: *Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_order(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        var order = self.orders[idx].?;

        if (order.status != .pending) {
            assert(resp.status == .order_not_pending);
            return;
        }

        assert(resp.status == .ok);

        order.status = .cancelled;
        self.orders[idx] = order;

        // Restore inventory in model.
        for (order.items[0..order.items_len]) |item| {
            if (self.find_product(item.product_id)) |pidx| {
                var p = self.products[pidx].?;
                p.inventory += item.quantity;
                self.products[pidx] = p;
            }
        }
    }

    fn on_get_order(self: *const Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_order(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        assert(resp.status == .ok);

        const expected = self.orders[idx].?;
        const actual = resp.result.order;
        assert(expected.id == actual.id);
        assert(expected.total_cents == actual.total_cents);
        assert(expected.items_len == actual.items_len);
        for (expected.items[0..expected.items_len], actual.items[0..actual.items_len]) |*e, *a| {
            assert(stdx.equal_bytes(message.OrderResultItem, e, a));
        }
    }

    // =================================================================
    // Collection handlers
    // =================================================================

    fn on_create_collection(self: *Auditor, input: message.ProductCollection, resp: message.MessageResponse) void {
        if (self.find_collection(input.id) != null) {
            assert(resp.status == .storage_error);
            return;
        }

        assert(resp.status == .ok);

        const returned = resp.result.collection;
        // Compare semantic fields — the state machine reconstructs canonical
        // storage (zeroed trailing bytes), so byte-wise comparison against the
        // input would fail. Compare what matters: id and name content.
        assert(returned.collection.id == input.id);
        assert(returned.collection.name_len == input.name_len);
        assert(std.mem.eql(u8, returned.collection.name[0..returned.collection.name_len], input.name[0..input.name_len]));
        assert(returned.products.len == 0);

        // Update model with the canonical returned value.
        const slot = self.find_empty_collection_slot();
        self.collections[slot] = returned.collection;
        self.collection_count += 1;

        if (self.collection_id_count < id_pool_capacity) {
            self.collection_ids[self.collection_id_count] = input.id;
            self.collection_id_count += 1;
        }
    }

    fn on_get_collection(self: *const Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_collection(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        if (!self.collections[idx].?.flags.active) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);

        const returned = resp.result.collection;
        assert(stdx.equal_bytes(message.ProductCollection, &self.collections[idx].?, &returned.collection));

        // Validate member products: all returned products should be active members
        // and match the model.
        for (returned.products.items[0..returned.products.len]) |*p| {
            const p_idx = self.find_product(p.id);
            assert(p_idx != null);
            assert(self.find_active_membership(id, p.id) != null);
            assert_product_equal(&self.products[p_idx.?].?, p);
        }

        // Count expected members (active memberships with products that still exist).
        var expected_count: u32 = 0;
        for (self.memberships) |slot| {
            const m = slot orelse continue;
            if (m.collection_id == id and !m.removed and self.find_product(m.product_id) != null) {
                expected_count += 1;
            }
        }
        assert(returned.products.len == @min(expected_count, message.list_max));
    }

    fn on_delete_collection(self: *Auditor, id: u128, resp: message.MessageResponse) void {
        const idx = self.find_collection(id) orelse {
            assert(resp.status == .not_found);
            return;
        };

        if (!self.collections[idx].?.flags.active) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);

        // Update model: soft delete (set flag, keep memberships).
        var col = self.collections[idx].?;
        col.flags.active = false;
        self.collections[idx] = col;

        // Remove from ID pool.
        self.remove_collection_id(id);
    }

    fn on_add_member(self: *Auditor, collection_id: u128, product_id: u128, resp: message.MessageResponse) void {
        // Prefetch checks both collection and product exist.
        if (self.find_collection(collection_id) == null or self.find_product(product_id) == null) {
            assert(resp.status == .not_found);
            return;
        }

        assert(resp.status == .ok);

        // Add to model — un-remove if already exists, else insert.
        if (self.find_membership_any(collection_id, product_id)) |idx| {
            self.memberships[idx].?.removed = false;
        } else {
            const slot = self.find_empty_membership_slot();
            self.memberships[slot] = .{ .collection_id = collection_id, .product_id = product_id, .removed = false };
            self.membership_count += 1;
        }
    }

    fn on_remove_member(self: *Auditor, collection_id: u128, product_id: u128, resp: message.MessageResponse) void {
        if (self.find_collection(collection_id) == null) {
            assert(resp.status == .not_found);
            return;
        }

        // Remove is idempotent — always ok if collection exists.
        assert(resp.status == .ok);

        if (self.find_active_membership(collection_id, product_id)) |m_idx| {
            self.memberships[m_idx].?.removed = true;
        }
    }

    // =================================================================
    // List handlers — validate all returned entities exist and match.
    // Exact filtering/sorting is validated by storage_fuzz.zig.
    // =================================================================

    fn on_list_products(self: *const Auditor, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        const list = resp.result.product_list;
        for (list.items[0..list.len]) |*p| {
            const idx = self.find_product(p.id) orelse {
                std.debug.panic("list returned unknown product id={}", .{p.id});
            };
            assert_product_equal(&self.products[idx].?, p);
        }
    }

    fn on_search_products(self: *const Auditor, query: message.SearchQuery, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        const list = resp.result.product_list;

        // Compute expected result set independently.
        var expected_count: u32 = 0;
        for (self.products) |maybe_product| {
            const product = maybe_product orelse continue;
            if (!product.flags.active) continue;
            if (query.matches(&product)) expected_count += 1;
        }

        // Result count must match (capped at list_max).
        const capped = @min(expected_count, message.list_max);
        if (list.len != capped) {
            std.debug.panic("search result count mismatch: expected={} got={}", .{ capped, list.len });
        }

        // Every returned product must exist, be active, match the query, and have correct data.
        for (list.items[0..list.len]) |*p| {
            const idx = self.find_product(p.id) orelse {
                std.debug.panic("search returned unknown product id={}", .{p.id});
            };
            assert(self.products[idx].?.flags.active);
            assert(query.matches(&self.products[idx].?));
            assert_product_equal(&self.products[idx].?, p);
        }
    }

    fn on_list_collections(self: *const Auditor, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        const list = resp.result.collection_list;
        for (list.items[0..list.len]) |*col| {
            const idx = self.find_collection(col.id) orelse {
                std.debug.panic("list returned unknown collection id={}", .{col.id});
            };
            assert(self.collections[idx].?.flags.active);
            assert(stdx.equal_bytes(message.ProductCollection, &self.collections[idx].?, col));
        }
    }

    fn on_list_orders(self: *const Auditor, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        const list = resp.result.order_list;
        for (list.items[0..list.len]) |summary| {
            const idx = self.find_order(summary.id) orelse {
                std.debug.panic("list returned unknown order id={}", .{summary.id});
            };
            const expected = self.orders[idx].?;
            assert(summary.total_cents == expected.total_cents);
            assert(summary.items_len == expected.items_len);
        }
    }

    fn on_page_load_dashboard(self: *const Auditor, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        const dashboard = resp.result.page_load_dashboard;

        // Domain cap: state machine must not return more than dashboard_list_max.
        assert(dashboard.products.len <= message.dashboard_list_max);
        assert(dashboard.collections.len <= message.dashboard_list_max);
        assert(dashboard.orders.len <= message.dashboard_list_max);

        // Validate each sub-list is consistent with the model.
        for (dashboard.products.items[0..dashboard.products.len]) |p| {
            assert(self.find_product(p.id) != null);
            // Dashboard uses active_filter=.active_only — no inactive products.
            assert(p.flags.active);
        }
        for (dashboard.collections.items[0..dashboard.collections.len]) |col| {
            const idx = self.find_collection(col.id);
            assert(idx != null);
            assert(self.collections[idx.?].?.flags.active);
        }
        for (dashboard.orders.items[0..dashboard.orders.len]) |o| {
            assert(self.find_order(o.id) != null);
        }
    }

    // =================================================================
    // Lookup helpers
    // =================================================================

    fn find_product(self: *const Auditor, id: u128) ?usize {
        for (self.products, 0..) |slot, i| {
            if (slot) |p| {
                if (p.id == id) return i;
            }
        }
        return null;
    }

    fn find_collection(self: *const Auditor, id: u128) ?usize {
        for (self.collections, 0..) |slot, i| {
            if (slot) |c| {
                if (c.id == id) return i;
            }
        }
        return null;
    }

    fn find_order(self: *const Auditor, id: u128) ?usize {
        for (self.orders, 0..) |slot, i| {
            if (slot) |o| {
                if (o.id == id) return i;
            }
        }
        return null;
    }

    /// Find an active (non-removed) membership.
    fn find_active_membership(self: *const Auditor, collection_id: u128, product_id: u128) ?usize {
        for (self.memberships, 0..) |slot, i| {
            if (slot) |m| {
                if (m.collection_id == collection_id and m.product_id == product_id and !m.removed) return i;
            }
        }
        return null;
    }

    /// Find a membership regardless of removed status.
    fn find_membership_any(self: *const Auditor, collection_id: u128, product_id: u128) ?usize {
        for (self.memberships, 0..) |slot, i| {
            if (slot) |m| {
                if (m.collection_id == collection_id and m.product_id == product_id) return i;
            }
        }
        return null;
    }

    // =================================================================
    // Login handlers
    // =================================================================

    fn on_request_login_code(self: *Auditor, msg: message.Message, resp: message.MessageResponse) void {
        assert(resp.status == .ok);
        assert(resp.session_action == .none);

        const result = resp.result.login;
        const event = msg.body_as(message.LoginCodeRequest);

        // Result email matches request email.
        assert(result.email_len == event.email_len);
        assert(std.mem.eql(u8, result.email[0..result.email_len], event.email[0..event.email_len]));

        // Code is non-zero (all digits).
        const zero_code: [message.code_length]u8 = .{0} ** message.code_length;
        assert(!std.mem.eql(u8, &result.code, &zero_code));
        for (result.code) |c| {
            assert(c >= '0' and c <= '9');
        }

        // user_id must be 0 for code request (no authentication yet).
        assert(result.user_id == 0);

        // Store in model — overwrite any existing code for this email.
        const email = event.email[0..event.email_len];
        for (&self.login_codes) |*slot| {
            if (slot.*) |*existing| {
                if (existing.email_len == email.len and
                    std.mem.eql(u8, existing.email[0..existing.email_len], email))
                {
                    existing.code = result.code;
                    existing.expires_at = std.math.maxInt(i64); // auditor doesn't track time
                    return;
                }
            }
        }
        for (&self.login_codes) |*slot| {
            if (slot.* == null) {
                slot.* = .{
                    .email = event.email,
                    .email_len = event.email_len,
                    .code = result.code,
                    .expires_at = std.math.maxInt(i64),
                };
                return;
            }
        }
        // Login code capacity exceeded — not a bug, just a test limit.
    }

    fn on_verify_login_code(self: *Auditor, msg: message.Message, resp: message.MessageResponse) void {
        const event = msg.body_as(message.LoginVerification);
        const email = event.email[0..event.email_len];

        // Find stored code for this email.
        const stored = self.find_login_code(email);

        if (stored == null) {
            // No code stored → must be invalid_code.
            assert(resp.status == .invalid_code);
            return;
        }

        if (!std.mem.eql(u8, &stored.?.code, &event.code)) {
            // Wrong code → must be invalid_code.
            assert(resp.status == .invalid_code);
            return;
        }

        // Note: we don't track time expiry in the auditor (the fuzzer
        // sets sm.now but the auditor doesn't model it). Code expired
        // responses are accepted without assertion.
        if (resp.status == .code_expired) return;

        // Correct code → must succeed.
        assert(resp.status == .ok);
        assert(resp.session_action == .set_authenticated);

        const result = resp.result.login;
        assert(result.user_id != 0);
        assert(result.email_len == event.email_len);
        assert(std.mem.eql(u8, result.email[0..result.email_len], email));

        // Code consumed — remove from model.
        self.remove_login_code(email);

        // Validate user_id consistency: same email → same user_id.
        if (self.find_user_by_email(email)) |existing_user| {
            assert(result.user_id == existing_user.user_id);
        } else {
            // New user — store in model.
            for (&self.users) |*slot| {
                if (slot.* == null) {
                    slot.* = .{
                        .user_id = result.user_id,
                        .email = event.email,
                        .email_len = event.email_len,
                    };
                    break;
                }
            }
        }
    }

    fn find_login_code(self: *const Auditor, email: []const u8) ?AuditorLoginCode {
        for (self.login_codes) |slot| {
            if (slot) |entry| {
                if (entry.email_len == email.len and
                    std.mem.eql(u8, entry.email[0..entry.email_len], email))
                {
                    return entry;
                }
            }
        }
        return null;
    }

    fn remove_login_code(self: *Auditor, email: []const u8) void {
        for (&self.login_codes) |*slot| {
            if (slot.*) |entry| {
                if (entry.email_len == email.len and
                    std.mem.eql(u8, entry.email[0..entry.email_len], email))
                {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    fn find_user_by_email(self: *const Auditor, email: []const u8) ?AuditorUser {
        for (self.users) |slot| {
            if (slot) |entry| {
                if (entry.email_len == email.len and
                    std.mem.eql(u8, entry.email[0..entry.email_len], email))
                {
                    return entry;
                }
            }
        }
        return null;
    }

    fn find_empty_product_slot(self: *const Auditor) usize {
        for (self.products, 0..) |slot, i| {
            if (slot == null) return i;
        }
        unreachable; // capacity_threshold prevents overflow
    }

    fn find_empty_collection_slot(self: *const Auditor) usize {
        for (self.collections, 0..) |slot, i| {
            if (slot == null) return i;
        }
        unreachable;
    }

    fn find_empty_membership_slot(self: *const Auditor) usize {
        for (self.memberships, 0..) |slot, i| {
            if (slot == null) return i;
        }
        unreachable;
    }

    fn find_empty_order_slot(self: *const Auditor) usize {
        for (self.orders, 0..) |slot, i| {
            if (slot == null) return i;
        }
        unreachable;
    }

    // =================================================================
    // ID pool management
    // =================================================================

    fn remove_product_id(self: *Auditor, id: u128) void {
        for (self.product_ids[0..self.product_id_count], 0..) |pid, i| {
            if (pid == id) {
                self.product_id_count -= 1;
                self.product_ids[i] = self.product_ids[self.product_id_count];
                return;
            }
        }
    }

    fn remove_collection_id(self: *Auditor, id: u128) void {
        for (self.collection_ids[0..self.collection_id_count], 0..) |cid, i| {
            if (cid == id) {
                self.collection_id_count -= 1;
                self.collection_ids[i] = self.collection_ids[self.collection_id_count];
                return;
            }
        }
    }
};

fn assert_product_equal(expected: *const message.Product, actual: *const message.Product) void {
    if (!stdx.equal_bytes(message.Product, expected, actual)) {
        std.debug.panic(
            "product mismatch: expected id={} version={} inventory={}, got id={} version={} inventory={}",
            .{
                expected.id, expected.version, expected.inventory,
                actual.id, actual.version, actual.inventory,
            },
        );
    }
}
