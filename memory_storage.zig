//! MemoryStorage — in-memory storage backend for simulation testing.
//!
//! Responsibilities:
//!   1. Speed — no SQL, no disk, no syscalls. Fuzz tests run millions of
//!      operations per second against this backend.
//!   2. Determinism — given the same PRNG seed, produces identical results
//!      every time. Failures are reproducible by replaying the seed.
//!   3. Fault injection — returns busy/err on any read operation, controlled
//!      by the PRNG. Exercises every error-handling path in the framework
//!      without needing a real database that misbehaves on command.
//!
//! NOT responsibilities:
//!   - Correctness oracle for SqliteStorage. We do not compare MemoryStorage
//!     results against SQL results. The database executes SQL correctly —
//!     that's its job, not ours. See docs/plans/storage-boundary.md.
//!   - Domain logic validation. Checking that "inventory transfers preserve
//!     totals" is a user-space concern, not a storage concern. The framework
//!     provides the sim harness; the user provides the auditor.
//!   - Production use. This backend exists only in test/fuzz builds.
//!
//! Interface contract:
//!   MemoryStorage implements the same method set as SqliteStorage so that
//!   StateMachineType(Storage) can be parameterized on either at comptime.
//!   The interface is domain-specific (get, put, list, etc.) because that's
//!   what the state machine dispatches to. Both backends must agree on the
//!   method signatures; they need not agree on internal representation.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const StorageResult = state_machine.StorageResult;
const marks = @import("tiger_framework").marks;
const log = marks.wrap_log(std.log.scoped(.state_machine));
const PRNG = @import("tiger_framework").prng;

pub const MemoryStorage = struct {
    /// Read-only view for prefetch phase. Delegates to self with fault injection.
    pub const ReadView = struct {
        storage: *MemoryStorage,

        pub fn init(storage: *MemoryStorage) ReadView {
            return .{ .storage = storage };
        }

        pub fn get(self: ReadView, id: u128, out: *message.Product) StorageResult {
            return self.storage.get(id, out);
        }

        pub fn get_collection(self: ReadView, id: u128, out: *message.ProductCollection) StorageResult {
            return self.storage.get_collection(id, out);
        }

        pub fn get_order(self: ReadView, id: u128, out: *message.OrderResult) StorageResult {
            return self.storage.get_order(id, out);
        }

        pub fn list(self: ReadView, out: *[message.list_max]message.Product, out_len: *u32, params: message.ListParams) StorageResult {
            return self.storage.list(out, out_len, params);
        }

        pub fn list_collections(self: ReadView, out: *[message.list_max]message.ProductCollection, out_len: *u32, cursor: u128) StorageResult {
            return self.storage.list_collections(out, out_len, cursor);
        }

        pub fn list_products_in_collection(self: ReadView, collection_id: u128, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
            return self.storage.list_products_in_collection(collection_id, out, out_len);
        }

        pub fn list_orders(self: ReadView, out: *[message.list_max]message.OrderSummary, out_len: *u32, cursor: u128) StorageResult {
            return self.storage.list_orders(out, out_len, cursor);
        }

        pub fn search(self: ReadView, out: *[message.list_max]message.Product, out_len: *u32, query: message.SearchQuery) StorageResult {
            return self.storage.search(out, out_len, query);
        }

        pub fn get_login_code(self: ReadView, email: []const u8, out: *LoginCodeEntry) StorageResult {
            return self.storage.get_login_code(email, out);
        }

        pub fn get_user_by_email(self: ReadView, email: []const u8, out: *u128) StorageResult {
            return self.storage.get_user_by_email(email, out);
        }
    };

    pub const product_capacity = 1024;
    pub const collection_capacity = 256;
    pub const membership_capacity = 1024;
    pub const order_capacity = 256;
    pub const login_code_capacity = 64;
    pub const user_capacity = 256;

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
        removed: bool,
    };

    const OrderEntry = struct {
        order: message.OrderResult,
        occupied: bool,
    };

    pub const LoginCodeEntry = message.LoginCodeEntry;

    const UserEntry = struct {
        user_id: u128,
        email: [message.email_max]u8,
        email_len: u8,
        occupied: bool,
    };

    const empty_product = ProductEntry{ .product = undefined, .occupied = false };
    const empty_collection = CollectionEntry{ .collection = undefined, .occupied = false };
    const empty_membership = MembershipEntry{ .collection_id = 0, .product_id = 0, .occupied = false, .removed = false };
    const empty_order = OrderEntry{ .order = undefined, .occupied = false };
    const empty_login_code = LoginCodeEntry{ .email = undefined, .code = undefined, .email_len = 0, .occupied = 0, .expires_at = 0 };
    const empty_user = UserEntry{ .user_id = 0, .email = undefined, .email_len = 0, .occupied = false };

    products: *[product_capacity]ProductEntry,
    product_count: u32,
    collections_store: *[collection_capacity]CollectionEntry,
    collection_count: u32,
    memberships: *[membership_capacity]MembershipEntry,
    orders: *[order_capacity]OrderEntry,
    order_count: u32,
    login_codes: [login_code_capacity]LoginCodeEntry,
    users: [user_capacity]UserEntry,

    // --- Fault injection ---
    //
    // PRNG-driven, same pattern as TigerBeetle's SimIO. The sim configures
    // non-zero probabilities; production (SqliteStorage) doesn't have these
    // fields at all. Faults fire on reads only — writes are infallible
    // (TigerBeetle convention: if the machine is dying, crash, don't degrade).
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
            .login_codes = [_]LoginCodeEntry{empty_login_code} ** login_code_capacity,
            .users = [_]UserEntry{empty_user} ** user_capacity,
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
        self.login_codes = [_]LoginCodeEntry{empty_login_code} ** login_code_capacity;
        self.users = [_]UserEntry{empty_user} ** user_capacity;
    }

    pub fn begin(_: *MemoryStorage) void {}
    pub fn commit(_: *MemoryStorage) void {}

    // --- Product operations ---

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

    pub fn search(self: *MemoryStorage, out: *[message.list_max]message.Product, out_len: *u32, query: message.SearchQuery) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            if (!entry.product.flags.active) continue;
            if (query.matches(&entry.product)) {
                insert_sorted(message.Product, out, out_len, entry.product);
            }
        }
        return .ok;
    }

    fn match_product_filters(product: *const message.Product, params: message.ListParams) bool {
        switch (params.active_filter) {
            .any => {},
            .active_only => if (!product.flags.active) return false,
            .inactive_only => if (product.flags.active) return false,
        }
        if (params.price_min > 0 and product.price_cents < params.price_min) return false;
        if (params.price_max > 0 and product.price_cents > params.price_max) return false;
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

    pub fn update_collection(self: *MemoryStorage, id: u128, col: *const message.ProductCollection) StorageResult {
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == id) {
                entry.collection = col.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_collections(self: *MemoryStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32, cursor: u128) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.collections_store) |*entry| {
            if (!entry.occupied) continue;
            if (!entry.collection.flags.active) continue;
            if (entry.collection.id <= cursor) continue;
            insert_sorted(message.ProductCollection, out, out_len, entry.collection);
        }
        return .ok;
    }

    // --- Membership operations ---

    pub fn add_to_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == collection_id and m.product_id == product_id) {
                m.removed = false;
                return .ok;
            }
        }
        for (self.memberships) |*m| {
            if (!m.occupied) {
                m.* = .{ .collection_id = collection_id, .product_id = product_id, .occupied = true, .removed = false };
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn remove_from_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        for (self.memberships) |*m| {
            if (m.occupied and !m.removed and m.collection_id == collection_id and m.product_id == product_id) {
                m.removed = true;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_products_in_collection(self: *MemoryStorage, collection_id: u128, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.memberships) |*m| {
            if (!m.occupied or m.removed or m.collection_id != collection_id) continue;
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

    pub fn update_order_completion(self: *MemoryStorage, order: *const message.OrderResult) StorageResult {
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == order.id) {
                entry.order.status = order.status;
                entry.order.payment_ref = order.payment_ref;
                entry.order.payment_ref_len = order.payment_ref_len;
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
            summary.status = entry.order.status;
            summary.timeout_at = entry.order.timeout_at;
            summary.payment_ref = entry.order.payment_ref;
            summary.payment_ref_len = entry.order.payment_ref_len;
            insert_sorted(message.OrderSummary, out, out_len, summary);
        }
        return .ok;
    }

    // --- Login code operations ---

    pub fn get_login_code(self: *MemoryStorage, email: []const u8, out: *LoginCodeEntry) StorageResult {
        if (self.fault()) |f| return f;
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                out.* = entry.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_login_code(self: *MemoryStorage, email: []const u8, code: *const [message.code_length]u8, expires_at: i64) StorageResult {
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                entry.code = code.*;
                entry.expires_at = expires_at;
                return .ok;
            }
        }
        for (&self.login_codes) |*entry| {
            if (entry.occupied == 0) {
                entry.occupied = 1;
                entry.email_len = @intCast(email.len);
                @memset(&entry.email, 0);
                @memcpy(entry.email[0..email.len], email);
                entry.code = code.*;
                entry.expires_at = expires_at;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn consume_login_code(self: *MemoryStorage, email: []const u8) StorageResult {
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                entry.expires_at = 0;
                return .ok;
            }
        }
        return .not_found;
    }

    // --- User operations ---

    pub fn get_user_by_email(self: *MemoryStorage, email: []const u8, out: *u128) StorageResult {
        if (self.fault()) |f| return f;
        for (&self.users) |*entry| {
            if (entry.occupied and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                out.* = entry.user_id;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_user(self: *MemoryStorage, user_id: u128, email: []const u8) StorageResult {
        for (&self.users) |*entry| {
            if (entry.occupied and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                return .err;
            }
        }
        for (&self.users) |*entry| {
            if (!entry.occupied) {
                entry.occupied = true;
                entry.user_id = user_id;
                entry.email_len = @intCast(email.len);
                @memset(&entry.email, 0);
                @memcpy(entry.email[0..email.len], email);
                return .ok;
            }
        }
        return .err; // full
    }

    // --- Fault injection ---
    //
    // Roll PRNG against configured probabilities. Returns a fault result
    // on hit, null on miss. Only called from read paths — writes don't
    // fault (if storage is dying, the framework crashes, it doesn't
    // return degraded results).

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

    // --- Sorted insertion ---
    //
    // Matches ORDER BY id LIMIT list_max semantics. Keeps the list_max
    // entities with the smallest IDs, in ascending order.

    fn insert_sorted(comptime T: type, out: *[message.list_max]T, out_len: *u32, item: T) void {
        var pos: u32 = 0;
        while (pos < out_len.*) : (pos += 1) {
            if (out[pos].id > item.id) break;
        }

        if (out_len.* < message.list_max) {
            var i: u32 = out_len.*;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
            out_len.* += 1;
        } else if (pos < message.list_max) {
            var i: u32 = message.list_max - 1;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
        }
    }
};
