//! State machine benchmark — measures prefetch/commit throughput per operation.
//!
//! Runs against MemoryStorage with no fault injection, so measurements reflect
//! pure decision logic cost. Use as a regression detector: if the numbers move,
//! your code changed — not your environment.
//!
//! Smoke mode: `zig build unit-test` (small inputs, silent, prevents bitrot)
//! Benchmark mode: `zig build bench` (large inputs, prints results)

const std = @import("std");
const assert = std.debug.assert;
const Bench = @import("bench.zig");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const auth = @import("auth.zig");
const MemoryStorage = state_machine.MemoryStorage;
const StateMachine = state_machine.StateMachineType(MemoryStorage);
const fuzz = @import("fuzz.zig");
const PRNG = @import("prng.zig");

const bench_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

const repetitions = 32;

test "benchmark: state machine" {
    var bench: Bench = .init();
    defer bench.deinit();

    const entity_count: u32 = @intCast(bench.parameter("entity_count", 10, 1_000));
    const ops: u32 = @intCast(bench.parameter("ops", 50, 5_000));

    var prng = PRNG.from_seed(bench.seed);

    var storage = try MemoryStorage.init(std.heap.page_allocator);
    defer storage.deinit(std.heap.page_allocator);
    var sm = StateMachine.init(&storage, false, 0, bench_test_key);

    // --- Seed phase (untimed) ---

    const id_pool_cap = 2048;
    var product_ids_buf: [id_pool_cap]u128 = undefined;
    var product_count: u32 = 0;

    for (0..entity_count * 2) |_| {
        if (product_count >= entity_count) break;
        const p = fuzz.gen_product(&prng);
        const msg = message.Message.init(.create_product, 0, 1, p);
        if (!StateMachine.input_valid(msg)) continue;
        assert(sm.prefetch(msg));
        const resp = sm.commit(msg);
        if (resp.status == .ok) {
            product_ids_buf[product_count] = p.id;
            product_count += 1;
        }
    }
    assert(product_count > 0);
    const product_ids = product_ids_buf[0..product_count];

    bench.report("seeded {} products", .{product_count});

    // Checksum accumulator — prevents the compiler from optimizing away work.
    var checksum: u64 = 0;

    // --- get_product ---
    {
        var durations: [repetitions]u64 = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |i| {
                const msg = message.Message.init(.get_product, product_ids[i % product_count], 1, {});
                assert(sm.prefetch(msg));
                const resp = sm.commit(msg);
                checksum +%= @intFromEnum(resp.status);
            }
            dur.* = bench.stop();
            dur.* /= ops;
        }
        bench.report("get_product:    {}/op", .{std.fmt.fmtDuration(bench.estimate(&durations))});
    }

    // --- list_products ---
    {
        const params = std.mem.zeroes(message.ListParams);
        var durations: [repetitions]u64 = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |_| {
                const msg = message.Message.init(.list_products, 0, 1, params);
                assert(sm.prefetch(msg));
                const resp = sm.commit(msg);
                checksum +%= @intFromEnum(resp.status);
            }
            dur.* = bench.stop();
            dur.* /= ops;
        }
        bench.report("list_products:  {}/op", .{std.fmt.fmtDuration(bench.estimate(&durations))});
    }

    // --- update_product ---
    // Uses version=0 to bypass optimistic concurrency check, so the same
    // message succeeds on every repetition.
    {
        var update_payload = fuzz.gen_product(&prng);
        update_payload.version = 0;

        var durations: [repetitions]u64 = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |i| {
                update_payload.id = product_ids[i % product_count];
                const msg = message.Message.init(.update_product, update_payload.id, 1, update_payload);
                assert(sm.prefetch(msg));
                const resp = sm.commit(msg);
                checksum +%= @intFromEnum(resp.status);
            }
            dur.* = bench.stop();
            dur.* /= ops;
        }
        bench.report("update_product: {}/op", .{std.fmt.fmtDuration(bench.estimate(&durations))});
    }

    bench.report("checksum: {}", .{checksum});
}
