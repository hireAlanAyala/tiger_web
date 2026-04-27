//! Shared memory bus — mmap + busy-poll transport.
//!
//! Drop-in replacement for MessageBusType when used with the v2 dispatch.
//! Same interface: send_message_to, is_connection_ready, can_send_to,
//! get_message, unref.
//!
//! Layout per slot pair:
//!   [Header 64B][Request frame_max][Response frame_max]
//!
//! Signaling: both sides busy-poll per-slot sequence numbers.
//! Server polls sidecar_seq in the tick loop (run_for_ns(0) when pending).
//! Sidecar polls server_seq via C addon (setImmediate when active,
//! setTimeout(1ms) when idle). No futex, no io_uring dependency.
//!
//! **Why busy-poll, not io_uring FUTEX_WAIT.** An event-driven wake via
//! io_uring_prep_futex_wait was attempted in commit 5ff1088 and reverted
//! in 687761f after it collapsed throughput from 57K req/s to 362 req/s.
//! The regression turned out to be elsewhere (commit 1215ba4 moved
//! poll_shm into the tick loop without preserving the run_for_ns(0)
//! drain); but the attempt proved that event-driven wake adds per-request
//! syscall cost that busy-poll avoids. **Do not re-attempt without a
//! benchmark that beats busy-poll + run_for_ns(0)-when-pending** — the
//! current default mix sustains ~64K req/s (2026-04-22).
//!
//! CRC covers len_bytes ++ payload_bytes (TB convention — corrupted
//! length produces CRC mismatch, not garbage read). See
//! framework/shm_layout.zig:crc_frame for the shared helper.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const protocol = @import("../protocol.zig");
const shm_layout = @import("shm_layout.zig");
const log = std.log.scoped(.shm_bus);

pub fn SharedMemoryBusType(comptime options: Options) type {
    return struct {
        const Self = @This();
        pub const slot_count = options.slot_count;

        pub const frame_header_size: u32 = 0;

        // =============================================================
        // Shared memory layout — extern struct, comptime-verified
        // =============================================================

        /// Slot state — explicit lifecycle tracking for crash safety analysis.
        /// The state is the source of truth for where the slot is in the
        /// CALL/RESULT cycle. Sequence numbers are for ordering and wake
        /// detection; state is for safety invariants.
        pub const SlotState = enum(u8) {
            /// No active request. Safe to write a new CALL.
            free = 0,
            /// Server wrote CALL + CRC, bumped server_seq. Sidecar can read.
            call_written = 1,
            /// Sidecar wrote RESULT + CRC, bumped sidecar_seq. Server can read.
            result_written = 2,
        };

        pub const SlotHeader = extern struct {
            server_seq: u32 = 0,
            sidecar_seq: u32 = 0,
            request_len: u32 = 0,
            response_len: u32 = 0,
            request_crc: u32 = 0,
            response_crc: u32 = 0,
            /// Explicit slot lifecycle state. Written by both sides:
            ///   server: free → call_written (after CALL write)
            ///   sidecar: call_written → result_written (after RESULT write)
            ///   server: result_written → free (after RESULT read)
            /// Crash safety: if sidecar crashes in call_written, server
            /// times out. If server crashes in result_written, sidecar's
            /// RESULT is lost (acceptable — client retries).
            slot_state: SlotState = .free,
            _pad: [39]u8 = [_]u8{0} ** 39,

            // Freeze the leading-field offsets against the cross-language
            // contract in packages/vectors/shm_layout.json. Drift here
            // silently breaks the TS sidecar reader.
            comptime {
                shm_layout.assert_slot_header_layout(SlotHeader);
            }
        };

        const slot_data_size = protocol.frame_max;

        pub const SlotPair = extern struct {
            header: SlotHeader,
            request: [slot_data_size]u8,
            response: [slot_data_size]u8,
        };

        pub const RegionHeader = shm_layout.RegionHeader;

        pub const Region = extern struct {
            header: RegionHeader,
            slots: [slot_count]SlotPair,

            comptime {
                assert(@sizeOf(Region) == 64 + @as(usize, slot_count) * @sizeOf(SlotPair));
                assert(@sizeOf(Region) <= 32 * 1024 * 1024);
            }
        };

        // =============================================================
        // Message — bus interface compat
        // =============================================================

        pub const Message = struct {
            buffer: [protocol.frame_max]u8,
            references: u32,
            slot_index: u8,
        };

        pub const Connection = struct {
            pub const CloseReason = enum { eof, recv_error, shutdown };
        };

        // =============================================================
        // Bus state
        // =============================================================

        region: ?*Region = null,
        shm_fd: posix.fd_t = -1,

        server_seqs: [slot_count]u32 = [_]u32{0} ** slot_count,
        slot_delivered: [slot_count]bool = [_]bool{false} ** slot_count,
        /// Tracks the request_id sent in each slot's CALL. Verified against
        /// the RESULT's request_id on response — catches sidecar bugs that
        /// respond to the wrong request (silent data corruption).
        sent_request_ids: [slot_count]u32 = [_]u32{0} ** slot_count,

        // Message pool — heap-allocated to avoid 4MB inline in Server struct.
        message_pool: ?[*]Message = null,
        next_message: u8 = 0,

        ready: bool = false,

        on_frame_fn: ?*const fn (*anyopaque, u8, []const u8) void = null,
        context: ?*anyopaque = null,

        shm_name: [64]u8 = undefined,
        shm_name_len: u8 = 0,

        // =============================================================
        // Init / deinit
        // =============================================================

        pub fn create(
            self: *Self,
            name: []const u8,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            context: *anyopaque,
        ) !void {
            // Double-init catches the "create on a live bus" bug — would
            // leak the previous region and confuse the sidecar.
            assert(self.region == null);
            assert(self.message_pool == null);
            assert(name.len > 0);
            assert(name.len < self.shm_name.len);

            self.on_frame_fn = on_frame_fn;
            self.context = context;

            // Allocate message pool on the heap (16 × 256KB = 4MB).
            const pool_count = slot_count * 2;
            const pool = std.heap.page_allocator.alloc(Message, pool_count) catch return error.PoolAllocFailed;
            for (pool) |*m| {
                m.references = 0;
                m.slot_index = 0;
            }
            self.message_pool = pool.ptr;

            @memcpy(self.shm_name[0..name.len], name);
            self.shm_name_len = @intCast(name.len);

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

            // Size the region.
            posix.ftruncate(fd, @sizeOf(Region)) catch return error.FtruncateFailed;

            // Map it.
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
            // Struct defaults don't apply to mmap'd memory — must be explicit.
            const region = self.region.?;
            @memset(@as([*]u8, @ptrCast(region))[0..@sizeOf(Region)], 0);
            region.header.slot_count = slot_count;
            region.header.frame_max = slot_data_size;

            log.info("shm bus: region={d}B, {d} slots, name={s}", .{
                @sizeOf(Region), slot_count, name,
            });
        }

        pub fn deinit(self: *Self) void {
            if (self.message_pool) |pool| {
                std.heap.page_allocator.free(pool[0 .. slot_count * 2]);
                self.message_pool = null;
            }
            if (self.region) |r| {
                posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrCast(@alignCast(r)))[0..@sizeOf(Region)]);
                self.region = null;
            }
            if (self.shm_fd >= 0) {
                posix.close(self.shm_fd);
                self.shm_fd = -1;
            }
            // Unlink named SHM (no-op for anonymous test regions).
            if (self.shm_name_len > 0) {
                var path_buf: [128]u8 = undefined;
                if (std.fmt.bufPrintZ(&path_buf, "/{s}", .{self.shm_name[0..self.shm_name_len]})) |path| {
                    _ = std.c.shm_unlink(path.ptr);
                } else |_| {}
            }
            // Post: the bus is fully torn down — any re-use requires create() again.
            assert(self.region == null);
            assert(self.message_pool == null);
            assert(self.shm_fd == -1);
        }

        /// Create a test-only instance backed by anonymous mmap (no /dev/shm).
        /// Same layout as create() but no filesystem involvement.
        pub fn create_test(
            self: *Self,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            context: *anyopaque,
        ) void {
            assert(self.region == null);
            assert(self.message_pool == null);
            self.on_frame_fn = on_frame_fn;
            self.context = context;

            // Message pool.
            const pool_count = slot_count * 2;
            const pool = std.heap.page_allocator.alloc(Message, pool_count) catch
                @panic("shm_bus: test pool alloc failed");
            for (pool) |*m| {
                m.references = 0;
                m.slot_index = 0;
            }
            self.message_pool = pool.ptr;

            // Anonymous mmap — no /dev/shm, no cleanup needed.
            const ptr = posix.mmap(
                null,
                @sizeOf(Region),
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                -1,
                0,
            ) catch @panic("shm_bus: test mmap failed");
            self.region = @ptrCast(@alignCast(ptr));
            const region = self.region.?;
            @memset(@as([*]u8, @ptrCast(region))[0..@sizeOf(Region)], 0);
            region.header.slot_count = slot_count;
            region.header.frame_max = slot_data_size;
        }

        pub fn set_ready(self: *Self) void {
            // Only transition once per bus lifetime. A double-set would
            // indicate a reconnection path we have not yet designed for.
            assert(!self.ready);
            assert(self.region != null);
            self.ready = true;
        }

        // =============================================================
        // Bus interface
        // =============================================================

        pub fn is_connection_ready(self: *const Self, _: u8) bool {
            return self.ready;
        }

        pub fn can_send_to(self: *const Self, _: u8) bool {
            return self.region != null and self.ready;
        }

        pub fn get_message(self: *Self) *Message {
            const pool = self.message_pool orelse @panic("shm bus: message pool not initialized");
            const idx = self.next_message;
            // Ring index must always be in bounds of the pool.
            assert(idx < slot_count * 2);
            self.next_message = (self.next_message + 1) % (slot_count * 2);
            pool[idx].references = 1;
            return &pool[idx];
        }

        pub fn unref(_: *Self, _: *Message) void {}

        /// Get direct write access to a slot's request buffer.
        /// Caller writes the CALL frame directly, then calls finalize_slot_send.
        /// Eliminates intermediate buffer copies.
        pub fn get_slot_request_buf(self: *Self, slot_index: u8) ?[]u8 {
            assert(slot_index < slot_count);
            const region = self.region orelse return null;
            // The slot must be free — dispatching a CALL to a slot that
            // already carries one would overwrite the pending request.
            assert(region.slots[slot_index].header.slot_state == .free);
            self.slot_delivered[slot_index] = false;
            return &region.slots[slot_index].request;
        }

        /// Finalize a direct-write send: compute CRC, bump seq.
        /// Call after writing payload into the buffer returned by get_slot_request_buf.
        pub fn finalize_slot_send(self: *Self, slot_index: u8, payload_len: u32) void {
            const region = self.region orelse return;
            assert(slot_index < slot_count);
            const slot = &region.slots[slot_index];

            // Precondition: slot must be free. If this fires, the server
            // dispatched two CALLs to the same slot — a logic bug that would
            // silently overwrite the first request.
            assert(slot.header.slot_state == .free);

            // Extract request_id from CALL frame (offset 1, u32 BE) for
            // verification when the RESULT comes back.
            assert(payload_len >= 5); // tag + request_id minimum
            self.sent_request_ids[slot_index] = std.mem.readInt(u32, slot.request[1..5], .big);

            slot.header.request_len = payload_len;
            slot.header.request_crc = shm_layout.crc_frame(payload_len, &slot.request);
            slot.header.slot_state = .call_written;

            self.server_seqs[slot_index] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_index], .release);
        }

        /// Write a CALL payload to shared memory for the given slot.
        /// The slot is determined by message.slot_index — pinned 1:1
        /// to dispatch entries. No round-robin, no collisions.
        pub fn send_message_to(self: *Self, _: u8, message: *Message, payload_len: u32) void {
            const region = self.region orelse return;
            const slot_index = message.slot_index;
            assert(slot_index < slot_count);
            var slot = &region.slots[slot_index];

            // Precondition: slot must be free before writing a new CALL.
            assert(slot.header.slot_state == .free);

            // New CALL on this slot — clear delivery flag so
            // check_response will deliver the next response.
            self.slot_delivered[slot_index] = false;

            // Write payload to request area.
            @memcpy(slot.request[0..payload_len], message.buffer[0..payload_len]);

            // Extract request_id from CALL frame for response verification.
            assert(payload_len >= 5);
            self.sent_request_ids[slot_index] = std.mem.readInt(u32, slot.request[1..5], .big);

            // Update header (non-atomic — only seq needs ordering).
            // CRC convention (len ++ payload) is defined in shm_layout.
            slot.header.request_len = payload_len;
            slot.header.request_crc = shm_layout.crc_frame(payload_len, &slot.request);
            slot.header.slot_state = .call_written;

            // Increment seq with release ordering — all payload stores
            // are visible before the seq update.
            self.server_seqs[slot_index] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_index], .release);
        }

        /// Check for responses. Called from poll_responses in the
        /// server tick loop — checks if sidecar wrote a new sidecar_seq.
        pub fn check_response(self: *Self, slot_index: u8) void {
            assert(slot_index < slot_count);
            const region = self.region orelse return;
            const slot = &region.slots[slot_index];

            const response_len = self.validate_pending_response(slot, slot_index) orelse return;
            if (!self.verify_response_request_id(slot, slot_index, response_len)) return;

            // Mark as consumed BEFORE the callback — the callback may send
            // a new CALL on this same slot (which clears the flag). Setting
            // after would overwrite the cleared flag.
            //
            // If the callback panics, the slot is left free but with
            // unfinished work — acceptable because a callback panic means
            // the server is crashing anyway (assert failure).
            self.slot_delivered[slot_index] = true;
            slot.header.slot_state = .free;

            if (self.on_frame_fn) |cb| {
                cb(self.context.?, slot_index, slot.response[0..response_len]);
            }
        }

        /// Check gate conditions, bounds, and CRC on the response area.
        /// Returns `response_len` if a new valid response is ready for
        /// delivery, null otherwise. Pure — no state mutation.
        ///
        /// The gate has two complementary layers:
        ///   Seq check (ORDERING) — `sidecar_seq >= server_seq` means a
        ///     new response was written since our last CALL. Low-cost
        ///     atomic load, primary detection mechanism.
        ///   State check (SAFETY) — `slot_state == result_written`
        ///     confirms the sidecar completed the full write sequence
        ///     (data → len → CRC → state → seq). Seq bumped but state
        ///     disagreeing means memory corruption or a broken write
        ///     order — refuse to read either way.
        fn validate_pending_response(
            self: *const Self,
            slot: *const SlotPair,
            slot_index: u8,
        ) ?u32 {
            assert(slot_index < slot_count);
            assert(self.server_seqs.len == slot_count);

            const sidecar_seq = @atomicLoad(u32, &slot.header.sidecar_seq, .acquire);
            if (self.server_seqs[slot_index] == 0) return null;
            if (sidecar_seq < self.server_seqs[slot_index]) return null;
            if (self.slot_delivered[slot_index]) return null;
            if (slot.header.slot_state != .result_written) return null;

            const response_len = slot.header.response_len;
            if (response_len > slot_data_size) {
                log.warn("shm: invalid response_len {d} on slot {d}", .{ response_len, slot_index });
                return null;
            }

            // CRC=0 sentinel: "not yet written" (partial crash). A
            // computed CRC that happens to equal 0 is treated as invalid
            // — one-in-2^32 false-positive rejection, acceptable cost.
            const stored_crc = slot.header.response_crc;
            if (stored_crc == 0) return null;
            if (shm_layout.crc_frame(response_len, &slot.response) != stored_crc) {
                log.warn("shm: CRC mismatch on slot {d}", .{slot_index});
                return null;
            }

            return response_len;
        }

        /// Verify the RESULT's request_id matches what this slot sent.
        /// On mismatch, reset the slot (the original request is lost —
        /// its HTTP client will be closed via sidecar_on_close or
        /// dispatch timeout). Returns true on match.
        ///
        /// RESULT frame layout: [tag:1][request_id:4 BE][flag:1][payload].
        fn verify_response_request_id(
            self: *Self,
            slot: *SlotPair,
            slot_index: u8,
            response_len: u32,
        ) bool {
            assert(slot_index < slot_count);
            assert(response_len <= slot_data_size);

            if (response_len < 5) return true; // too short to carry a request_id

            const resp_request_id = std.mem.readInt(u32, slot.response[1..5], .big);
            if (resp_request_id == self.sent_request_ids[slot_index]) return true;

            log.warn("shm: request_id mismatch on slot {d}: sent {d}, got {d}", .{
                slot_index, self.sent_request_ids[slot_index], resp_request_id,
            });
            self.slot_delivered[slot_index] = true;
            slot.header.slot_state = .free;
            return false;
        }

        /// Poll all slots for new responses. Called from the server
        /// tick loop. Cost: slot_count atomic loads per tick.
        pub fn poll_responses(self: *Self) void {
            comptime assert(slot_count > 0);
            comptime assert(slot_count <= std.math.maxInt(u8));
            for (0..slot_count) |i| {
                self.check_response(@intCast(i));
            }
        }
    };
}

pub const Options = struct {
    slot_count: u8 = 8,
};
