//! Storage equivalence fuzzer — runs the same operation sequence against
//! MemoryStorage and SqliteStorage, asserts they produce identical results.
//!
//! MemoryStorage is the reference model (simple, obviously correct).
//! SqliteStorage is the system under test (production backend).
//! Any disagreement is a real semantic bug.
//!
//! No fault injection on either backend — faults cause intentional divergence,
//! and the point here is to find unintentional divergence.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const MemoryStorage = state_machine.MemoryStorage;
const SqliteStorage = @import("storage.zig").SqliteStorage;
const Auditor = @import("auditor.zig").Auditor;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzArgs = fuzz_lib.FuzzArgs;
const PRNG = @import("prng.zig");
const gen = @import("fuzz.zig");

const log = std.log.scoped(.fuzz);

const MemSM = state_machine.StateMachineType(MemoryStorage);
const SqlSM = state_machine.StateMachineType(SqliteStorage);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 50_000;
    var prng = PRNG.from_seed(seed);

    // Reference model: in-memory storage, no faults.
    var mem_storage = try MemoryStorage.init(std.heap.page_allocator);
    defer mem_storage.deinit(std.heap.page_allocator);

    // System under test: SQLite in-memory mode, no faults.
    var sql_storage = try SqliteStorage.init(":memory:");
    defer sql_storage.deinit();

    var mem_sm = MemSM.init(&mem_storage, false);
    var sql_sm = SqlSM.init(&sql_storage, false);

    // Auditor: third independent reference model — pure-logic state
    // tracking. Validates both backends against predicted results.
    var auditor = try Auditor.init(allocator);
    defer auditor.deinit(allocator);

    const op_weights = fuzz_lib.random_enum_weights(&prng, message.Operation);

    var coverage = gen.OperationCoverage{};

    for (0..events_max) |event_i| {
        const operation = prng.enum_weighted(message.Operation, op_weights);

        log.debug("Running fuzz_ops[{}/{}] == {s}", .{ event_i, events_max, @tagName(operation) });

        const msg = gen.gen_message(&prng, operation, auditor.id_pools()) orelse continue;

        if (!MemSM.input_valid(msg)) continue;

        // Both backends must accept prefetch — no faults configured.
        if (!mem_sm.prefetch(msg)) @panic("mem prefetch returned busy with no faults");
        if (!sql_sm.prefetch(msg)) @panic("sql prefetch returned busy with no faults");

        const mem_resp = mem_sm.commit(msg);
        const sql_resp = sql_sm.commit(msg);

        // Three-way validation:
        // 1. Both backends agree (storage equivalence).
        assert_response_equal(mem_resp, sql_resp, event_i, operation);
        // 2. Response matches independent model (logic correctness).
        auditor.on_commit(msg, mem_resp);
        coverage.record(operation);
    }

    coverage.assert_full_coverage(op_weights);
    log.info("storage equivalence: {} events, all agreed", .{events_max});
}

// =====================================================================
// Response comparison
// =====================================================================

fn assert_response_equal(
    mem: message.MessageResponse,
    sql: message.MessageResponse,
    event_i: usize,
    operation: message.Operation,
) void {
    if (mem.status != sql.status) {
        std.debug.panic(
            "status mismatch at event {} op={s}: mem={s} sql={s}",
            .{ event_i, @tagName(operation), @tagName(mem.status), @tagName(sql.status) },
        );
    }

    const mem_tag = std.meta.activeTag(mem.result);
    const sql_tag = std.meta.activeTag(sql.result);
    if (mem_tag != sql_tag) {
        std.debug.panic(
            "result tag mismatch at event {} op={s}: mem={s} sql={s}",
            .{ event_i, @tagName(operation), @tagName(mem_tag), @tagName(sql_tag) },
        );
    }

    switch (mem.result) {
        .empty => {},
        .product => |mp| assert_bytes_equal(message.Product, &mp, &sql.result.product, event_i),
        .product_list => |ml| assert_product_list_equal(&ml, &sql.result.product_list, event_i, operation),
        .inventory => |mi| {
            if (mi != sql.result.inventory) {
                std.debug.panic("inventory mismatch at event {}: mem={} sql={}", .{ event_i, mi, sql.result.inventory });
            }
        },
        .collection => |mc| {
            assert_bytes_equal(message.ProductCollection, &mc.collection, &sql.result.collection.collection, event_i);
            assert_product_list_equal(&mc.products, &sql.result.collection.products, event_i, operation);
        },
        .collection_list => |ml| assert_collection_list_equal(&ml, &sql.result.collection_list, event_i, operation),
        .order => |mo| assert_order_equal(&mo, &sql.result.order, event_i, operation),
        .order_list => |ml| assert_order_list_equal(&ml, &sql.result.order_list, event_i, operation),
    }
}

/// Byte-wise struct equality using stdx.equal_bytes — comptime-verified
/// no padding, no pointers, unique representation. Matches TigerBeetle's
/// equal_bytes pattern.
fn assert_bytes_equal(comptime T: type, a: *const T, b: *const T, event_i: usize) void {
    if (!stdx.equal_bytes(T, a, b)) {
        std.debug.panic("{s} data mismatch at event {}", .{ @typeName(T), event_i });
    }
}

fn assert_list_equal(comptime T: type, a_items: []const T, b_items: []const T, event_i: usize, operation: message.Operation) void {
    if (a_items.len != b_items.len) {
        std.debug.panic("{s} list len mismatch at event {} op={s}: mem={} sql={}", .{ @typeName(T), event_i, @tagName(operation), a_items.len, b_items.len });
    }
    for (a_items, b_items) |*ai, *bi| {
        assert_bytes_equal(T, ai, bi, event_i);
    }
}

fn assert_product_list_equal(a: *const message.ProductList, b: *const message.ProductList, event_i: usize, operation: message.Operation) void {
    assert_list_equal(message.Product, a.items[0..a.len], b.items[0..b.len], event_i, operation);
}

fn assert_collection_list_equal(a: *const message.CollectionList, b: *const message.CollectionList, event_i: usize, operation: message.Operation) void {
    assert_list_equal(message.ProductCollection, a.items[0..a.len], b.items[0..b.len], event_i, operation);
}

fn assert_order_equal(a: *const message.OrderResult, b: *const message.OrderResult, event_i: usize, operation: message.Operation) void {
    if (a.items_len != b.items_len) {
        std.debug.panic("order items_len mismatch at event {}: mem={} sql={}", .{ event_i, a.items_len, b.items_len });
    }
    assert_list_equal(message.OrderResultItem, a.items[0..a.items_len], b.items[0..b.items_len], event_i, operation);
    if (a.id != b.id) std.debug.panic("order id mismatch at event {}", .{event_i});
    if (a.total_cents != b.total_cents) std.debug.panic("order total_cents mismatch at event {}: mem={} sql={}", .{ event_i, a.total_cents, b.total_cents });
}

fn assert_order_list_equal(a: *const message.OrderSummaryList, b: *const message.OrderSummaryList, event_i: usize, operation: message.Operation) void {
    assert_list_equal(message.OrderSummary, a.items[0..a.len], b.items[0..b.len], event_i, operation);
}
