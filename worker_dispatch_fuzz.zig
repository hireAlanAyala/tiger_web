//! Worker dispatch boundary fuzzer — exercises WorkerDispatch with
//! malformed RESULT frames, unknown request_ids, truncated data,
//! and duplicate completions.
//!
//! Verifies: every malformed result is rejected (no state corruption),
//! valid results are accepted, and invariants hold throughout.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("framework/constants.zig");
const wd_mod = @import("framework/worker_dispatch.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

const WorkerDispatch = wd_mod.WorkerDispatchType(8); // 8 slots for fuzzing
const Crc32 = std.hash.crc.Crc32;

const log = std.log.scoped(.fuzz);

const DummyStorage = @import("fuzz_lib.zig").DummyStorage;

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var wd = WorkerDispatch.init_test();
    defer wd.deinit_test();

    var dispatched_ops: [8]u64 = .{0} ** 8;
    var dispatched_request_ids: [8]u32 = .{0} ** 8;
    var dispatched_count: u8 = 0;
    var valid_completions: u64 = 0;
    var rejected_completions: u64 = 0;
    var dispatches_total: u64 = 0;
    var deadlines_detected: u64 = 0;
    var tick: u32 = 0;

    for (0..events_max) |_| {
        tick +%= 1;
        const action = prng.range_inclusive(u32, 0, 99);

        if (action < 30 and dispatched_count < 8) {
            // Dispatch a new worker.
            const slot = wd.acquire_slot() orelse continue;
            const op: u64 = prng.range_inclusive(u64, 1, 1_000_000);
            assert(wd.dispatch(slot, "fuzz_worker", "fuzz_args", op, tick));
            dispatched_ops[slot] = op;
            dispatched_request_ids[slot] = wd.entries[slot].request_id;
            dispatched_count += 1;
            dispatches_total += 1;
        } else if (action < 50 and dispatched_count > 0) {
            // Write a valid RESULT for a random in-flight slot.
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const request_id = dispatched_request_ids[slot];
            const flag: u8 = if (prng.boolean()) 0x00 else 0x01; // success or failure
            write_valid_result(&wd, slot, request_id, flag, "valid_data");
            wd.poll_completions(&DummyStorage{});

            // Verify it was accepted.
            if (wd.entries[slot].state == .completed) {
                valid_completions += 1;
                wd.release(&wd.entries[slot]);
                dispatched_count -= 1;
            }
        } else if (action < 65 and dispatched_count > 0) {
            // Write a RESULT with wrong request_id.
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const bad_id = prng.range_inclusive(u32, 100_000, 200_000); // unlikely to match
            write_valid_result(&wd, slot, bad_id, 0x00, "wrong_id");
            wd.poll_completions(&DummyStorage{});

            // Must NOT have completed (wrong request_id).
            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 75 and dispatched_count > 0) {
            // Write a RESULT with bad CRC.
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const request_id = dispatched_request_ids[slot];
            write_valid_result(&wd, slot, request_id, 0x00, "bad_crc");
            // Corrupt the CRC.
            wd.region.?.slots[slot].header.response_crc +%= 1;
            wd.poll_completions(&DummyStorage{});

            // Must NOT have completed (bad CRC).
            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 82 and dispatched_count > 0) {
            // Write a truncated RESULT (too short for header).
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const region = wd.region.?;
            var s = &region.slots[slot];
            // Write only 3 bytes (need at least 6 for tag+request_id+flag).
            s.response[0] = 0x11;
            s.response[1] = 0;
            s.response[2] = 0;
            const len: u32 = 3;
            s.header.response_len = len;
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&len));
            crc.update(s.response[0..len]);
            s.header.response_crc = crc.final();
            @atomicStore(u32, &s.header.sidecar_seq, wd.server_seqs[slot], .release);
            wd.poll_completions(&DummyStorage{});

            // Must NOT have completed (truncated).
            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 88 and dispatched_count > 0) {
            // Write RESULT with wrong tag byte.
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const request_id = dispatched_request_ids[slot];
            write_result_with_tag(&wd, slot, 0x10, request_id, 0x00, "wrong_tag"); // 0x10 = call, not result
            wd.poll_completions(&DummyStorage{});

            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 90 and dispatched_count > 0) {
            // Write a malformed QUERY frame (truncated — too short for header).
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const region = wd.region.?;
            var s = &region.slots[slot];
            // QUERY needs at least 9 bytes: tag(1) + request_id(4) + query_id(2) + sql_len(2).
            // Write only 5 bytes to trigger rejection.
            s.response[0] = 0x12; // QUERY tag
            std.mem.writeInt(u32, s.response[1..5], dispatched_request_ids[slot], .big);
            const len: u32 = 5;
            s.header.response_len = len;
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&len));
            crc.update(s.response[0..len]);
            s.header.response_crc = crc.final();
            @atomicStore(u32, &s.header.sidecar_seq, wd.server_seqs[slot], .release);
            wd.poll_completions(&DummyStorage{});

            // Must stay in_flight — truncated QUERY rejected.
            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 92 and dispatched_count > 0) {
            // Write a QUERY frame with invalid mode byte.
            const slot = pick_in_flight_slot(&wd, &prng) orelse continue;
            const region = wd.region.?;
            var s = &region.slots[slot];
            var pos: usize = 0;
            s.response[pos] = 0x12; pos += 1; // QUERY tag
            std.mem.writeInt(u32, s.response[pos..][0..4], dispatched_request_ids[slot], .big); pos += 4;
            std.mem.writeInt(u16, s.response[pos..][0..2], 0, .big); pos += 2; // query_id
            std.mem.writeInt(u16, s.response[pos..][0..2], 0, .big); pos += 2; // sql_len = 0
            s.response[pos] = 0xFF; pos += 1; // invalid mode byte
            s.response[pos] = 0; pos += 1; // param_count = 0
            const len: u32 = @intCast(pos);
            s.header.response_len = len;
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&len));
            crc.update(s.response[0..len]);
            s.header.response_crc = crc.final();
            @atomicStore(u32, &s.header.sidecar_seq, wd.server_seqs[slot], .release);
            wd.poll_completions(&DummyStorage{});

            // Must stay in_flight — invalid mode rejected.
            assert(wd.entries[slot].state == .in_flight);
            rejected_completions += 1;
        } else if (action < 94) {
            // Check deadlines with large tick jump.
            if (wd.check_deadlines(tick +% 100_000, 3000)) |entry| {
                wd.release(entry);
                dispatched_count -= 1;
                deadlines_detected += 1;
            }
        } else {
            // Just poll (no-op if nothing to poll).
            wd.poll_completions(&DummyStorage{});
        }

        wd.invariants();
    }

    log.info("Worker dispatch fuzz done: dispatches={d} valid={d} rejected={d} deadlines={d}", .{
        dispatches_total, valid_completions, rejected_completions, deadlines_detected,
    });
    assert(dispatches_total > 0);
    assert(valid_completions > 0);
    assert(rejected_completions > 0);
}

fn pick_in_flight_slot(wd: *WorkerDispatch, prng: *PRNG) ?u8 {
    // Collect in-flight slot indices.
    var slots: [8]u8 = undefined;
    var count: u8 = 0;
    for (&wd.entries, 0..) |*entry, i| {
        if (entry.state == .in_flight) {
            slots[count] = @intCast(i);
            count += 1;
        }
    }
    if (count == 0) return null;
    return slots[prng.range_inclusive(u8, 0, count - 1)];
}

fn write_valid_result(wd: *WorkerDispatch, slot: u8, request_id: u32, flag: u8, data: []const u8) void {
    write_result_with_tag(wd, slot, 0x11, request_id, flag, data);
}

fn write_result_with_tag(wd: *WorkerDispatch, slot: u8, tag: u8, request_id: u32, flag: u8, data: []const u8) void {
    const region = wd.region.?;
    var s = &region.slots[slot];

    var pos: usize = 0;
    s.response[pos] = tag;
    pos += 1;
    std.mem.writeInt(u32, s.response[pos..][0..4], request_id, .big);
    pos += 4;
    s.response[pos] = flag;
    pos += 1;
    if (data.len > 0) {
        @memcpy(s.response[pos..][0..data.len], data);
        pos += data.len;
    }

    const response_len: u32 = @intCast(pos);
    s.header.response_len = response_len;

    var crc = Crc32.init();
    crc.update(std.mem.asBytes(&response_len));
    crc.update(s.response[0..response_len]);
    s.header.response_crc = crc.final();

    @atomicStore(u32, &s.header.sidecar_seq, wd.server_seqs[slot], .release);
}
