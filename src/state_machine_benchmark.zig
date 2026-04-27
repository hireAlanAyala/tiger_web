//! State machine benchmark — pipeline-tier: measures prefetch/commit
//! throughput per operation.
//!
//! Internal tool for framework developers. Detects regressions in core
//! state machine logic cost. Framework users testing end-to-end
//! throughput will use `tiger-web benchmark` (Phase D of the
//! benchmark-tracking plan).
//!
//! Bypasses HTTP, uses in-memory SQLite, single-threaded. Answers
//! "did the logic get slower?" not "how much can this server handle?"
//!
//! Smoke mode: `zig build unit-test` (small inputs, silent, prevents bitrot)
//! Benchmark mode: `zig build bench` (large inputs, prints results)
//!
//! **Budget:** `docs/internal/benchmark-budgets.md#state_machine_benchmarkzig`
//! holds the 3-run calibration. Phase F regenerates on `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const Duration = stdx.Duration;
const Bench = @import("framework/bench.zig");
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const App = @import("app.zig");
const auth = @import("framework/auth.zig");
const StateMachine = App.SM;
const fuzz = @import("fuzz.zig");
const PRNG = stdx.PRNG;

// Per-operation smoke-mode budgets. Calibrated 10×max(3 runs) at
// entity_count=10, ops=50 — see docs/internal/benchmark-budgets.md.
// Phase F regenerates on ubuntu-22.04.
const budget = struct {
    const get_product: Duration = .{ .ns = 100_000 }; // 100 µs
    const list_products: Duration = .{ .ns = 500_000 }; // 500 µs
    const update_product: Duration = .{ .ns = 200_000 }; // 200 µs
};

const bench_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

/// Test pipeline helper — runs the full prefetch + commit pipeline for native handlers.
fn pipeline_execute(sm: *StateMachine, msg: message.Message) message.Status {
    var handler: App.HandlersType(App.Storage) = .{};
    const identity = sm.resolve_credential(msg);
    const cache = handler.handler_prefetch(sm.storage, &msg) orelse unreachable;
    sm.begin_batch();
    var write_view = App.Storage.WriteView.init(sm.storage);
    const fw = App.HandlersType(App.Storage).FwCtx{ .identity = identity, .now = sm.now, .is_sse = false };
    const result = handler.handler_execute(cache, msg, fw, &write_view);
    sm.commit_batch();
    return result.status;
}

const repetitions = 32;

test "benchmark: state machine" {
    var bench: Bench = .init();
    defer bench.deinit();

    const entity_count: u32 = @intCast(bench.parameter("entity_count", 10, 1_000));
    const ops: u32 = @intCast(bench.parameter("ops", 50, 5_000));

    var prng = PRNG.from_seed(bench.seed);

    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, bench_test_key);

    // --- Seed phase (untimed) ---

    const id_pool_cap = 2048;
    var product_ids_buf: [id_pool_cap]u128 = undefined;
    var product_count: u32 = 0;

    for (0..entity_count * 2) |_| {
        if (product_count >= entity_count) break;
        const p = fuzz.gen_product(&prng);
        const msg = message.Message.init(.create_product, 0, 1, p);
        if (!state_machine.input_valid(msg)) continue;
        const status = pipeline_execute(&sm, msg);
        if (status == .ok) {
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
        var durations: [repetitions]Duration = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |i| {
                const msg = message.Message.init(.get_product, product_ids[i % product_count], 1, {});
                const status = pipeline_execute(&sm, msg);
                checksum +%= @intFromEnum(status);
            }
            const elapsed = bench.stop();
            dur.* = .{ .ns = elapsed.ns / ops };
        }
        const est = bench.estimate(&durations);
        bench.report("get_product = {d} ns", .{est.ns});
        bench.assert_budget(est, budget.get_product, "get_product");
    }

    // --- list_products ---
    {
        const params = std.mem.zeroes(message.ListParams);
        var durations: [repetitions]Duration = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |_| {
                const msg = message.Message.init(.list_products, 0, 1, params);
                const status = pipeline_execute(&sm, msg);
                checksum +%= @intFromEnum(status);
            }
            const elapsed = bench.stop();
            dur.* = .{ .ns = elapsed.ns / ops };
        }
        const est = bench.estimate(&durations);
        bench.report("list_products = {d} ns", .{est.ns});
        bench.assert_budget(est, budget.list_products, "list_products");
    }

    // --- update_product ---
    // Uses version=0 to bypass optimistic concurrency check, so the same
    // message succeeds on every repetition.
    {
        var update_payload = fuzz.gen_product(&prng);
        update_payload.version = 0;

        var durations: [repetitions]Duration = undefined;
        for (&durations) |*dur| {
            bench.start();
            for (0..ops) |i| {
                update_payload.id = product_ids[i % product_count];
                const msg = message.Message.init(.update_product, update_payload.id, 1, update_payload);
                const status = pipeline_execute(&sm, msg);
                checksum +%= @intFromEnum(status);
            }
            const elapsed = bench.stop();
            dur.* = .{ .ns = elapsed.ns / ops };
        }
        const est = bench.estimate(&durations);
        bench.report("update_product = {d} ns", .{est.ns});
        bench.assert_budget(est, budget.update_product, "update_product");
    }

    bench.report("checksum: {}", .{checksum});
}
