//! Shared memory bus — mmap + futex wake transport.
//!
//! Drop-in replacement for MessageBusType when used with the v2 dispatch.
//! Same interface: send_message_to, is_connection_ready, can_send_to,
//! get_message, unref.
//!
//! Layout per slot pair:
//!   [Header 64B][Request frame_max][Response frame_max]
//!
//! Signaling: raw futex WAKE on epoch (fire-and-forget syscall).
//! Server detects responses by polling sidecar_seq in the tick loop.
//! No io_uring dependency — same raw futex as WorkerDispatch.
//!
//! CRC covers len_bytes ++ payload_bytes (TB convention — corrupted
//! length produces CRC mismatch, not garbage read).

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;
const protocol = @import("../protocol.zig");
const Crc32 = std.hash.crc.Crc32;
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

            comptime {
                assert(@sizeOf(SlotHeader) == 64);
            }
        };

        const slot_data_size = protocol.frame_max;

        pub const SlotPair = extern struct {
            header: SlotHeader,
            request: [slot_data_size]u8,
            response: [slot_data_size]u8,
        };

        pub const RegionHeader = extern struct {
            /// Epoch counter — bumped after every CALL write.
            /// Sidecar futex-waits on this address. One futex for
            /// all slots instead of per-slot futex.
            epoch: u32 = 0,
            /// Number of slot pairs in this region. Sidecar reads this
            /// instead of hardcoding the slot count.
            slot_count: u16 = slot_count,
            /// Reserved for alignment.
            _reserved: u16 = 0,
            /// Maximum frame payload size (bytes). Sidecar reads this
            /// instead of hardcoding FRAME_MAX.
            frame_max: u32 = slot_data_size,
            /// Sidecar sets to 1 when actively polling (setImmediate loop).
            /// Server skips futex_wake when this is set — the sidecar will
            /// see the new CALL within one poll cycle without a syscall.
            /// Set to 0 when sidecar enters futex_wait (idle mode).
            sidecar_polling: u32 = 0,
            _pad: [48]u8 = [_]u8{0} ** 48,

            comptime {
                assert(@sizeOf(RegionHeader) == 64);
            }
        };

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

            // Store name for sidecar to open.
            assert(name.len < self.shm_name.len);
            @memcpy(self.shm_name[0..name.len], name);
            self.shm_name_len = @intCast(name.len);

            // Build null-terminated path: "/name"
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrintZ(&path_buf, "/{s}", .{name}) catch return error.NameTooLong;

            // Clean stale region.
            _ = std.c.shm_unlink(path.ptr);

            // Create shared memory.
            const fd = std.c.shm_open(
                path.ptr,
                @bitCast(linux.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }),
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
        }

        /// Create a test-only instance backed by anonymous mmap (no /dev/shm).
        /// Same layout as create() but no filesystem involvement.
        pub fn create_test(
            self: *Self,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            context: *anyopaque,
        ) void {
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
            self.next_message = (self.next_message + 1) % (slot_count * 2);
            pool[idx].references = 1;
            return &pool[idx];
        }

        pub fn unref(_: *Self, _: *Message) void {}

        /// Get direct write access to a slot's request buffer.
        /// Caller writes the CALL frame directly, then calls finalize_slot_send.
        /// Eliminates intermediate buffer copies.
        pub fn get_slot_request_buf(self: *Self, slot_idx: u8) ?[]u8 {
            const region = self.region orelse return null;
            assert(slot_idx < slot_count);
            self.slot_delivered[slot_idx] = false;
            return &region.slots[slot_idx].request;
        }

        /// Finalize a direct-write send: compute CRC, bump seq, wake sidecar.
        /// Call after writing payload into the buffer returned by get_slot_request_buf.
        pub fn finalize_slot_send(self: *Self, slot_idx: u8, payload_len: u32) void {
            const region = self.region orelse return;
            assert(slot_idx < slot_count);
            const slot = &region.slots[slot_idx];

            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&payload_len));
            crc.update(slot.request[0..payload_len]);

            slot.header.request_len = payload_len;
            slot.header.request_crc = crc.final();
            slot.header.slot_state = .call_written;

            self.server_seqs[slot_idx] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_idx], .release);

            const epoch_ptr: *u32 = &region.header.epoch;
            _ = @atomicRmw(u32, epoch_ptr, .Add, 1, .release);

            // Skip futex_wake when sidecar is actively polling — it will
            // see the new epoch within one poll cycle (microseconds).
            // Only wake when sidecar is in futex_wait (idle mode).
            if (@atomicLoad(u32, &region.header.sidecar_polling, .acquire) == 0) {
                futex_wake(epoch_ptr);
            }
        }

        /// Write a CALL payload to shared memory for the given slot.
        /// The slot is determined by message.slot_index — pinned 1:1
        /// to dispatch entries. No round-robin, no collisions.
        pub fn send_message_to(self: *Self, _: u8, message: *Message, payload_len: u32) void {
            const region = self.region orelse return;
            const slot_idx = message.slot_index;
            assert(slot_idx < slot_count);
            var slot = &region.slots[slot_idx];

            // New CALL on this slot — clear delivery flag so
            // check_response will deliver the next response.
            self.slot_delivered[slot_idx] = false;

            // Write payload to request area.
            @memcpy(slot.request[0..payload_len], message.buffer[0..payload_len]);

            // CRC covers len_bytes ++ payload_bytes (TB convention).
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&payload_len));
            crc.update(slot.request[0..payload_len]);

            // Update header (non-atomic — only seq needs ordering).
            slot.header.request_len = payload_len;
            slot.header.request_crc = crc.final();
            slot.header.slot_state = .call_written;

            // Increment seq with release ordering — all payload stores
            // are visible before the seq update.
            self.server_seqs[slot_idx] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_idx], .release);

            // Bump epoch — one atomic counter the sidecar futex-waits on.
            // Release ordering: all slot writes visible before epoch update.
            const epoch_ptr: *u32 = &region.header.epoch;
            _ = @atomicRmw(u32, epoch_ptr, .Add, 1, .release);

            // Skip futex_wake when sidecar is actively polling.
            if (@atomicLoad(u32, &region.header.sidecar_polling, .acquire) == 0) {
                futex_wake(epoch_ptr);
            }
        }

        /// Check for responses. Called from the io_uring futex_wait
        /// completion callback — the sidecar wrote a new sidecar_seq.
        pub fn check_response(self: *Self, slot_idx: u8) void {
            const region = self.region orelse return;
            assert(slot_idx < slot_count);
            const slot = &region.slots[slot_idx];

            // Acquire load on sidecar_seq — all response payload reads
            // are ordered after this load.
            const sidecar_seq_ptr: *u32 = &slot.header.sidecar_seq;
            const sidecar_seq = @atomicLoad(u32, sidecar_seq_ptr, .acquire);

            // Two complementary checks — different purposes:
            //
            // Seq check (ORDERING): sidecar_seq >= server_seq means a new
            // response has been written since our last CALL. This is the
            // primary detection mechanism — low-cost atomic load per tick.
            //
            // State check (SAFETY): slot_state == result_written confirms
            // the sidecar completed the full write sequence (data → len →
            // CRC → state → seq). If seq is bumped but state disagrees,
            // either: memory corruption, or a code bug broke the write order.
            // In both cases, refusing to read is the safe choice.
            if (self.server_seqs[slot_idx] == 0) return;
            if (sidecar_seq < self.server_seqs[slot_idx]) return;
            if (self.slot_delivered[slot_idx]) return;
            if (slot.header.slot_state != .result_written) return;

            const response_len = slot.header.response_len;
            if (response_len > slot_data_size) {
                log.warn("shm: invalid response_len {d} on slot {d}", .{ response_len, slot_idx });
                return;
            }

            // Validate CRC (len ++ payload).
            const stored_crc = slot.header.response_crc;
            var crc = Crc32.init();
            crc.update(std.mem.asBytes(&response_len));
            crc.update(slot.response[0..response_len]);
            if (crc.final() != stored_crc) {
                log.warn("shm: CRC mismatch on slot {d}", .{slot_idx});
                return;
            }

            // Mark as consumed BEFORE the callback — the callback may
            // send a new CALL on this same slot (clearing the flag).
            // Setting after would overwrite the cleared flag.
            self.slot_delivered[slot_idx] = true;
            slot.header.slot_state = .free;

            // Deliver frame to dispatch module.
            if (self.on_frame_fn) |cb| {
                cb(self.context.?, slot_idx, slot.response[0..response_len]);
            }
        }

        /// Poll all slots for new responses. Called from the server
        /// tick loop. Cost: slot_count atomic loads per tick.
        pub fn poll_responses(self: *Self) void {
            for (0..slot_count) |i| {
                self.check_response(@intCast(i));
            }
        }
    };
}

/// Raw futex WAKE syscall — fire-and-forget, no io_uring dependency.
/// Same as WorkerDispatch.futex_wake.
fn futex_wake(ptr: *const u32) void {
    _ = linux.futex_wake(
        @ptrCast(ptr),
        linux.FUTEX.WAKE,
        1,
    );
}

pub const Options = struct {
    slot_count: u8 = 8,
};
