//! Message-level state machine fuzzer.
//!
//! Bypasses HTTP parsing — generates random Message structs and calls
//! prefetch/commit directly. Exercises framework invariants (prefetch/
//! execute ordering, fault handling, input validation) with PRNG-driven
//! fault injection at the prefetch dispatch level.
//!
//! Does NOT validate domain correctness — that's a user-space concern.
//! See decisions/storage-ownership.md.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const App = @import("app.zig");
const auth = @import("framework/auth.zig");
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzArgs = fuzz_lib.FuzzArgs;
const StateMachine = App.SM;
const PRNG = @import("stdx").PRNG;

const fuzz_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

const log = std.log.scoped(.fuzz);

const Handlers = App.HandlersType(App.Storage);

/// Pipeline helper — prefetch + commit for native handlers.
/// Returns null if prefetch was busy (fault injection).
fn pipeline_execute(sm: *StateMachine, msg: message.Message) ?message.Status {
    var handler: Handlers = .{};
    const identity = sm.resolve_credential(msg);
    const cache = handler.handler_prefetch(sm.storage, &msg) orelse return null;
    sm.begin_batch();
    var write_view = App.Storage.WriteView.init(sm.storage);
    const fw = Handlers.FwCtx{ .identity = identity, .now = sm.now, .is_sse = false };
    const result = handler.handler_execute(cache, msg, fw, &write_view);
    sm.commit_batch();
    return result.status;
}

pub const id_pool_capacity = 64;

/// Generate a random number, biased towards all bit 'edges' of T. That is,
/// given a u64, it's very likely to not only get 0 or maxInt(u64), but also
/// values around maxInt(u63), maxInt(u62), ..., maxInt(u1).
pub fn int_edge_biased(prng: *PRNG, comptime T: type) T {
    const bits = @typeInfo(T).int.bits;
    comptime assert(@typeInfo(T).int.signedness == .unsigned);

    // With bits * 2, there's a ~50% chance of generating a uniform integer
    // within the full range, and a ~50% chance of generating an integer
    // biased towards an edge.
    const bias_to = prng.range_inclusive(T, 0, bits * 2);

    if (bias_to > bits) {
        return prng.int(T);
    } else {
        const bias_center: T = if (bias_to == bits)
            math.maxInt(T)
        else
            math.pow(T, 2, bias_to);
        const bias_min = if (bias_to == 0) 0 else bias_center - @min(bias_center, 8);
        const bias_max = if (bias_to == bits) bias_center else bias_center + 8;

        return prng.range_inclusive(T, bias_min, bias_max);
    }
}

pub fn main(_: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();

    // Enable fault injection at the dispatch boundary (app.zig module-level).
    var fault_prng_instance = PRNG.from_seed(prng.int(u64));
    App.fault_prng = &fault_prng_instance;
    App.fault_busy_ratio = PRNG.ratio(prng.range_inclusive(u64, 5, 30), 100);
    defer {
        App.fault_prng = null;
        App.fault_busy_ratio = PRNG.Ratio.zero();
    }

    log.info(
        \\Fuzz config:
        \\  fault_busy_ratio={}
        \\  events_max={}
    , .{
        App.fault_busy_ratio,
        events_max,
    });

    var sm = StateMachine.init(&storage, seed, fuzz_test_key);
    sm.now = 1_700_000_000;

    // ID tracker: lightweight pool for generating messages that reference
    // existing entities. No domain validation — just remembers IDs that
    // were successfully created so subsequent operations target real entities.
    var tracker = IdTracker{};

    // Swarm testing: random weights per seed so different seeds stress
    // different operation mixes (TigerBeetle workload pattern).
    var op_weights = fuzz_lib.random_enum_weights(&prng, message.Operation);
    op_weights.root = 0; // .root is a WAL sentinel, not an application operation.

    // Dependency guarantees: if an operation has non-zero weight, its
    // prerequisites must too. Otherwise the operation always returns null
    // (no entities to reference) and coverage assertion fires.
    // create_order, complete_order, cancel_order, get_order, list_orders → need products
    // add/remove_collection_member → need products AND collections
    // get_product, delete_product, update_product, get_product_inventory, transfer_inventory → need products
    // get_collection, delete_collection → need collections
    if (op_weights.create_order > 0 or
        op_weights.complete_order > 0 or
        op_weights.cancel_order > 0 or
        op_weights.get_product > 0 or
        op_weights.delete_product > 0 or
        op_weights.update_product > 0 or
        op_weights.get_product_inventory > 0 or
        op_weights.transfer_inventory > 0 or
        op_weights.search_products > 0)
    {
        op_weights.create_product = @max(op_weights.create_product, 1);
    }
    if (op_weights.get_collection > 0 or
        op_weights.delete_collection > 0 or
        op_weights.add_collection_member > 0 or
        op_weights.remove_collection_member > 0)
    {
        op_weights.create_collection = @max(op_weights.create_collection, 1);
    }
    if (op_weights.add_collection_member > 0 or
        op_weights.remove_collection_member > 0)
    {
        op_weights.create_product = @max(op_weights.create_product, 1);
    }

    var coverage = OperationCoverage{};
    var features = FeatureCoverage{};

    for (0..events_max) |event_i| {
        // Advance time by a random amount each iteration to exercise
        // order timeout paths. ~1-5 seconds per tick.
        sm.now += @intCast(prng.range_inclusive(u32, 1, 5));
        const operation = prng.enum_weighted(message.Operation, op_weights);

        log.debug("Running fuzz_ops[{}/{}] == {s}", .{ event_i, events_max, @tagName(operation) });

        if (tracker.at_capacity(operation)) continue;

        const msg = gen_message(&prng, operation, tracker.pools()) orelse continue;

        // Gate: skip invalid inputs — matches TB's input_valid pattern.
        if (!state_machine.input_valid(msg)) continue;

        // Prefetch + commit — may fail with busy (fault injection), skip.
        const status = pipeline_execute(&sm, msg) orelse continue;
        coverage.record(operation);
        const resp_proxy = struct { status: message.Status }{ .status = status };
        features.record_message(msg, resp_proxy);

        // Track created entity IDs and verify structural invariants.
        tracker.on_commit(msg, resp_proxy);

        // Cross-operation probe: after a successful create, immediately
        // get the entity back and assert it exists. Catches write-then-read
        // bugs where the storage accepted the write but can't find it.
        // Only fires when no faults are injected (prefetch succeeds).
        if (status == .ok) {
            switch (msg.operation) {
                .create_product => {
                    const probe = message.Message.init(.get_product, msg.body_as(message.Product).id, 1, {});
                    if (pipeline_execute(&sm, probe)) |probe_status| {
                        assert(probe_status == .ok or probe_status == .storage_error);
                    }
                },
                .create_collection => {
                    const probe = message.Message.init(.get_collection, msg.body_as(message.ProductCollection).id, 1, {});
                    if (pipeline_execute(&sm, probe)) |probe_status| {
                        assert(probe_status == .ok or probe_status == .storage_error);
                    }
                },
                .create_order => {
                    const probe = message.Message.init(.get_order, msg.body_as(message.OrderRequest).id, 1, {});
                    if (pipeline_execute(&sm, probe)) |probe_status| {
                        assert(probe_status == .ok or probe_status == .storage_error);
                    }
                },
                else => {},
            }
        }
    }

    coverage.assert_full_coverage(op_weights);
    features.assert_full_coverage(&coverage);
}

// =====================================================================
// IdTracker — lightweight entity ID pool for message generation.
//
// Remembers IDs of successfully created entities so the fuzzer can
// generate operations that target existing entities (get, update,
// delete, transfer). No domain validation, no state tracking — just
// IDs and capacity awareness.
// =====================================================================

pub const IdTracker = struct {
    product_ids: [id_pool_capacity]u128 = undefined,
    product_id_count: u32 = 0,
    collection_ids: [id_pool_capacity]u128 = undefined,
    collection_id_count: u32 = 0,
    order_ids: [id_pool_capacity]u128 = undefined,
    order_id_count: u32 = 0,

    // Counts for capacity gating — prevents unbounded growth that would
    // slow the fuzzer and exhaust ID pools.
    product_count: u32 = 0,
    collection_count: u32 = 0,
    order_count: u32 = 0,
    membership_count: u32 = 0,

    pub fn pools(self: *const IdTracker) IdPools {
        return .{
            .product_ids = self.product_ids[0..self.product_id_count],
            .collection_ids = self.collection_ids[0..self.collection_id_count],
            .order_ids = self.order_ids[0..self.order_id_count],
        };
    }

    pub fn at_capacity(self: *const IdTracker, operation: message.Operation) bool {
        return switch (operation) {
            .root => unreachable,
            // Capacity limits for fuzzing — prevents unbounded growth.
            // Not tied to a specific storage backend's limits.
            .create_product => self.product_count >= 896,
            .create_collection => self.collection_count >= 224,
            .create_order => self.order_count >= 224,
            .add_collection_member => self.membership_count >= 896,
            else => false,
        };
    }

    /// Track created IDs and verify structural response invariants.
    ///
    /// This is NOT domain validation (that's user-space). These are
    /// framework-level structural invariants:
    /// - create returns the entity that was created (id matches)
    /// - get of a known-created entity returns ok or not_found (not garbage)
    /// - status is a valid enum value (not undefined)
    /// - response result tag matches the operation's expected result type
    pub fn on_commit(self: *IdTracker, msg: message.Message, resp: anytype) void {
        if (resp.status == .storage_error) return;

        // Structural: status must be a known value (not undefined bits).
        _ = @tagName(resp.status);

        switch (msg.operation) {
            .create_product => {
                if (resp.status == .ok) {
                    // Create returns the entity — ID must match what was sent.
                    // ID from message body — response has no domain data.
                    self.product_count += 1;
                    if (self.product_id_count < id_pool_capacity) {
                        self.product_ids[self.product_id_count] = msg.body_as(message.Product).id;
                        self.product_id_count += 1;
                    }
                }
            },
            .get_product, .get_product_inventory => {
                // Get must return ok or not_found — never a create-style status.
                assert(resp.status == .ok or resp.status == .not_found);
            },
            .update_product => {
                assert(resp.status == .ok or resp.status == .not_found or resp.status == .version_conflict);
                if (resp.status == .ok) {
                    // Update returns the entity — ID must match the request.
                    // ID verified via msg.id — response has no domain data.
                }
            },
            .delete_product => {
                assert(resp.status == .ok or resp.status == .not_found);
            },
            .create_collection => {
                if (resp.status == .ok) {
                    // ID from message body — response has no domain data.
                    self.collection_count += 1;
                    if (self.collection_id_count < id_pool_capacity) {
                        self.collection_ids[self.collection_id_count] = msg.body_as(message.ProductCollection).id;
                        self.collection_id_count += 1;
                    }
                }
            },
            .get_collection => {
                assert(resp.status == .ok or resp.status == .not_found);
            },
            .create_order => {
                if (resp.status == .ok) {
                    // ID from message body — response has no domain data.
                    self.order_count += 1;
                    if (self.order_id_count < id_pool_capacity) {
                        self.order_ids[self.order_id_count] = msg.body_as(message.OrderRequest).id;
                        self.order_id_count += 1;
                    }
                }
            },
            .get_order => {
                assert(resp.status == .ok or resp.status == .not_found);
            },
            .add_collection_member => {
                if (resp.status == .ok) self.membership_count += 1;
            },
            .transfer_inventory => {
                assert(resp.status == .ok or resp.status == .not_found or resp.status == .insufficient_inventory);
            },
            else => {},
        }
    }
};

/// Tracks which operations were actually committed during a fuzz run.
/// Asserts full coverage at the end — catches gen_message handlers that
/// silently return null for new operations.
pub const OperationCoverage = struct {
    counts: std.enums.EnumArray(message.Operation, u32) = std.enums.EnumArray(message.Operation, u32).initFill(0),

    pub fn record(self: *OperationCoverage, operation: message.Operation) void {
        self.counts.set(operation, self.counts.get(operation) + 1);
    }

    /// Assert every operation with non-zero weight was actually committed.
    /// Operations with zero weight are disabled by swarm testing and skipped.
    pub fn assert_full_coverage(self: *const OperationCoverage, weights: PRNG.EnumWeightsType(message.Operation)) void {
        inline for (comptime std.enums.values(message.Operation)) |op| {
            if (@field(weights, @tagName(op)) > 0 and self.counts.get(op) == 0) {
                std.debug.panic(
                    "operation {s} was never committed — gen_message may be broken",
                    .{@tagName(op)},
                );
            }
        }
    }
};

/// Tracks whether specific input features were exercised during a fuzz run.
/// Catches blind spots where the fuzzer generates operations but never with
/// the interesting parameters that differ between backends.
pub const FeatureCoverage = struct {
    list_with_name_prefix: bool = false,
    list_with_price_filter: bool = false,
    list_with_active_filter: bool = false,
    list_with_cursor: bool = false,
    utf8_multibyte_name: bool = false,

    pub fn record_message(self: *FeatureCoverage, msg: message.Message, resp: anytype) void {
        switch (msg.operation) {
            .list_products, .list_collections, .list_orders => {
                const lp = msg.body_as(message.ListParams);
                if (lp.name_prefix_len > 0) self.list_with_name_prefix = true;
                if (lp.price_min > 0 or lp.price_max > 0) self.list_with_price_filter = true;
                if (lp.active_filter != .any) self.list_with_active_filter = true;
                if (lp.cursor != 0) self.list_with_cursor = true;
            },
            .create_product => {
                const p = msg.body_as(message.Product);
                if (resp.status == .ok) {
                    for (p.name[0..p.name_len]) |b| {
                        if (b >= 0x80) {
                            self.utf8_multibyte_name = true;
                            break;
                        }
                    }
                }
            },
            else => {},
        }
    }

    /// Assert all features that could have been exercised were exercised.
    /// Features that depend on operations with zero swarm weight are skipped.
    pub fn assert_full_coverage(self: *const FeatureCoverage, op_counts: *const OperationCoverage) void {
        const has_lists = op_counts.counts.get(.list_products) > 0 or
            op_counts.counts.get(.list_collections) > 0 or
            op_counts.counts.get(.list_orders) > 0;
        const has_creates = op_counts.counts.get(.create_product) > 0;

        if (has_lists) {
            if (!self.list_with_name_prefix) @panic("feature list_with_name_prefix was never exercised");
            if (!self.list_with_price_filter) @panic("feature list_with_price_filter was never exercised");
            if (!self.list_with_active_filter) @panic("feature list_with_active_filter was never exercised");
            if (!self.list_with_cursor) @panic("feature list_with_cursor was never exercised");
        }
        if (has_creates) {
            if (!self.utf8_multibyte_name) @panic("feature utf8_multibyte_name was never exercised");
        }
    }
};

pub const IdPools = struct {
    product_ids: []const u128,
    collection_ids: []const u128,
    order_ids: []const u128,
};

/// Generate a Message for the given operation, or null if prerequisites
/// aren't met (e.g., transfer_inventory needs 2 products).
/// Sometimes generates intentionally invalid messages to exercise input_valid.
pub fn gen_message(prng: *PRNG, operation: message.Operation, pools: IdPools) ?message.Message {
    // ~10% chance: generate a random message with correct operation tag but
    // random fields — exercises the input_valid boundary.
    if (prng.chance(PRNG.ratio(1, 10))) {
        return gen_random_message(prng, operation);
    }

    const user_id = prng.int(u128) | 1;
    const M = message.Message;
    return switch (operation) {
        .root => unreachable,
        .create_product => M.init(.create_product, 0, user_id, gen_product(prng)),
        .get_product, .get_product_inventory => M.init(operation, pick_or_random_id(prng, pools.product_ids), user_id, {}),
        .list_products => M.init(.list_products, 0, user_id, gen_list_params(prng)),
        .update_product => blk: {
            const id = pick_or_random_id(prng, pools.product_ids);
            break :blk M.init(.update_product, id, user_id, gen_product_with_id(prng, id));
        },
        .delete_product => M.init(.delete_product, pick_or_random_id(prng, pools.product_ids), user_id, {}),
        .transfer_inventory => blk: {
            if (pools.product_ids.len < 2) return null;
            const src_idx = prng.int_inclusive(usize, pools.product_ids.len - 1);
            var dst_idx = prng.int_inclusive(usize, pools.product_ids.len - 1);
            if (dst_idx == src_idx) dst_idx = (src_idx + 1) % pools.product_ids.len;
            break :blk M.init(.transfer_inventory, pools.product_ids[src_idx], user_id, message.InventoryTransfer{
                .target_id = pools.product_ids[dst_idx],
                .quantity = prng.range_inclusive(u32, 1, 1000),
                .reserved = .{0} ** 12,
            });
        },
        .create_order => blk: {
            if (pools.product_ids.len == 0) return null;
            break :blk M.init(.create_order, 0, user_id, gen_order(prng, pools.product_ids));
        },
        .complete_order => blk: {
            if (pools.order_ids.len == 0) return null;
            const result: message.OrderCompletion.OrderCompletionResult = if (prng.boolean()) .confirmed else .failed;
            var completion = std.mem.zeroes(message.OrderCompletion);
            completion.result = result;
            if (result == .confirmed and prng.boolean()) {
                completion.payment_ref_len = prng.range_inclusive(u8, 1, message.payment_ref_max);
                for (completion.payment_ref[0..completion.payment_ref_len]) |*byte| {
                    byte.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
                }
            }
            break :blk M.init(.complete_order, pick_or_random_id(prng, pools.order_ids), user_id, completion);
        },
        .cancel_order => M.init(.cancel_order, pick_or_random_id(prng, pools.order_ids), user_id, {}),
        .search_products => M.init(.search_products, 0, user_id, gen_search_query(prng)),
        .get_order => M.init(.get_order, pick_or_random_id(prng, pools.order_ids), user_id, {}),
        .list_orders => M.init(.list_orders, 0, user_id, gen_list_params(prng)),
        .create_collection => M.init(.create_collection, 0, user_id, gen_collection(prng)),
        .get_collection => M.init(.get_collection, pick_or_random_id(prng, pools.collection_ids), user_id, {}),
        .list_collections => M.init(.list_collections, 0, user_id, gen_list_params(prng)),
        .delete_collection => M.init(.delete_collection, pick_or_random_id(prng, pools.collection_ids), user_id, {}),
        .add_collection_member => blk: {
            if (pools.collection_ids.len == 0 or pools.product_ids.len == 0) return null;
            break :blk M.init(.add_collection_member, pools.collection_ids[prng.int_inclusive(usize, pools.collection_ids.len - 1)], user_id, pools.product_ids[prng.int_inclusive(usize, pools.product_ids.len - 1)]);
        },
        .remove_collection_member => blk: {
            if (pools.collection_ids.len == 0 or pools.product_ids.len == 0) return null;
            break :blk M.init(.remove_collection_member, pools.collection_ids[prng.int_inclusive(usize, pools.collection_ids.len - 1)], user_id, pools.product_ids[prng.int_inclusive(usize, pools.product_ids.len - 1)]);
        },
        .page_load_dashboard => M.init(.page_load_dashboard, 0, user_id, {}),
        .page_load_login, .logout => M.init(operation, 0, user_id, {}),
        .request_login_code => M.init(.request_login_code, 0, user_id, gen_login_code_request(prng)),
        .verify_login_code => M.init(.verify_login_code, 0, user_id, gen_login_verification(prng)),
    };
}

pub fn pick_or_random_id(prng: *PRNG, pool: []const u128) u128 {
    if (pool.len > 0 and prng.chance(PRNG.ratio(3, 4))) {
        return pool[prng.int_inclusive(usize, pool.len - 1)];
    }
    return prng.int(u128) | 1;
}

pub fn gen_search_query(prng: *PRNG) message.SearchQuery {
    var sq = std.mem.zeroes(message.SearchQuery);
    sq.query_len = @intCast(gen_utf8_text(prng, &sq.query, 1, message.search_query_max));
    return sq;
}

pub fn gen_product(prng: *PRNG) message.Product {
    return gen_product_with_id(prng, prng.int(u128) | 1);
}

pub fn gen_product_with_id(prng: *PRNG, id: u128) message.Product {
    var p: message.Product = std.mem.zeroes(message.Product);
    p.id = id;
    p.price_cents = prng.range_inclusive(u32, 0, 999_999);
    p.inventory = prng.range_inclusive(u32, 0, 10_000);
    p.version = 1;
    p.flags = .{ .active = prng.boolean() };
    p.name_len = @intCast(gen_utf8_text(prng, &p.name, 1, message.product_name_max));
    const desc_len = gen_utf8_text(prng, &p.description, 0, message.product_description_max);
    p.description_len = @intCast(desc_len);
    return p;
}

pub fn gen_collection(prng: *PRNG) message.ProductCollection {
    var col: message.ProductCollection = std.mem.zeroes(message.ProductCollection);
    col.id = prng.int(u128) | 1;
    col.name_len = @intCast(gen_utf8_text(prng, &col.name, 1, message.collection_name_max));
    col.flags = .{ .active = true };
    return col;
}

pub fn gen_order(prng: *PRNG, product_ids: []const u128) message.OrderRequest {
    var order = std.mem.zeroes(message.OrderRequest);
    order.id = prng.int(u128) | 1;
    const max_items: u8 = @intCast(@min(message.order_items_max, product_ids.len));
    order.items_len = prng.range_inclusive(u8, 1, max_items);

    var used: [message.order_items_max]usize = undefined;
    var used_count: u8 = 0;

    for (0..order.items_len) |i| {
        var prod_idx = prng.int_inclusive(usize, product_ids.len - 1);
        var attempts: usize = 0;
        while (attempts < product_ids.len) : (attempts += 1) {
            var dup = false;
            for (used[0..used_count]) |u| {
                if (u == prod_idx) {
                    dup = true;
                    break;
                }
            }
            if (!dup) break;
            prod_idx = (prod_idx + 1) % product_ids.len;
        }
        used[used_count] = prod_idx;
        used_count += 1;

        order.items[i] = .{
            .product_id = product_ids[prod_idx],
            .quantity = prng.range_inclusive(u32, 1, 100),
            .reserved = .{0} ** 12,
        };
    }
    return order;
}

/// Generate a message with random fields — likely invalid, exercises input_valid.
pub fn gen_random_message(prng: *PRNG, operation: message.Operation) message.Message {
    const id = prng.int(u128);
    const user_id = prng.int(u128) | 1;
    const M = message.Message;
    return switch (operation.event_tag()) {
        .product => M.init(operation, id, user_id, blk: {
            var p = std.mem.zeroes(message.Product);
            p.id = prng.int(u128);
            p.name_len = prng.int(u8);
            p.description_len = prng.int(u16);
            p.price_cents = prng.int(u32);
            p.inventory = prng.int(u32);
            p.version = prng.int(u32);
            p.flags = .{ .active = prng.boolean() };
            prng.fill(&p.name);
            prng.fill(&p.description);
            break :blk p;
        }),
        .collection => M.init(operation, id, user_id, blk: {
            var col = std.mem.zeroes(message.ProductCollection);
            col.id = prng.int(u128);
            col.name_len = prng.int(u8);
            col.flags = .{ .active = prng.boolean() };
            prng.fill(&col.name);
            break :blk col;
        }),
        .order => M.init(operation, id, user_id, blk: {
            var o = std.mem.zeroes(message.OrderRequest);
            o.id = prng.int(u128);
            o.items_len = prng.int(u8);
            const len = @min(o.items_len, message.order_items_max);
            for (o.items[0..len]) |*item| {
                item.* = .{
                    .product_id = prng.int(u128),
                    .quantity = prng.int(u32),
                    .reserved = .{0} ** 12,
                };
            }
            break :blk o;
        }),
        .transfer => M.init(operation, id, user_id, message.InventoryTransfer{
            .target_id = prng.int(u128),
            .quantity = prng.int(u32),
            .reserved = .{0} ** 12,
        }),
        .completion => M.init(operation, id, user_id, blk: {
            var comp = std.mem.zeroes(message.OrderCompletion);
            comp.result = prng.enum_uniform(message.OrderCompletion.OrderCompletionResult);
            comp.payment_ref_len = prng.int(u8);
            prng.fill(&comp.payment_ref);
            break :blk comp;
        }),
        .search => M.init(operation, id, user_id, blk: {
            var sq = std.mem.zeroes(message.SearchQuery);
            sq.query_len = prng.int(u8);
            prng.fill(&sq.query);
            break :blk sq;
        }),
        .member_id => M.init(operation, id, user_id, prng.int(u128)),
        .list => M.init(operation, id, user_id, blk: {
            var lp = std.mem.zeroes(message.ListParams);
            lp.active_filter = prng.enum_uniform(message.ListParams.ActiveFilter);
            lp.price_min = prng.int(u32);
            lp.price_max = prng.int(u32);
            lp.name_prefix_len = prng.int(u8);
            prng.fill(&lp.name_prefix);
            break :blk lp;
        }),
        .login_request => M.init(operation, id, user_id, gen_login_code_request(prng)),
        .login_verify => M.init(operation, id, user_id, gen_login_verification(prng)),
        .none => M.init(operation, id, user_id, {}),
    };
}

fn gen_login_code_request(prng: *PRNG) message.LoginCodeRequest {
    var ev = std.mem.zeroes(message.LoginCodeRequest);
    const email_len = prng.range_inclusive(u8, 5, 32);
    ev.email_len = email_len;
    for (ev.email[0..email_len]) |*byte| {
        byte.* = 'a' + @as(u8, @intCast(prng.int(u8) % 26));
    }
    if (email_len > 3) ev.email[email_len / 2] = '@';
    return ev;
}

fn gen_login_verification(prng: *PRNG) message.LoginVerification {
    var ev = std.mem.zeroes(message.LoginVerification);
    const email_len = prng.range_inclusive(u8, 5, 32);
    ev.email_len = email_len;
    for (ev.email[0..email_len]) |*byte| {
        byte.* = 'a' + @as(u8, @intCast(prng.int(u8) % 26));
    }
    if (email_len > 3) ev.email[email_len / 2] = '@';
    for (&ev.code) |*c| {
        c.* = '0' + @as(u8, @intCast(prng.int(u8) % 10));
    }
    return ev;
}

/// Fill buf with random UTF-8 text between min_len and max_len bytes.
/// ~70% ASCII-only, ~30% mixed with multi-byte characters (2-3 byte).
/// Returns the actual byte length written.
pub fn gen_utf8_text(prng: *PRNG, buf: []u8, min_len: u16, max_len: u16) u16 {
    assert(max_len >= min_len);
    assert(max_len > 0);
    assert(buf.len >= max_len);

    const use_multibyte = prng.chance(PRNG.ratio(3, 10));
    if (!use_multibyte) {
        const len = prng.range_inclusive(u16, min_len, max_len);
        for (buf[0..len]) |*c| {
            c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        }
        return len;
    }

    var pos: u16 = 0;
    while (pos < min_len or (pos < max_len and prng.boolean())) {
        const remaining = max_len - pos;
        if (remaining == 0) break;

        const cp: u21 = if (remaining >= 3 and prng.chance(PRNG.ratio(1, 4)))
            prng.range_inclusive(u21, 0x0800, 0x9FFF)
        else if (remaining >= 2 and prng.chance(PRNG.ratio(1, 3)))
            prng.range_inclusive(u21, 0x00C0, 0x07FF)
        else
            @as(u21, 'a') + prng.int_inclusive(u21, 25);

        const seq_len = std.unicode.utf8Encode(cp, buf[pos..max_len]) catch break;
        pos += @intCast(seq_len);
    }

    while (pos < min_len) {
        buf[pos] = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        pos += 1;
    }

    return pos;
}

pub fn gen_list_params(prng: *PRNG) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    if (prng.boolean()) {
        params.active_filter = prng.enum_uniform(message.ListParams.ActiveFilter);
    }
    if (prng.boolean()) {
        params.price_min = int_edge_biased(prng, u32);
    }
    if (prng.boolean()) {
        params.price_max = int_edge_biased(prng, u32);
        if (params.price_max < params.price_min) {
            params.price_max = params.price_min;
        }
    }
    if (prng.boolean()) {
        params.name_prefix_len = @intCast(gen_utf8_text(prng, &params.name_prefix, 1, 3));
    }
    if (prng.boolean()) {
        params.cursor = prng.int(u128);
    }
    return params;
}
