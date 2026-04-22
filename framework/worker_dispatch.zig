//! Worker dispatch — concurrent CALL/RESULT over shared memory.
//!
//! Manages a separate SHM region for worker dispatch (distinct from
//! the HTTP request ShmBus). The server sends CALLs when dispatching
//! workers, and polls for RESULTs when workers complete.
//!
//! Same SHM layout as ShmBus (SlotHeader, SlotPair, RegionHeader,
//! Region), same CRC convention, same seq protocol. Leading 24 bytes
//! of SlotHeader and the RegionHeader are the shared substrate — see
//! framework/shm_layout.zig.
//!
//! **Why a separate region, not multiplexed into ShmBus.** The two
//! transports look identical at the byte layout but diverge on
//! semantics:
//!
//!   - ShmBus: HTTP request dispatch. Bounded latency (handler must
//!     finish within a request deadline), strict write ordering
//!     (CALL → RESULT is a pair, no re-use of a slot until RESULT is
//!     consumed), and the slot is pinned 1:1 to a pipeline slot. The
//!     SlotHeader carries an explicit `slot_state` enum because the
//!     lifecycle is short-lived and crash-safety depends on it.
//!   - Worker dispatch: background work. Unbounded latency (a worker
//!     may block on an external API for seconds), no write ordering
//!     requirement, and the slot is pinned 1:1 to a WAL dispatch entry
//!     so the server knows which pending dispatch a RESULT completes.
//!     Lifecycle lives in `Entry.State` on the server side; the wire
//!     format does not need a `slot_state` byte, so the SlotHeader pads
//!     it out.
//!
//! Multiplexing would force one lifecycle model onto the other — the
//! HTTP path would pay the cost of Entry.State indirection, or the
//! worker path would pay the cost of slot_state round-trips. Two
//! regions with a shared substrate (shm_layout) is the right primitive.
//!
//! Both sides busy-poll per-slot sequence numbers. No futex dependency.
//! (See shm_bus.zig header for why busy-poll, not io_uring FUTEX_WAIT.)

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const constants = @import("constants.zig");
const shm_layout = @import("shm_layout.zig");

const wire = @import("wire.zig");
const log = std.log.scoped(.worker_dispatch);

pub const CallTag = wire.CallTag;
pub const ResultFlag = wire.ResultFlag;
const build_call = wire.build_call;
const parse_result = wire.parse_result;

pub fn WorkerDispatchType(comptime max_entries: u8) type {
    return struct {
        const Self = @This();

        // =============================================================
        // SHM layout — identical to ShmBus, standalone to avoid
        // IoUring dependency. Same extern struct sizes.
        // =============================================================

        /// NOTE: No slot_state field — unlike shm_bus.zig's SlotHeader which
        /// has an explicit SlotState enum. Worker dispatch uses Entry.State for
        /// lifecycle tracking (in-flight/completed/free), not a shared-memory
        /// field. Different SHM region, different protocol. The shared leading
        /// 24 bytes are pair-asserted against shm_layout — drift there would
        /// silently break the TS sidecar reader.
        pub const SlotHeader = extern struct {
            server_seq: u32 = 0,
            sidecar_seq: u32 = 0,
            request_len: u32 = 0,
            response_len: u32 = 0,
            request_crc: u32 = 0,
            response_crc: u32 = 0,
            _pad: [40]u8 = [_]u8{0} ** 40,

            comptime {
                shm_layout.assert_slot_header_layout(SlotHeader);
            }
        };

        const slot_data_size = constants.frame_max;

        pub const SlotPair = extern struct {
            header: SlotHeader,
            request: [slot_data_size]u8,
            response: [slot_data_size]u8,
        };

        pub const RegionHeader = shm_layout.RegionHeader;

        pub const Region = extern struct {
            header: RegionHeader,
            slots: [max_entries]SlotPair,

            comptime {
                assert(@sizeOf(Region) == 64 + @as(usize, max_entries) * @sizeOf(SlotPair));
            }
        };

        // =============================================================
        // Entry — per-slot worker dispatch state
        // =============================================================

        pub const Entry = struct {
            state: State = .free,
            request_id: u32 = 0,
            dispatch_op: u64 = 0, // WAL op — links to pending index
            dispatched_tick: u32 = 0, // server tick count for deadline
            result_flag: ResultFlag = .success,
            result_data: [constants.worker_result_max]u8 = undefined,
            result_len: usize = 0,

            pub const State = enum(u8) {
                free = 0,
                in_flight = 1,
                completed = 2,
            };
        };

        // =============================================================
        // Dispatch state
        // =============================================================

        entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
        next_request_id: u32 = 1,
        region: ?*Region = null,
        shm_fd: posix.fd_t = -1,
        server_seqs: [max_entries]u32 = [_]u32{0} ** max_entries,

        // =============================================================
        // Init / deinit
        // =============================================================

        /// Create the worker SHM region.
        pub fn create(self: *Self, name: []const u8) !void {
            assert(self.region == null);
            assert(name.len > 0);

            // Build null-terminated path: "/name"
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/{s}", .{name}) catch return error.NameTooLong;

            // Clean stale region.
            _ = std.c.shm_unlink(path.ptr);

            // Create shared memory — POSIX flags, cross-platform.
            const fd = std.c.shm_open(
                path.ptr,
                @bitCast(posix.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }),
                0o600,
            );
            if (fd < 0) return error.ShmOpenFailed;
            self.shm_fd = fd;

            posix.ftruncate(fd, @sizeOf(Region)) catch return error.FtruncateFailed;

            const ptr = posix.mmap(
                null,
                @sizeOf(Region),
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                fd,
                0,
            ) catch return error.MmapFailed;
            self.region = @ptrCast(@alignCast(ptr));

            // Zero the region, then write header fields.
            // Struct defaults don't apply to mmap'd memory.
            const region = self.region.?;
            @memset(@as([*]u8, @ptrCast(region))[0..@sizeOf(Region)], 0);
            region.header.slot_count = max_entries;
            region.header.frame_max = slot_data_size;

            log.info("worker shm: region={d}B, {d} slots", .{ @sizeOf(Region), max_entries });
        }

        pub fn deinit(self: *Self) void {
            if (self.region) |r| {
                posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(r)))[0..@sizeOf(Region)]);
                self.region = null;
            }
            if (self.shm_fd >= 0) {
                posix.close(self.shm_fd);
                self.shm_fd = -1;
            }
        }

        /// Create a test-only instance backed by anonymous mmap (no /dev/shm).
        pub fn init_test() Self {
            var self = Self{};
            const ptr = posix.mmap(
                null,
                @sizeOf(Region),
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            ) catch @panic("worker_dispatch: test mmap failed");
            self.region = @ptrCast(@alignCast(ptr));
            const region = self.region.?;
            @memset(@as([*]u8, @ptrCast(region))[0..@sizeOf(Region)], 0);
            region.header.slot_count = max_entries;
            region.header.frame_max = slot_data_size;
            return self;
        }

        pub fn deinit_test(self: *Self) void {
            if (self.region) |r| {
                posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(r)))[0..@sizeOf(Region)]);
                self.region = null;
            }
        }

        // =============================================================
        // Operations
        // =============================================================

        /// Find the first free slot. Returns null if all slots occupied.
        pub fn acquire_slot(self: *const Self) ?u8 {
            assert(self.region != null);
            for (&self.entries, 0..) |*entry, i| {
                if (entry.state == .free) return @intCast(i);
            }
            return null;
        }

        /// Dispatch a worker CALL to the given SHM slot.
        /// Dispatch a worker CALL to the given SHM slot.
        /// Returns false if the CALL frame is too large (name + args exceed frame_max).
        pub fn dispatch(
            self: *Self,
            slot_index: u8,
            name: []const u8,
            args: []const u8,
            dispatch_op: u64,
            tick: u32,
        ) bool {
            assert(slot_index < max_entries);
            assert(self.region != null);
            assert(self.entries[slot_index].state == .free);
            assert(self.entries[slot_index].dispatch_op == 0); // Pair: free state implies no active dispatch.
            assert(name.len > 0);
            assert(dispatch_op > 0);

            const region = self.region.?;
            var slot = &region.slots[slot_index];

            // Build CALL frame directly into SHM request area.
            const payload_len = build_call(
                &slot.request,
                self.next_request_id,
                name,
                args,
            ) orelse {
                log.warn("CALL frame too large: name_len={d} args_len={d}", .{ name.len, args.len });
                return false;
            };

            // CRC convention (len ++ payload) is defined in shm_layout.
            const len32: u32 = @intCast(payload_len);
            slot.header.request_len = len32;
            slot.header.request_crc = shm_layout.crc_frame(len32, &slot.request);

            // Bump server_seq (release — visible to worker).
            self.server_seqs[slot_index] +%= 1;
            @atomicStore(u32, &slot.header.server_seq, self.server_seqs[slot_index], .release);

            // Mark entry.
            self.entries[slot_index] = .{
                .state = .in_flight,
                .request_id = self.next_request_id,
                .dispatch_op = dispatch_op,
                .dispatched_tick = tick,
            };

            self.next_request_id +%= 1;
            return true;
        }

        /// Poll all in-flight slots for RESULT or QUERY frames from the sidecar.
        /// RESULT terminates the exchange (entry → completed).
        /// QUERY executes SQL and writes QUERY_RESULT (entry stays in_flight).
        pub fn poll_completions(self: *Self, storage: anytype) void {
            const region = self.region orelse return;

            for (&self.entries, 0..) |*entry, i| {
                if (entry.state != .in_flight) continue;

                // In-flight entries must have a non-zero server_seq.
                assert(self.server_seqs[i] > 0);

                const slot = &region.slots[i];
                const sidecar_seq = @atomicLoad(u32, &slot.header.sidecar_seq, .acquire);
                if (sidecar_seq < self.server_seqs[i]) continue;

                const frame = validate_response(slot) orelse continue;
                assert(frame.len >= 1);

                const tag = frame[0];
                if (tag == @intFromEnum(CallTag.result)) {
                    self.handle_result(entry, frame);
                } else if (tag == @intFromEnum(CallTag.query)) {
                    self.handle_query(entry, slot, frame, @intCast(i), storage);
                }
                // Unknown tags: silently ignored (CRC-validated but unrecognized).
            }
        }

        /// Validate CRC and bounds on the response area. Returns the frame
        /// slice on success, null on failure (CRC mismatch, zero length, etc.).
        fn validate_response(slot: *const SlotPair) ?[]const u8 {
            const response_length = slot.header.response_len;
            if (response_length == 0 or response_length > slot_data_size) return null;
            if (shm_layout.crc_frame(response_length, &slot.response) != slot.header.response_crc) {
                return null;
            }
            return slot.response[0..response_length];
        }

        /// Handle a RESULT frame — mark the entry completed with result data.
        fn handle_result(self: *Self, entry: *Entry, frame: []const u8) void {
            _ = self;
            assert(entry.state == .in_flight);
            const result = parse_result(frame) orelse return;
            if (result.request_id != entry.request_id) return;

            entry.result_flag = result.flag;
            const copy_length = @min(result.data.len, constants.worker_result_max);
            @memcpy(entry.result_data[0..copy_length], result.data[0..copy_length]);
            entry.result_len = copy_length;
            entry.state = .completed;
            assert(entry.state == .completed);
        }

        /// Handle a QUERY frame — execute SQL, write QUERY_RESULT, bump seq.
        /// The entry stays in_flight; the worker continues after receiving
        /// the QUERY_RESULT.
        fn handle_query(
            self: *Self,
            entry: *const Entry,
            slot: *SlotPair,
            frame: []const u8,
            slot_index: u8,
            storage: anytype,
        ) void {
            assert(entry.state == .in_flight);
            assert(slot_index < max_entries);

            if (frame.len < wire.query_header_size) return;
            const request_id = std.mem.readInt(u32, frame[1..5], .big);
            if (request_id != entry.request_id) return;

            const query_id = std.mem.readInt(u16, frame[5..7], .big);
            const sql_length = std.mem.readInt(u16, frame[7..9], .big);
            if (wire.query_header_size + sql_length + 2 > frame.len) return;

            const sql = frame[wire.query_header_size..][0..sql_length];
            const mode_byte = frame[wire.query_header_size + sql_length];
            const param_count = frame[wire.query_header_size + sql_length + 1];
            const params_data = frame[wire.query_header_size + sql_length + 2 ..];

            // Validate mode byte — reject unknown values.
            if (mode_byte != 0x00 and mode_byte != 0x01) {
                log.warn("worker slot {d}: unknown QUERY mode={d}, skipping.", .{ slot_index, mode_byte });
                return;
            }

            var query_result_buffer: [constants.frame_max]u8 = undefined;
            const query_mode = if (mode_byte == 0x01) @as(@TypeOf(storage.*).QueryMode, .query_all) else .query;
            const row_set = storage.query_raw(sql, params_data, param_count, query_mode, &query_result_buffer);

            // Build QUERY_RESULT and write to the slot's request area.
            write_query_result(slot, request_id, query_id, row_set);

            // Bump server_seq (release — visible to worker).
            self.server_seqs[slot_index] +%= 1;
            @atomicStore(u32, &slot.header.server_seq, self.server_seqs[slot_index], .release);

            log.debug("worker slot {d}: QUERY handled, sql_length={d}.", .{ slot_index, sql_length });
        }

        /// Build a QUERY_RESULT frame into the slot's request area.
        fn write_query_result(
            slot: *SlotPair,
            request_id: u32,
            query_id: u16,
            row_set: ?[]const u8,
        ) void {
            var pos: u32 = 0;
            slot.request[pos] = @intFromEnum(CallTag.query_result);
            pos += 1;
            std.mem.writeInt(u32, slot.request[pos..][0..4], request_id, .big);
            pos += 4;
            std.mem.writeInt(u16, slot.request[pos..][0..2], query_id, .big);
            pos += 2;
            if (row_set) |rs| {
                assert(pos + rs.len <= slot_data_size);
                @memcpy(slot.request[pos..][0..rs.len], rs);
                pos += @intCast(rs.len);
            }

            // Write length + CRC (convention defined in shm_layout).
            slot.header.request_len = pos;
            slot.header.request_crc = shm_layout.crc_frame(pos, &slot.request);
        }

        /// Return the first completed entry, or null.
        pub fn take_completed(self: *Self) ?*Entry {
            for (&self.entries) |*entry| {
                if (entry.state == .completed) return entry;
            }
            return null;
        }

        /// Return the first in-flight entry past its deadline, or null.
        /// `current_tick` is the server's monotonic tick count.
        /// `deadline_ticks` is the max ticks before a dispatch is dead.
        pub fn check_deadlines(self: *Self, current_tick: u32, deadline_ticks: u32) ?*Entry {
            assert(deadline_ticks > 0);
            for (&self.entries) |*entry| {
                if (entry.state != .in_flight) continue;
                if (current_tick -% entry.dispatched_tick >= deadline_ticks) return entry;
            }
            return null;
        }

        /// Release an entry back to free.
        pub fn release(self: *Self, entry: *Entry) void {
            assert(entry.state != .free); // Negative space: releasing a free entry is a bug.
            assert(entry.state == .completed or entry.state == .in_flight);
            assert(entry.dispatch_op > 0); // Pair: active entries always have a dispatch op.
            const idx = self.entry_index(entry);
            assert(idx < max_entries);
            self.entries[idx] = .{};
            assert(self.entries[idx].state == .free); // Post-condition: entry is now free.
        }

        /// Get the entry index from a pointer (pointer arithmetic).
        fn entry_index(self: *const Self, entry: *const Entry) u8 {
            const base = @intFromPtr(&self.entries);
            const ptr = @intFromPtr(entry);
            assert(ptr >= base);
            const offset = ptr - base;
            assert(offset % @sizeOf(Entry) == 0);
            return @intCast(offset / @sizeOf(Entry));
        }

        pub fn invariants(self: *const Self) void {
            var in_flight: u8 = 0;
            var completed: u8 = 0;
            for (&self.entries, 0..) |*entry, i| {
                switch (entry.state) {
                    .free => {
                        assert(entry.request_id == 0);
                        assert(entry.dispatch_op == 0);
                    },
                    .in_flight => {
                        assert(entry.request_id > 0);
                        assert(entry.dispatch_op > 0);
                        in_flight += 1;
                        // No duplicate dispatch_ops among active entries.
                        for (self.entries[i + 1 ..]) |*other| {
                            if (other.state == .free) continue;
                            assert(other.dispatch_op != entry.dispatch_op);
                        }
                    },
                    .completed => {
                        assert(entry.request_id > 0);
                        assert(entry.dispatch_op > 0);
                        completed += 1;
                    },
                }
            }
            assert(in_flight + completed <= max_entries);
        }

    };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

// Local DummyStorage for tests — can't import fuzz_lib.zig (outside module path).
const DummyStorage = struct {
    pub const QueryMode = enum { query, query_all };
    pub fn query_raw(_: *const DummyStorage, _: []const u8, _: []const u8, _: u8, _: QueryMode, _: []u8) ?[]const u8 {
        @panic("DummyStorage.query_raw called — test should not generate QUERY frames");
    }
};

test "WorkerDispatch: create and deinit" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    try testing.expect(wd.region != null);
    try testing.expectEqual(@as(?u8, 0), wd.acquire_slot());
}

test "WorkerDispatch: header init — slot_count and frame_max written after memset" {
    // Regression: mmap'd memory doesn't get struct defaults. If create/init_test
    // zeroes the region but forgets to write header fields, the sidecar reads
    // slot_count=0 and maps a 64-byte region (header only, no slots).
    var wd = WorkerDispatchType(8).init_test();
    defer wd.deinit_test();

    const region = wd.region.?;
    try testing.expectEqual(@as(u16, 8), region.header.slot_count);
    try testing.expectEqual(@as(u32, constants.frame_max), region.header.frame_max);
}

test "WorkerDispatch: dispatch writes CALL to SHM" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    const slot: u8 = 0;
    assert(wd.dispatch(slot, "charge_payment", "test_args", 1, 100));

    try testing.expectEqual(WorkerDispatchType(4).Entry.State.in_flight, wd.entries[slot].state);
    try testing.expectEqual(@as(u32, 1), wd.entries[slot].request_id);
    try testing.expectEqual(@as(u64, 1), wd.entries[slot].dispatch_op);
    try testing.expectEqual(@as(u32, 100), wd.entries[slot].dispatched_tick);

    // Verify CALL frame in SHM.
    const region = wd.region.?;
    const request = region.slots[slot].request;
    try testing.expectEqual(@as(u8, 0x10), request[0]); // call tag
    const request_id = std.mem.readInt(u32, request[1..5], .big);
    try testing.expectEqual(@as(u32, 1), request_id);

    // Next slot should be 1 (slot 0 is in_flight).
    try testing.expectEqual(@as(?u8, 1), wd.acquire_slot());
}

test "WorkerDispatch: poll detects completion" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    assert(wd.dispatch(0, "process_image", "", 5, 200));

    // Simulate sidecar writing a RESULT.
    simulate_result(&wd, 0, 1, .success, "result_data_123");

    wd.poll_completions(&DummyStorage{});

    try testing.expectEqual(WorkerDispatchType(4).Entry.State.completed, wd.entries[0].state);
    try testing.expectEqual(ResultFlag.success, wd.entries[0].result_flag);
    try testing.expectEqualSlices(u8, "result_data_123", wd.entries[0].result_data[0..wd.entries[0].result_len]);
}

test "WorkerDispatch: take_completed returns entry" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    // No completed entries yet.
    try testing.expect(wd.take_completed() == null);

    assert(wd.dispatch(0, "worker_a", "", 10, 300));
    simulate_result(&wd, 0, 1, .success, "done");
    wd.poll_completions(&DummyStorage{});

    const entry = wd.take_completed();
    try testing.expect(entry != null);
    try testing.expectEqual(@as(u64, 10), entry.?.dispatch_op);

    // Release and verify it's free.
    wd.release(entry.?);
    try testing.expectEqual(WorkerDispatchType(4).Entry.State.free, wd.entries[0].state);
    try testing.expectEqual(@as(?u8, 0), wd.acquire_slot());
}

test "WorkerDispatch: failure result" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    assert(wd.dispatch(0, "flaky_worker", "", 15, 400));
    simulate_result(&wd, 0, 1, .failure, "error: timeout");
    wd.poll_completions(&DummyStorage{});

    try testing.expectEqual(ResultFlag.failure, wd.entries[0].result_flag);
    try testing.expectEqualSlices(u8, "error: timeout", wd.entries[0].result_data[0..wd.entries[0].result_len]);
}

test "WorkerDispatch: deadline detection" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    assert(wd.dispatch(0, "slow_worker", "", 20, 100));

    // Not past deadline yet.
    try testing.expect(wd.check_deadlines(200, 3000) == null);

    // Past deadline.
    const expired = wd.check_deadlines(3200, 3000);
    try testing.expect(expired != null);
    try testing.expectEqual(@as(u64, 20), expired.?.dispatch_op);
}

test "WorkerDispatch: invariants" {
    var wd = WorkerDispatchType(4).init_test();
    defer wd.deinit_test();

    wd.invariants();

    assert(wd.dispatch(0, "a", "", 1, 10));
    assert(wd.dispatch(1, "b", "", 2, 20));
    wd.invariants();

    simulate_result(&wd, 0, 1, .success, "");
    wd.poll_completions(&DummyStorage{});
    wd.invariants();

    wd.release(&wd.entries[0]);
    wd.invariants();
}

test "CRC32 cross-language test vector" {
    // This test vector MUST match the TS worker SHM client and the
    // C SHM addon (shm.c). Calling shm_layout.crc_frame here turns any
    // silent divergence in the helper into an immediate test failure —
    // pair-assertion across the cross-language boundary.
    //
    // Convention: CRC32 covers len_bytes(4 LE) ++ payload_bytes.
    // Payload: "hello" (5 bytes). len = 5 (u32 LE = 0x05000000).
    const payload = "hello";
    const result = shm_layout.crc_frame(payload.len, payload);

    // Verified: matches Node zlib.crc32 and shm.c (zlib).
    // Regenerate in Node:
    //   const {crc32} = require("zlib");
    //   const buf = Buffer.from([0x05,0x00,0x00,0x00,0x68,0x65,0x6c,0x6c,0x6f]);
    //   console.log('0x' + (crc32(buf) >>> 0).toString(16).toUpperCase());
    //   // => 0x5CAC007A
    try testing.expectEqual(@as(u32, 0x5CAC007A), result);
}

// =========================================================================
// Test helpers
// =========================================================================

fn simulate_result(
    wd: anytype,
    slot_index: u8,
    request_id: u32,
    flag: ResultFlag,
    data: []const u8,
) void {
    const region = wd.region.?;
    var slot = &region.slots[slot_index];

    // Build RESULT frame: [tag:0x11][request_id:4 BE][flag:1][data]
    var pos: usize = 0;
    slot.response[pos] = 0x11; // CallTag.result
    pos += 1;
    std.mem.writeInt(u32, slot.response[pos..][0..4], request_id, .big);
    pos += 4;
    slot.response[pos] = @intFromEnum(flag);
    pos += 1;
    if (data.len > 0) {
        @memcpy(slot.response[pos..][0..data.len], data);
        pos += data.len;
    }

    // Set response metadata.
    const response_len: u32 = @intCast(pos);
    slot.header.response_len = response_len;
    slot.header.response_crc = shm_layout.crc_frame(response_len, &slot.response);

    // Bump sidecar_seq to signal response ready.
    @atomicStore(u32, &slot.header.sidecar_seq, wd.server_seqs[slot_index], .release);
}
