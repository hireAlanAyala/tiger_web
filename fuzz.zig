//! Message-level state machine fuzzer.
//!
//! Bypasses HTTP parsing — generates random Message structs and calls
//! prefetch/commit directly. Matches TigerBeetle's state_machine_fuzz.zig
//! pattern: library called by fuzz_tests.zig dispatcher.

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const MemoryStorage = state_machine.MemoryStorage;
const StateMachine = state_machine.StateMachineType(MemoryStorage);
const PRNG = @import("prng.zig");

const log = std.log.scoped(.fuzz);

const id_pool_capacity = 64;

/// Generate a random number, biased towards all bit 'edges' of T. That is,
/// given a u64, it's very likely to not only get 0 or maxInt(u64), but also
/// values around maxInt(u63), maxInt(u62), ..., maxInt(u1).
fn int_edge_biased(prng: *PRNG, comptime T: type) T {
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

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;

    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    var storage = try MemoryStorage.init(std.heap.page_allocator);
    defer storage.deinit(std.heap.page_allocator);

    // Enable fault injection.
    storage.prng = PRNG.from_seed(prng.int(u64));
    storage.busy_fault_probability = PRNG.ratio(prng.range_inclusive(u64, 5, 30), 100);
    storage.err_fault_probability = PRNG.ratio(prng.range_inclusive(u64, 1, 10), 100);

    log.info(
        \\Fuzz config:
        \\  busy_fault_probability={}
        \\  err_fault_probability={}
        \\  events_max={}
    , .{
        storage.busy_fault_probability,
        storage.err_fault_probability,
        events_max,
    });

    var sm = StateMachine.init(&storage, false);

    // Track known IDs for generating valid references.
    const id_pool_max = id_pool_capacity;
    var product_ids: [id_pool_max]u128 = undefined;
    var product_count: u32 = 0;
    var collection_ids: [id_pool_max]u128 = undefined;
    var collection_count: u32 = 0;
    var order_ids: [id_pool_max]u128 = undefined;
    var order_count: u32 = 0;
    var total_products_created: u32 = 0;
    var total_orders_created: u32 = 0;

    for (0..events_max) |event_i| {
        const operation = prng.enum_uniform(message.Operation);

        log.debug("Running fuzz_ops[{}/{}] == {s}", .{ event_i, events_max, @tagName(operation) });

        const msg = gen_message(&prng, operation, .{
            .product_ids = product_ids[0..product_count],
            .collection_ids = collection_ids[0..collection_count],
            .order_ids = order_ids[0..order_count],
            .total_products_created = total_products_created,
            .total_orders_created = total_orders_created,
        }) orelse continue;

        // Gate: skip invalid inputs — matches TB's input_valid pattern.
        if (!StateMachine.input_valid(msg)) continue;

        // Prefetch — may fail with busy, in which case we just skip.
        if (!sm.prefetch(msg)) continue;

        const resp = sm.commit(msg);

        // Track newly created entities.
        if (resp.status == .ok) {
            switch (operation) {
                .create_product => {
                    total_products_created += 1;
                    if (product_count < id_pool_max) {
                        product_ids[product_count] = msg.event.product.id;
                        product_count += 1;
                    }
                },
                .create_collection => {
                    if (collection_count < id_pool_max) {
                        collection_ids[collection_count] = msg.event.collection.id;
                        collection_count += 1;
                    }
                },
                .create_order => {
                    total_orders_created += 1;
                    if (order_count < id_pool_max) {
                        order_ids[order_count] = msg.event.order.id;
                        order_count += 1;
                    }
                },
                .delete_product => {
                    // Remove from pool.
                    for (product_ids[0..product_count], 0..) |pid, i| {
                        if (pid == msg.id) {
                            product_count -= 1;
                            product_ids[i] = product_ids[product_count];
                            break;
                        }
                    }
                },
                .delete_collection => {
                    for (collection_ids[0..collection_count], 0..) |cid, i| {
                        if (cid == msg.id) {
                            collection_count -= 1;
                            collection_ids[i] = collection_ids[collection_count];
                            break;
                        }
                    }
                },
                else => {},
            }
        }
    }
}

const IdPools = struct {
    product_ids: []const u128,
    collection_ids: []const u128,
    order_ids: []const u128,
    total_products_created: u32,
    total_orders_created: u32,
};

/// Generate a Message for the given operation, or null if prerequisites
/// aren't met (e.g., transfer_inventory needs 2 products).
/// Sometimes generates intentionally invalid messages to exercise input_valid.
fn gen_message(prng: *PRNG, operation: message.Operation, pools: IdPools) ?message.Message {
    // ~10% chance: generate a random message with correct operation tag but
    // random fields — exercises the input_valid boundary.
    if (prng.chance(PRNG.ratio(1, 10))) {
        return gen_random_message(prng, operation);
    }

    return switch (operation) {
        .create_product => blk: {
            // Stay below MemoryStorage.product_capacity (1024) — soft
            // delete never frees slots, so track total created.
            if (pools.total_products_created >= 950) return null;
            break :blk .{
                .operation = .create_product,
                .id = 0,
                .event = .{ .product = gen_product(prng) },
            };
        },
        .get_product, .get_product_inventory => .{
            .operation = operation,
            .id = pick_or_random_id(prng, pools.product_ids),
            .event = .{ .none = {} },
        },
        .list_products => .{
            .operation = .list_products,
            .id = 0,
            .event = .{ .list = gen_list_params(prng) },
        },
        .update_product => blk: {
            const id = pick_or_random_id(prng, pools.product_ids);
            break :blk .{
                .operation = .update_product,
                .id = id,
                .event = .{ .product = gen_product_with_id(prng, id) },
            };
        },
        .delete_product => .{
            .operation = .delete_product,
            .id = pick_or_random_id(prng, pools.product_ids),
            .event = .{ .none = {} },
        },
        .transfer_inventory => blk: {
            if (pools.product_ids.len < 2) return null;
            const src_idx = prng.int_inclusive(usize, pools.product_ids.len - 1);
            var dst_idx = prng.int_inclusive(usize, pools.product_ids.len - 1);
            if (dst_idx == src_idx) dst_idx = (src_idx + 1) % pools.product_ids.len;
            break :blk .{
                .operation = .transfer_inventory,
                .id = pools.product_ids[src_idx],
                .event = .{ .transfer = .{
                    .target_id = pools.product_ids[dst_idx],
                    .quantity = prng.range_inclusive(u32, 1, 1000),
                } },
            };
        },
        .create_order => blk: {
            if (pools.product_ids.len == 0) return null;
            // Stay below MemoryStorage.order_capacity (256) to avoid
            // storage-full assert in execute_create_order.
            if (pools.total_orders_created >= 240) return null;
            break :blk .{
                .operation = .create_order,
                .id = 0,
                .event = .{ .order = gen_order(prng, pools.product_ids) },
            };
        },
        .get_order => .{
            .operation = .get_order,
            .id = pick_or_random_id(prng, pools.order_ids),
            .event = .{ .none = {} },
        },
        .list_orders => .{
            .operation = .list_orders,
            .id = 0,
            .event = .{ .list = gen_list_params(prng) },
        },
        .create_collection => blk: {
            if (pools.collection_ids.len >= 200) return null;
            break :blk .{
                .operation = .create_collection,
                .id = 0,
                .event = .{ .collection = gen_collection(prng) },
            };
        },
        .get_collection => .{
            .operation = .get_collection,
            .id = pick_or_random_id(prng, pools.collection_ids),
            .event = .{ .none = {} },
        },
        .list_collections => .{
            .operation = .list_collections,
            .id = 0,
            .event = .{ .list = gen_list_params(prng) },
        },
        .delete_collection => .{
            .operation = .delete_collection,
            .id = pick_or_random_id(prng, pools.collection_ids),
            .event = .{ .none = {} },
        },
        .add_collection_member => blk: {
            if (pools.collection_ids.len == 0 or pools.product_ids.len == 0) return null;
            break :blk .{
                .operation = .add_collection_member,
                .id = pools.collection_ids[prng.int_inclusive(usize, pools.collection_ids.len - 1)],
                .event = .{ .member_id = pools.product_ids[prng.int_inclusive(usize, pools.product_ids.len - 1)] },
            };
        },
        .remove_collection_member => blk: {
            if (pools.collection_ids.len == 0 or pools.product_ids.len == 0) return null;
            break :blk .{
                .operation = .remove_collection_member,
                .id = pools.collection_ids[prng.int_inclusive(usize, pools.collection_ids.len - 1)],
                .event = .{ .member_id = pools.product_ids[prng.int_inclusive(usize, pools.product_ids.len - 1)] },
            };
        },
    };
}

fn pick_or_random_id(prng: *PRNG, pool: []const u128) u128 {
    if (pool.len > 0 and prng.chance(PRNG.ratio(3, 4))) {
        return pool[prng.int_inclusive(usize, pool.len - 1)];
    }
    return prng.int(u128) | 1;
}

fn gen_product(prng: *PRNG) message.Product {
    return gen_product_with_id(prng, prng.int(u128) | 1);
}

fn gen_product_with_id(prng: *PRNG, id: u128) message.Product {
    var p: message.Product = .{
        .id = id,
        .name = undefined,
        .name_len = 0,
        .description = undefined,
        .description_len = 0,
        .price_cents = prng.range_inclusive(u32, 0, 999_999),
        .inventory = prng.range_inclusive(u32, 0, 10_000),
        .version = 1,
        .active = prng.boolean(),
    };
    // Name: 1..name_max random alpha chars.
    p.name_len = prng.range_inclusive(u8, 1, message.product_name_max);
    for (p.name[0..p.name_len]) |*c| {
        c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
    }
    // Description: 0..desc_max random alpha chars.
    p.description_len = prng.range_inclusive(u16, 0, message.product_description_max);
    for (p.description[0..p.description_len]) |*c| {
        c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
    }
    return p;
}

fn gen_collection(prng: *PRNG) message.ProductCollection {
    var c: message.ProductCollection = .{
        .id = prng.int(u128) | 1,
        .name = undefined,
        .name_len = 0,
    };
    c.name_len = prng.range_inclusive(u8, 1, message.collection_name_max);
    for (c.name[0..c.name_len]) |*ch| {
        ch.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
    }
    return c;
}

fn gen_order(prng: *PRNG, product_ids: []const u128) message.OrderRequest {
    var order: message.OrderRequest = .{
        .id = prng.int(u128) | 1,
        .items = undefined,
        .items_len = 0,
    };
    const max_items: u8 = @intCast(@min(message.order_items_max, product_ids.len));
    order.items_len = prng.range_inclusive(u8, 1, max_items);

    // Track used product indices to avoid duplicate product_ids.
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
        };
    }
    return order;
}

/// Generate a message with random fields — likely invalid, exercises input_valid.
fn gen_random_message(prng: *PRNG, operation: message.Operation) message.Message {
    // Use random scalars for each field rather than prng.fill on the whole
    // struct — avoids undefined behavior from invalid enum/bool bit patterns.
    const event: message.Event = switch (operation.event_tag()) {
        .product => .{ .product = .{
            .id = prng.int(u128),
            .name = undefined,
            .name_len = prng.int(u8),
            .description = undefined,
            .description_len = prng.int(u16),
            .price_cents = prng.int(u32),
            .inventory = prng.int(u32),
            .version = prng.int(u32),
            .active = prng.boolean(),
        } },
        .collection => .{ .collection = .{
            .id = prng.int(u128),
            .name = undefined,
            .name_len = prng.int(u8),
        } },
        .order => .{ .order = blk: {
            var o: message.OrderRequest = .{
                .id = prng.int(u128),
                .items = undefined,
                .items_len = prng.int(u8),
            };
            const len = @min(o.items_len, message.order_items_max);
            for (o.items[0..len]) |*item| {
                item.* = .{
                    .product_id = prng.int(u128),
                    .quantity = prng.int(u32),
                };
            }
            break :blk o;
        } },
        .transfer => .{ .transfer = .{
            .target_id = prng.int(u128),
            .quantity = prng.int(u32),
        } },
        .member_id => .{ .member_id = prng.int(u128) },
        .list => .{ .list = .{
            .active_filter = prng.enum_uniform(message.ListParams.ActiveFilter),
            .price_min = prng.int(u32),
            .price_max = prng.int(u32),
            .name_prefix_len = prng.int(u8),
        } },
        .none => .{ .none = {} },
    };
    return .{
        .operation = operation,
        .id = prng.int(u128),
        .event = event,
    };
}

fn gen_list_params(prng: *PRNG) message.ListParams {
    var params: message.ListParams = .{};
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
    return params;
}
