//! Shared memory bus — mmap + io_uring futex transport.
//!
//! Drop-in replacement for MessageBusType when used with the v2 dispatch.
//! Same interface: send_message_to, is_connection_ready, can_send_to,
//! get_message, unref.
//!
//! Layout per slot pair:
//!   [Header 64B][Request frame_max][Response frame_max]
//!
//! Signaling: io_uring FUTEX_WAIT on sidecar_seq. The server submits
//! a futex wait; when the sidecar writes a new seq, the kernel
//! completes the wait. No eventfd, no extra fd, no extra syscalls.
//!
//! CRC covers len_bytes ++ payload_bytes (TB convention — corrupted
//! length produces CRC mismatch, not garbage read).

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const linux = std.os.linux;
const protocol = @import("../protocol.zig");
const Crc32 = std.hash.crc.Crc32;
const IoUring = @import("io.zig").IoUring;

const log = std.log.scoped(.shm_bus);

pub fn SharedMemoryBusType(comptime options: Options) type {
    return struct {
        const Self = @This();
        pub const slot_count = options.slot_count;

        pub const frame_header_size: u32 = 0;

        // =============================================================
        // Shared memory layout — extern struct, comptime-verified
        // =============================================================

        pub const SlotHeader = extern struct {
            server_seq: u32 = 0,
            sidecar_seq: u32 = 0,
            request_len: u32 = 0,
            response_len: u32 = 0,
            request_crc: u32 = 0,
            response_crc: u32 = 0,
            _pad: [40]u8 = [_]u8{0} ** 40,

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
            _pad: [60]u8 = [_]u8{0} ** 60,

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
        uring: ?*IoUring = null,

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
            uring: *IoUring,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            context: *anyopaque,
        ) !void {
            self.on_frame_fn = on_frame_fn;
            self.context = context;
            self.uring = uring;

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

            // Zero the region.
            @memset(@as([*]u8, @ptrCast(self.region.?))[0..@sizeOf(Region)], 0);

            log.info("shm bus: region={d}B, {d} slots, name={s}", .{
                @sizeOf(Region), slot_count, name,
            });
        }

        pub fn deinit(self: *Self) void {
            if (self.region) |r| {
                posix.munmap(@as([*]u8, @ptrCast(r))[0..@sizeOf(Region)]);
                self.region = null;
            }
            if (self.shm_fd >= 0) {
                posix.close(self.shm_fd);
                self.shm_fd = -1;
            }
            // Unlink.
            if (self.shm_name_len > 0) {
                var path_buf: [128]u8 = undefined;
                if (std.fmt.bufPrintZ(&path_buf, "/{s}", .{self.shm_name[0..self.shm_name_len]})) |path| {
                    _ = std.c.shm_unlink(path.ptr);
                } else |_| {}
            }
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

            self.server_seqs[slot_idx] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_idx], .release);

            const epoch_ptr: *u32 = &region.header.epoch;
            _ = @atomicRmw(u32, epoch_ptr, .Add, 1, .release);
            IoUring.futex_wake(@ptrCast(epoch_ptr));
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

            // Increment seq with release ordering — all payload stores
            // are visible before the seq update.
            self.server_seqs[slot_idx] += 1;
            const seq_ptr: *u32 = &slot.header.server_seq;
            @atomicStore(u32, seq_ptr, self.server_seqs[slot_idx], .release);

            // Bump epoch — one atomic counter the sidecar futex-waits on.
            // Release ordering: all slot writes visible before epoch update.
            const epoch_ptr: *u32 = &region.header.epoch;
            _ = @atomicRmw(u32, epoch_ptr, .Add, 1, .release);

            // Wake sidecar via futex on epoch.
            IoUring.futex_wake(@ptrCast(epoch_ptr));
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

            // No request sent yet, stale response, or already delivered.
            if (self.server_seqs[slot_idx] == 0) return;
            if (sidecar_seq < self.server_seqs[slot_idx]) return;
            if (self.slot_delivered[slot_idx]) return;

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

            // Deliver frame to dispatch module.
            if (self.on_frame_fn) |cb| {
                cb(self.context.?, slot_idx, slot.response[0..response_len]);
            }

            // Re-submit futex wait for next response.
            self.submit_futex_wait(slot_idx);
        }

        /// Submit a futex wait on sidecar_seq for the given slot.
        /// The io_uring completion fires when sidecar_seq changes.
        pub fn submit_futex_wait(self: *Self, slot_idx: u8) void {
            const region = self.region orelse return;
            const slot = &region.slots[slot_idx];
            const current_seq = @as(*volatile u32, @ptrCast(&slot.header.sidecar_seq)).*;

            if (self.uring) |ring| {
                _ = ring.submit_futex_wait(
                    @ptrCast(&slot.header.sidecar_seq),
                    current_seq,
                    @ptrCast(self),
                    shm_futex_callback,
                );
            }
        }

        fn shm_futex_callback(ctx: *anyopaque, result: i32) void {
            _ = result;
            const self: *Self = @ptrCast(@alignCast(ctx));
            // Check all slots — the futex could have fired for any.
            for (0..slot_count) |i| {
                self.check_response(@intCast(i));
            }
        }

        /// Submit initial futex waits for all slots. Call after sidecar
        /// connects and is ready.
        pub fn start_watching(self: *Self) void {
            for (0..slot_count) |i| {
                self.submit_futex_wait(@intCast(i));
            }
        }
    };
}

pub const Options = struct {
    slot_count: u8 = 8,
};
