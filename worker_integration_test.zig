//! Worker integration test — exercises the full dispatch → completion lifecycle.
//!
//! Tests the path: pending dispatch → WorkerDispatch CALL → simulated RESULT
//! → tick takes completion → WAL completion entry → pending index resolved.
//!
//! Uses anonymous mmap (no /dev/shm) for the worker SHM and a temp WAL file.
//! No sidecar, no SimIO — tests the worker infrastructure in isolation.

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const message = @import("message.zig");
const wal_mod = @import("framework/wal.zig");
const pd = @import("framework/pending_dispatch.zig");
const wd_mod = @import("framework/worker_dispatch.zig");
const constants = @import("framework/constants.zig");

const Wal = wal_mod.WalType(message.Operation);
const WorkerDispatch = wd_mod.WorkerDispatchType(constants.max_in_flight_workers);
const PendingIndex = Wal.PendingIndex;

const DummyStorage = @import("fuzz_lib.zig").DummyStorage;

fn test_wal_path() [:0]const u8 {
    return "/tmp/tiger_worker_integration_test.wal";
}

fn cleanup_wal() void {
    std.posix.unlink(test_wal_path()) catch {};
}

/// Build a dispatch section for the WAL: [name_len:1][name][args_len:2 BE][args]
fn build_dispatch(name: []const u8, args: []const u8) struct { data: [256]u8, len: usize } {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intCast(name.len);
    pos += 1;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(args.len), .big);
    pos += 2;
    if (args.len > 0) {
        @memcpy(buf[pos..][0..args.len], args);
        pos += args.len;
    }
    return .{ .data = buf, .len = pos };
}

test "worker lifecycle: dispatch → CALL → RESULT → WAL completion → pending resolved" {
    cleanup_wal();
    defer cleanup_wal();

    // --- Phase 1: Record a dispatch in the WAL ---
    var pending = PendingIndex{};
    var wal = Wal.init(test_wal_path(), &pending);
    defer wal.deinit();

    // Simulate a handler committing SQL writes + a worker dispatch.
    const dispatch_section = build_dispatch("charge_payment", "test_args");
    var scratch: [8192]u8 = undefined;
    wal.append_writes(.create_order, 1000, "", 0, dispatch_section.data[0..dispatch_section.len], 1, &scratch);
    const dispatch_op = wal.op - 1; // op of the entry we just wrote

    // Add to pending index (same as server.add_dispatches_to_pending).
    var d = pd.PendingDispatch{
        .op = dispatch_op,
        .operation = @intFromEnum(message.Operation.create_order),
        .name = undefined,
        .name_len = "charge_payment".len,
        .args = undefined,
        .args_len = "test_args".len,
        .dispatched_at = 1000,
        .state = .pending,
    };
    @memcpy(d.name[0.."charge_payment".len], "charge_payment");
    @memcpy(d.args[0.."test_args".len], "test_args");
    assert(pending.add(d));

    // Verify: pending index has one dispatch.
    try testing.expectEqual(@as(u8, 1), pending.pending_count());
    const pd_entry = pending.find_by_op(dispatch_op);
    try testing.expect(pd_entry != null);
    try testing.expectEqualSlices(u8, "charge_payment", pd_entry.?.name_slice());

    // --- Phase 2: WorkerDispatch sends CALL ---
    var worker_dispatch = WorkerDispatch.init_test();
    defer worker_dispatch.deinit_test();

    // Scan pending index for .pending entries, dispatch via SHM.
    const slot = worker_dispatch.acquire_slot().?;
    const pd_mut = pending.find_by_op_mut(dispatch_op).?;
    assert(worker_dispatch.dispatch(
        slot,
        pd_mut.name[0..pd_mut.name_len],
        pd_mut.args[0..pd_mut.args_len],
        dispatch_op,
        100, // tick
    ));
    pd_mut.state = .in_flight;

    try testing.expectEqual(pd.PendingDispatch.State.in_flight, pd_mut.state);

    // --- Phase 3: Simulate sidecar worker RESULT ---
    simulate_worker_result(&worker_dispatch, slot, worker_dispatch.entries[slot].request_id, .success, "result_json");

    // Poll for completions.
    worker_dispatch.poll_completions(&DummyStorage{});
    try testing.expectEqual(WorkerDispatch.Entry.State.completed, worker_dispatch.entries[slot].state);

    // --- Phase 4: Process completion — WAL entry + pending resolve ---
    const completed = worker_dispatch.take_completed().?;
    try testing.expectEqual(dispatch_op, completed.dispatch_op);

    // Record WAL completion entry.
    wal.append_completion(
        .create_order, // operation (would be completion op in real code)
        1001, // timestamp
        "", // no writes (completion handler writes come from sidecar)
        0,
        dispatch_op,
        &scratch,
    );

    // Resolve pending index.
    pending.resolve(dispatch_op, .completed);
    worker_dispatch.release(completed);

    // --- Phase 5: Verify final state ---
    try testing.expectEqual(@as(u8, 0), pending.pending_count());
    try testing.expect(pending.find_by_op(dispatch_op) == null);
    worker_dispatch.invariants();

    // --- Phase 6: Verify WAL recovery rebuilds correctly ---
    {
        var recovered_pending = PendingIndex{};
        var wal2 = Wal.init(test_wal_path(), &recovered_pending);
        defer wal2.deinit();

        // The dispatch was completed — recovery should find zero pending.
        try testing.expectEqual(@as(u8, 0), recovered_pending.pending_count());
    }
}

test "worker lifecycle: dispatch → deadline → WAL dead → pending resolved" {
    cleanup_wal();
    defer cleanup_wal();

    var pending = PendingIndex{};
    var wal = Wal.init(test_wal_path(), &pending);
    defer wal.deinit();

    const dispatch_section = build_dispatch("slow_worker", "");
    var scratch: [8192]u8 = undefined;
    wal.append_writes(.create_order, 2000, "", 0, dispatch_section.data[0..dispatch_section.len], 1, &scratch);
    const dispatch_op = wal.op - 1;

    // Add to pending index.
    var d = pd.PendingDispatch{
        .op = dispatch_op,
        .operation = @intFromEnum(message.Operation.create_order),
        .name = undefined,
        .name_len = "slow_worker".len,
        .args = undefined,
        .args_len = 0,
        .dispatched_at = 2000,
        .state = .pending,
    };
    @memcpy(d.name[0.."slow_worker".len], "slow_worker");
    assert(pending.add(d));

    var worker_dispatch = WorkerDispatch.init_test();
    defer worker_dispatch.deinit_test();

    const slot = worker_dispatch.acquire_slot().?;
    const pd_mut = pending.find_by_op_mut(dispatch_op).?;
    assert(worker_dispatch.dispatch(slot, pd_mut.name[0..pd_mut.name_len], "", dispatch_op, 100));
    pd_mut.state = .in_flight;

    // No RESULT — check deadline after threshold.
    const expired = worker_dispatch.check_deadlines(100 + constants.worker_deadline_ticks + 1, constants.worker_deadline_ticks);
    try testing.expect(expired != null);
    try testing.expectEqual(dispatch_op, expired.?.dispatch_op);

    // Record WAL dead-dispatch entry.
    wal.append_dead_dispatch(.create_order, 2100, dispatch_op, &scratch);
    pending.resolve(dispatch_op, .dead);
    worker_dispatch.release(expired.?);

    try testing.expectEqual(@as(u8, 0), pending.pending_count());

    // Verify recovery.
    {
        var recovered = PendingIndex{};
        var wal2 = Wal.init(test_wal_path(), &recovered);
        defer wal2.deinit();
        try testing.expectEqual(@as(u8, 0), recovered.pending_count());
    }
}

// =========================================================================
// Test helpers
// =========================================================================

fn simulate_worker_result(
    dispatch: *WorkerDispatch,
    slot_idx: u8,
    request_id: u32,
    flag: wd_mod.ResultFlag,
    data: []const u8,
) void {
    const region = dispatch.region.?;
    var s = &region.slots[slot_idx];

    var pos: usize = 0;
    s.response[pos] = 0x11; // result tag
    pos += 1;
    std.mem.writeInt(u32, s.response[pos..][0..4], request_id, .big);
    pos += 4;
    s.response[pos] = @intFromEnum(flag);
    pos += 1;
    if (data.len > 0) {
        @memcpy(s.response[pos..][0..data.len], data);
        pos += data.len;
    }

    const response_len: u32 = @intCast(pos);
    s.header.response_len = response_len;

    var crc = std.hash.crc.Crc32.init();
    crc.update(std.mem.asBytes(&response_len));
    crc.update(s.response[0..response_len]);
    s.header.response_crc = crc.final();

    @atomicStore(u32, &s.header.sidecar_seq, dispatch.server_seqs[slot_idx], .release);
}
