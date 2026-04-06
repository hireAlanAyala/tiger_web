//! Shared memory bus — mmap + eventfd transport for sidecar communication.
//!
//! Drop-in replacement for MessageBusType when used with the v2 dispatch.
//! Same interface: send_message_to, is_connection_ready, can_send_to,
//! get_message, unref. But instead of unix socket framing (CRC + kernel
//! buffer copies), writes directly to a shared memory region and signals
//! via eventfd.
//!
//! Layout per slot pair:
//!   [Header 64B][Request frame_max][Response frame_max]
//! Header contains sequence numbers and lengths for synchronization.
//! Memory ordering: release on write, acquire on read.
//!
//! The server writes to request slots, the sidecar writes to response
//! slots. Each side only writes to its own slots. Sequence numbers
//! prevent torn reads. CRC validates payload integrity.

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const protocol = @import("../protocol.zig");
const Crc32 = std.hash.crc.Crc32;

const log = std.log.scoped(.shm_bus);

pub fn SharedMemoryBusType(comptime options: Options) type {
    return struct {
        const Self = @This();
        const slot_count = options.slot_count;

        pub const frame_header_size: u32 = 0; // No wire framing — payload goes direct.
        pub const Connection = ShmConnection;

        // =============================================================
        // Shared memory layout — extern struct, comptime-verified
        // =============================================================

        pub const SlotHeader = extern struct {
            server_seq: u32 align(1) = 0,
            sidecar_seq: u32 align(1) = 0,
            request_len: u32 align(1) = 0,
            response_len: u32 align(1) = 0,
            request_crc: u32 align(1) = 0,
            response_crc: u32 align(1) = 0,
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

        pub const Region = extern struct {
            slots: [slot_count]SlotPair,

            comptime {
                // Verify total size is bounded and known.
                assert(@sizeOf(Region) == slot_count * @sizeOf(SlotPair));
                assert(@sizeOf(Region) <= 16 * 1024 * 1024); // 16MB max
            }
        };

        // =============================================================
        // Message — compatible with dispatch module's bus interface
        // =============================================================

        pub const Message = struct {
            buffer: [protocol.frame_max]u8 = undefined,
            references: u32 = 1,
            slot_index: u8 = 0,
        };

        // =============================================================
        // Bus state
        // =============================================================

        region: ?*Region = null,
        shm_fd: posix.fd_t = -1,
        eventfd_to_sidecar: posix.fd_t = -1,
        eventfd_from_sidecar: posix.fd_t = -1,

        // Per-slot sequence tracking.
        server_seqs: [slot_count]u32 = [_]u32{0} ** slot_count,

        // Message pool — small, fixed size.
        message_pool: [slot_count * 2]Message = [_]Message{.{}} ** (slot_count * 2),
        next_message: u8 = 0,

        // Connection ready state.
        ready: bool = false,

        // Callback for received frames.
        on_frame_fn: ?*const fn (*anyopaque, u8, []const u8) void = null,
        on_close_fn: ?*const fn (*anyopaque, u8, ShmConnection.CloseReason) void = null,
        context: ?*anyopaque = null,

        // =============================================================
        // Initialization
        // =============================================================

        pub fn init(
            self: *Self,
            shm_name: []const u8,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            on_close_fn: *const fn (*anyopaque, u8, ShmConnection.CloseReason) void,
            context: *anyopaque,
        ) !void {
            self.on_frame_fn = on_frame_fn;
            self.on_close_fn = on_close_fn;
            self.context = context;

            // Create shared memory region.
            var name_buf: [256]u8 = undefined;
            const name_z = std.fmt.bufPrintZ(&name_buf, "/{s}", .{shm_name}) catch return error.NameTooLong;

            // Clean stale region.
            _ = std.c.shm_unlink(name_z.ptr);

            self.shm_fd = std.c.shm_open(
                name_z.ptr,
                @bitCast(@as(u32, std.c.O.CREAT | std.c.O.RDWR | std.c.O.EXCL)),
                0o600,
            );
            if (self.shm_fd < 0) return error.ShmOpenFailed;

            // Size the region.
            posix.ftruncate(self.shm_fd, @sizeOf(Region)) catch return error.FtruncateFailed;

            // Map it.
            const ptr = posix.mmap(
                null,
                @sizeOf(Region),
                posix.PROT.READ | posix.PROT.WRITE,
                .{ .TYPE = .SHARED },
                self.shm_fd,
                0,
            ) catch return error.MmapFailed;
            self.region = @ptrCast(@alignCast(ptr));

            // Zero the region.
            @memset(@as([*]u8, @ptrCast(self.region.?))[0..@sizeOf(Region)], 0);

            // Create eventfds for signaling.
            self.eventfd_to_sidecar = eventfd_create() catch return error.EventfdFailed;
            self.eventfd_from_sidecar = eventfd_create() catch return error.EventfdFailed;

            log.info("shm bus: region={d} bytes, {d} slots, eventfds={d},{d}", .{
                @sizeOf(Region), slot_count, self.eventfd_to_sidecar, self.eventfd_from_sidecar,
            });
        }

        pub fn deinit(self: *Self) void {
            if (self.region) |_| {
                posix.munmap(@ptrCast(@alignCast(self.region.?)), @sizeOf(Region));
                self.region = null;
            }
            if (self.shm_fd >= 0) {
                posix.close(self.shm_fd);
                self.shm_fd = -1;
            }
            if (self.eventfd_to_sidecar >= 0) posix.close(self.eventfd_to_sidecar);
            if (self.eventfd_from_sidecar >= 0) posix.close(self.eventfd_from_sidecar);
        }

        // =============================================================
        // Bus interface — compatible with dispatch module
        // =============================================================

        pub fn is_connection_ready(self: *const Self, _: u8) bool {
            return self.ready;
        }

        pub fn can_send_to(self: *const Self, _: u8) bool {
            return self.region != null;
        }

        pub fn get_message(self: *Self) *Message {
            const idx = self.next_message;
            self.next_message = (self.next_message + 1) % (slot_count * 2);
            self.message_pool[idx].references = 1;
            return &self.message_pool[idx];
        }

        pub fn unref(_: *Self, _: *Message) void {}

        /// Write a CALL frame to shared memory for the given slot.
        pub fn send_message_to(self: *Self, connection_index: u8, message: *Message, payload_len: u32) void {
            const region = self.region orelse return;
            _ = connection_index; // All slots share one sidecar.

            // Find the slot for this message.
            const slot_idx = message.slot_index;
            assert(slot_idx < slot_count);
            var slot = &region.slots[slot_idx];

            // Write payload to request area.
            @memcpy(slot.request[0..payload_len], message.buffer[0..payload_len]);

            // CRC over payload.
            var crc = Crc32.init();
            crc.update(slot.request[0..payload_len]);
            const crc_val = crc.final();

            // Update header: length, CRC, then sequence (release).
            @as(*volatile u32, @ptrCast(&slot.header.request_len)).* = payload_len;
            @as(*volatile u32, @ptrCast(&slot.header.request_crc)).* = crc_val;

            self.server_seqs[slot_idx] += 1;
            std.atomic.fence(.release);
            @as(*volatile u32, @ptrCast(&slot.header.server_seq)).* = self.server_seqs[slot_idx];

            // Signal sidecar.
            eventfd_signal(self.eventfd_to_sidecar);
        }

        /// Check for responses from the sidecar. Called from epoll
        /// callback when eventfd_from_sidecar is readable.
        pub fn poll_responses(self: *Self) void {
            const region = self.region orelse return;

            // Consume eventfd signal.
            eventfd_consume(self.eventfd_from_sidecar);

            // Check each slot for new responses.
            for (&region.slots, 0..) |*slot, i| {
                std.atomic.fence(.acquire);
                const sidecar_seq = @as(*volatile u32, @ptrCast(&slot.header.sidecar_seq)).*;
                const server_seq = self.server_seqs[i];

                if (sidecar_seq >= server_seq and server_seq > 0) {
                    // New response available.
                    const response_len = @as(*volatile u32, @ptrCast(&slot.header.response_len)).*;
                    if (response_len > slot_data_size) continue; // Invalid.

                    // Validate CRC.
                    const stored_crc = @as(*volatile u32, @ptrCast(&slot.header.response_crc)).*;
                    var crc = Crc32.init();
                    crc.update(slot.response[0..response_len]);
                    if (crc.final() != stored_crc) {
                        log.warn("shm: CRC mismatch on slot {d}", .{i});
                        continue;
                    }

                    // Deliver frame.
                    if (self.on_frame_fn) |cb| {
                        cb(self.context.?, @intCast(i), slot.response[0..response_len]);
                    }
                }
            }
        }

        // =============================================================
        // Helpers
        // =============================================================

        fn eventfd_create() !posix.fd_t {
            const fd = std.c.eventfd(0, std.c.EFD.NONBLOCK | std.c.EFD.CLOEXEC);
            if (fd < 0) return error.EventfdFailed;
            return fd;
        }

        fn eventfd_signal(fd: posix.fd_t) void {
            const val: u64 = 1;
            _ = posix.write(fd, std.mem.asBytes(&val)) catch {};
        }

        fn eventfd_consume(fd: posix.fd_t) void {
            var val: u64 = 0;
            _ = posix.read(fd, std.mem.asBytes(&val)) catch {};
        }
    };
}

pub const Options = struct {
    slot_count: u8 = 8,
};

pub const ShmConnection = struct {
    pub const CloseReason = enum { eof, recv_error, shutdown };
};
