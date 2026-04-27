//! Worker dispatch boundary fuzzer — exercises WorkerDispatch with
//! malformed RESULT frames, unknown request_ids, truncated data,
//! QUERY frames, and duplicate completions.
//!
//! Verifies: every malformed result is rejected (no state corruption),
//! valid results are accepted, and invariants hold throughout.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("framework/constants.zig");
const wd_mod = @import("framework/worker_dispatch.zig");
const wire = @import("framework/wire.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const DummyStorage = @import("fuzz_lib.zig").DummyStorage;
const PRNG = @import("stdx").PRNG;

const WorkerDispatch = wd_mod.WorkerDispatchType(8);
const Crc32 = std.hash.crc.Crc32;
const log = std.log.scoped(.fuzz);

/// Per-slot tracking — replaces parallel arrays.
const SlotInfo = struct {
    op: u64 = 0,
    request_id: u32 = 0,
};

/// Fuzz counters for summary assertion.
const Counters = struct {
    valid_completions: u64 = 0,
    rejected_completions: u64 = 0,
    dispatches_total: u64 = 0,
    deadlines_detected: u64 = 0,
};

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    var prng = PRNG.from_seed(args.seed);
    const events_max = args.events_max orelse 10_000;

    var wd = WorkerDispatch.init_test();
    defer wd.deinit_test();

    var slots: [8]SlotInfo = [_]SlotInfo{.{}} ** 8;
    var dispatched_count: u8 = 0;
    var counters = Counters{};
    var tick: u32 = 0;

    for (0..events_max) |_| {
        tick +%= 1;
        const action = prng.range_inclusive(u32, 0, 99);

        if (action < 30 and dispatched_count < 8) {
            dispatched_count += fuzz_dispatch(&wd, &slots, &counters, &prng, tick);
        } else if (action < 50 and dispatched_count > 0) {
            dispatched_count -%= fuzz_valid_result(&wd, &slots, &counters, &prng);
        } else if (action < 65 and dispatched_count > 0) {
            fuzz_wrong_request_id(&wd, &slots, &counters, &prng);
        } else if (action < 75 and dispatched_count > 0) {
            fuzz_bad_crc(&wd, &slots, &counters, &prng);
        } else if (action < 82 and dispatched_count > 0) {
            fuzz_truncated_result(&wd, &slots, &counters);
        } else if (action < 88 and dispatched_count > 0) {
            fuzz_wrong_tag(&wd, &slots, &counters, &prng);
        } else if (action < 90 and dispatched_count > 0) {
            fuzz_truncated_query(&wd, &slots, &counters);
        } else if (action < 92 and dispatched_count > 0) {
            fuzz_invalid_query_mode(&wd, &slots, &counters);
        } else if (action < 94) {
            fuzz_deadline(&wd, &dispatched_count, &counters, tick);
        } else {
            wd.poll_completions(&DummyStorage{});
        }

        wd.invariants();
    }

    log.info("Worker dispatch fuzz: dispatches={d} valid={d} rejected={d} deadlines={d}", .{
        counters.dispatches_total, counters.valid_completions,
        counters.rejected_completions, counters.deadlines_detected,
    });
    assert(counters.dispatches_total > 0);
    assert(counters.valid_completions > 0);
    assert(counters.rejected_completions > 0);
}

// =========================================================================
// Action functions — each exercises one fuzz scenario.
// =========================================================================

fn fuzz_dispatch(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters, prng: *PRNG, tick: u32) u8 {
    const slot = wd.acquire_slot() orelse return 0;
    assert(slot < 8);
    const op: u64 = prng.range_inclusive(u64, 1, 1_000_000);
    assert(wd.dispatch(slot, "fuzz_worker", "fuzz_args", op, tick));
    slots[slot] = .{ .op = op, .request_id = wd.entries[slot].request_id };
    counters.dispatches_total += 1;
    return 1;
}

fn fuzz_valid_result(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters, prng: *PRNG) u8 {
    const slot = pick_in_flight_slot(wd, prng) orelse return 0;
    const flag: u8 = if (prng.boolean()) 0x00 else 0x01;
    write_result(wd, slot, slots[slot].request_id, flag, "valid_data");
    wd.poll_completions(&DummyStorage{});
    if (wd.entries[slot].state == .completed) {
        counters.valid_completions += 1;
        wd.release(&wd.entries[slot]);
        return 1;
    }
    return 0;
}

fn fuzz_wrong_request_id(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters, prng: *PRNG) void {
    _ = slots;
    const slot = pick_in_flight_slot(wd, prng) orelse return;
    write_result(wd, slot, prng.range_inclusive(u32, 100_000, 200_000), 0x00, "wrong_id");
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_bad_crc(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters, prng: *PRNG) void {
    const slot = pick_in_flight_slot(wd, prng) orelse return;
    write_result(wd, slot, slots[slot].request_id, 0x00, "bad_crc");
    wd.region.?.slots[slot].header.response_crc +%= 1;
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_truncated_result(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters) void {
    _ = slots;
    const slot = first_in_flight_slot(wd) orelse return;
    write_raw_frame(wd, slot, &.{ 0x11, 0, 0 });
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_wrong_tag(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters, prng: *PRNG) void {
    const slot = pick_in_flight_slot(wd, prng) orelse return;
    write_result_with_tag(wd, slot, 0x10, slots[slot].request_id, 0x00, "wrong_tag");
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_truncated_query(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters) void {
    const slot = first_in_flight_slot(wd) orelse return;
    // QUERY header needs 9 bytes; write only 5 to trigger rejection.
    var frame: [5]u8 = undefined;
    frame[0] = @intFromEnum(wire.CallTag.query);
    std.mem.writeInt(u32, frame[1..5], slots[slot].request_id, .big);
    write_raw_frame(wd, slot, &frame);
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_invalid_query_mode(wd: *WorkerDispatch, slots: *[8]SlotInfo, counters: *Counters) void {
    const slot = first_in_flight_slot(wd) orelse return;
    var frame: [11]u8 = undefined;
    frame[0] = @intFromEnum(wire.CallTag.query);
    std.mem.writeInt(u32, frame[1..5], slots[slot].request_id, .big);
    std.mem.writeInt(u16, frame[5..7], 0, .big); // query_id.
    std.mem.writeInt(u16, frame[7..9], 0, .big); // sql_len = 0.
    frame[9] = 0xFF; // Invalid mode byte.
    frame[10] = 0; // param_count = 0.
    write_raw_frame(wd, slot, &frame);
    wd.poll_completions(&DummyStorage{});
    assert(wd.entries[slot].state == .in_flight);
    counters.rejected_completions += 1;
}

fn fuzz_deadline(wd: *WorkerDispatch, dispatched_count: *u8, counters: *Counters, tick: u32) void {
    if (wd.check_deadlines(tick +% 100_000, 3000)) |entry| {
        wd.release(entry);
        dispatched_count.* -%= 1;
        counters.deadlines_detected += 1;
    }
}

// =========================================================================
// Helpers.
// =========================================================================

fn pick_in_flight_slot(wd: *WorkerDispatch, prng: *PRNG) ?u8 {
    var indices: [8]u8 = undefined;
    var count: u8 = 0;
    for (&wd.entries, 0..) |*entry, i| {
        if (entry.state == .in_flight) {
            indices[count] = @intCast(i);
            count += 1;
        }
    }
    if (count == 0) return null;
    return indices[prng.range_inclusive(u8, 0, count - 1)];
}

fn first_in_flight_slot(wd: *WorkerDispatch) ?u8 {
    for (&wd.entries, 0..) |*entry, i| {
        if (entry.state == .in_flight) return @intCast(i);
    }
    return null;
}

fn write_result(wd: *WorkerDispatch, slot: u8, request_id: u32, flag: u8, data: []const u8) void {
    write_result_with_tag(wd, slot, @intFromEnum(wire.CallTag.result), request_id, flag, data);
}

fn write_result_with_tag(wd: *WorkerDispatch, slot: u8, tag: u8, request_id: u32, flag: u8, data: []const u8) void {
    assert(slot < 8);
    assert(wd.region != null);
    const region = wd.region.?;
    var response = &region.slots[slot];

    var pos: usize = 0;
    response.response[pos] = tag;
    pos += 1;
    std.mem.writeInt(u32, response.response[pos..][0..4], request_id, .big);
    pos += 4;
    response.response[pos] = flag;
    pos += 1;
    if (data.len > 0) {
        @memcpy(response.response[pos..][0..data.len], data);
        pos += data.len;
    }

    finalize_response(response, @intCast(pos), wd.server_seqs[slot]);
}

fn write_raw_frame(wd: *WorkerDispatch, slot: u8, frame: []const u8) void {
    assert(slot < 8);
    const region = wd.region.?;
    var response = &region.slots[slot];
    @memcpy(response.response[0..frame.len], frame);
    finalize_response(response, @intCast(frame.len), wd.server_seqs[slot]);
}

fn finalize_response(slot: *WorkerDispatch.SlotPair, length: u32, server_seq: u32) void {
    slot.header.response_len = length;
    var crc = Crc32.init();
    crc.update(std.mem.asBytes(&length));
    crc.update(slot.response[0..length]);
    slot.header.response_crc = crc.final();
    @atomicStore(u32, &slot.header.sidecar_seq, server_seq, .release);
}
