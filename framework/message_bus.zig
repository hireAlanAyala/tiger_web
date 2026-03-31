//! Message bus — framed IO transport for socket communication.
//!
//! Two layers, matching TigerBeetle's architecture:
//!
//! - **ConnectionType** — transport primitive. Recv loop, send queue,
//!   frame accumulation, CRC-32 validation, backpressure, 3-phase
//!   termination. Operates on an fd it's given. Knows nothing about
//!   how the fd was obtained.
//!
//! - **MessageBusType** — lifecycle manager. Listen, accept, tick.
//!   Owns one Connection. Hands the accepted fd to the Connection.
//!
//! Protocol logic (CALL/RESULT, QUERY) lives in the consumer, not
//! in the transport.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const stdx = @import("stdx");
const maybe = stdx.maybe;
const RingBufferType = stdx.RingBufferType;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.message_bus));

/// Transport primitive. Recv loop, send queue, frame accumulation,
/// CRC-32 validation, backpressure, 3-phase termination.
///
/// Parameterized at comptime so each consumer states its bounds:
///   const SidecarConn = ConnectionType(IO, .{ .send_queue_max = 2 });
///   const WorkerConn = ConnectionType(IO, .{ .send_queue_max = 4 });
pub fn ConnectionType(comptime IO: type, comptime options: Options) type {
    return struct {
        const Self = @This();

        // --- Frame format ---
        // [payload_len: u32 BE][crc32: u32][payload bytes]
        // CRC covers len_bytes ++ payload_bytes (not just payload).
        const frame_header_size: u32 = 8; // 4 len + 4 crc32
        const frame_max: u32 = options.frame_max;
        const recv_buf_max: u32 = frame_max + frame_header_size;
        const send_buf_max: u32 = frame_max + frame_header_size;
        const send_queue_max: u32 = options.send_queue_max;

        comptime {
            assert(frame_header_size == 8);
            assert(recv_buf_max <= std.math.maxInt(u32));
            assert(send_queue_max >= 2); // CALL + QUERY_RESULT
            assert(recv_buf_max == frame_max + frame_header_size);
        }

        pub const State = enum {
            /// Not initialized or closed after terminate.
            closed,
            /// Connected. Recv/send loops active.
            connected,
            /// Terminating. Waiting for in-flight IO to complete.
            /// No new operations. Callbacks call terminate_join().
            terminating,
        };

        io: *IO,
        state: State,
        fd: IO.fd_t,

        // --- Recv state ---
        recv_buf: [recv_buf_max]u8,
        recv_pos: u32, // bytes received (end of data)
        advance_pos: u32, // bytes validated (checksum-checked)
        process_pos: u32, // bytes consumed by on_frame_fn
        recv_completion: IO.Completion,
        recv_submitted: bool,
        recv_suspended: bool,

        // --- Send state ---
        // Bounded queue of outgoing frames. Uses TB's RingBufferType
        // (ported from stdx/ring_buffer.zig). Each entry holds the
        // framed data and its length. Pre-allocated, no dynamic alloc.
        send_queue: SendQueue,
        send_pos: u32, // bytes sent of current head frame
        send_completion: IO.Completion,
        send_submitted: bool,

        // --- Consumer callback ---
        // Called with complete, CRC-validated frame data.
        // May call send_frame() re-entrantly (QUERY sub-protocol).
        // May call terminate() (protocol error).
        // Frame data is valid only during this callback — consumer
        // must copy via copy_state() if data is needed later.
        on_frame_fn: *const fn (context: *anyopaque, frame: []const u8) void,
        context: *anyopaque,

        pub const SendEntry = struct { buf: [send_buf_max]u8 = undefined, len: u32 = 0 };
        pub const SendQueue = RingBufferType(SendEntry, .{ .array = send_queue_max });

        // =====================================================================
        // Public API
        // =====================================================================

        /// Initialize with an fd. Zeros all state, kicks off recv loop.
        /// Called by MessageBus after accept, or directly in tests.
        pub fn init(self: *Self, io: *IO, fd: IO.fd_t, context: *anyopaque, on_frame_fn: *const fn (*anyopaque, []const u8) void) void {
            assert(self.state == .closed);
            defer self.invariants();
            self.io = io;
            self.fd = fd;
            self.context = context;
            self.on_frame_fn = on_frame_fn;
            // Zero all mutable state — Connection may be reused after
            // terminate_close. Don't assume fields are zero-initialized.
            self.recv_pos = 0;
            self.advance_pos = 0;
            self.process_pos = 0;
            self.recv_submitted = false;
            self.recv_suspended = false;
            self.send_queue.clear();
            self.send_pos = 0;
            self.send_submitted = false;
            self.state = .connected;
            self.submit_recv();
        }

        /// Queue a frame for sending. May be called re-entrantly from
        /// on_frame_fn (QUERY sub-protocol). The frame is copied into
        /// a send queue slot, CRC-32 is computed, and the send loop
        /// is kicked if not already running.
        pub fn send_frame(self: *Self, data: []const u8) void {
            // Silently drop if terminating (TB pattern). This happens
            // when on_frame_fn calls send_frame re-entrantly and a
            // previous send_frame in the same callback triggered
            // terminate via send_now returning 0.
            if (self.state != .connected) return;
            defer self.invariants();
            assert(data.len <= frame_max);
            assert(!self.send_queue.full()); // bounded

            // Get pointer to next queue slot and build frame in-place.
            const entry = self.send_queue.next_tail_ptr().?;
            const len: u32 = @intCast(data.len);

            // Length prefix (big-endian).
            std.mem.writeInt(u32, entry.buf[0..4], len, .big);

            // Payload.
            @memcpy(entry.buf[8..][0..data.len], data);

            // CRC-32 covers len_bytes ++ payload_bytes (little-endian).
            var crc = Crc32.init();
            crc.update(entry.buf[0..4]); // length prefix
            crc.update(entry.buf[8..][0..data.len]); // payload
            std.mem.writeInt(u32, entry.buf[4..8], crc.final(), .little);

            entry.len = frame_header_size + len;
            self.send_queue.advance_tail();

            // Kick the send loop if not already running.
            if (!self.send_submitted) self.do_send();
        }

        /// Stop submitting io.recv — consumer needs time to process.
        /// Used by QUERY sub-protocol: suspend before sending
        /// QUERY_RESULT, resume after.
        pub fn suspend_recv(self: *Self) void {
            assert(self.state == .connected);
            assert(!self.recv_suspended);
            defer self.invariants();
            self.recv_suspended = true;
        }

        /// Resume receiving after suspend. Drains any buffered data
        /// first, then re-submits io.recv.
        pub fn resume_recv(self: *Self) void {
            assert(self.state == .connected);
            assert(self.recv_suspended);
            defer self.invariants();
            self.recv_suspended = false;
            self.try_drain_recv();
        }

        /// Initiate 3-phase termination (TB pattern).
        ///
        /// **This is asynchronous.** State transitions to `.terminating`,
        /// not `.closed`. The connection reaches `.closed` only after all
        /// in-flight IO callbacks have fired and called `terminate_join`.
        /// Callers must not assume `.closed` after this returns.
        ///
        /// .shutdown: call posix.shutdown (signal peer, e.g. on error)
        /// .no_shutdown: skip shutdown (peer already closed, orderly)
        pub fn terminate(self: *Self, how: enum { shutdown, no_shutdown }) void {
            if (self.state == .terminating) return;
            assert(self.state != .closed);
            defer self.invariants();
            if (how == .shutdown) {
                self.io.shutdown(self.fd, .both);
            }
            self.state = .terminating;
            self.terminate_join();
        }

        // =====================================================================
        // Recv internals
        // =====================================================================

        fn submit_recv(self: *Self) void {
            assert(self.state == .connected);
            assert(!self.recv_submitted);
            assert(!self.recv_suspended);
            assert(self.recv_pos < recv_buf_max); // buffer has room
            self.recv_submitted = true;
            self.io.recv(
                self.fd,
                self.recv_buf[self.recv_pos..],
                &self.recv_completion,
                @ptrCast(self),
                recv_callback,
            );
        }

        fn recv_callback(ctx: *anyopaque, result: i32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.invariants();
            self.recv_submitted = false;

            if (self.state == .terminating) {
                self.terminate_join();
                return;
            }
            assert(self.state == .connected);

            if (result < 0) {
                self.terminate(.shutdown);
                return;
            }
            if (result == 0) {
                self.terminate(.no_shutdown);
                return;
            }

            const bytes: u32 = @intCast(result);
            self.recv_pos += bytes;
            assert(self.recv_pos <= recv_buf_max);

            // Buffer full with incomplete frame — peer is stuck or malicious.
            if (self.recv_pos == recv_buf_max and self.advance_pos < self.recv_pos) {
                self.terminate(.shutdown);
                return;
            }

            self.advance();
            if (self.state != .connected) return; // advance() may have terminated
            self.try_drain_recv();
        }

        /// Validate as many complete frames as possible.
        /// Called after recv_callback (new bytes) and idempotent on
        /// re-entry (no new bytes → exits immediately).
        fn advance(self: *Self) void {
            while (true) {
                const frame_start = self.advance_pos;

                // Stage 1: need 4 bytes for length prefix.
                if (self.recv_pos - frame_start < 4) return;
                const len = std.mem.readInt(u32, self.recv_buf[frame_start..][0..4], .big);
                if (len > frame_max) {
                    self.terminate(.shutdown);
                    return;
                }

                // Stage 2: need 4 checksum + len payload bytes.
                const total = frame_header_size + len;
                if (self.recv_pos - frame_start < total) return;

                // Validate CRC-32 (covers len + payload, stored as little-endian).
                assert(frame_start + total <= recv_buf_max);
                const stored_crc = std.mem.readInt(u32, self.recv_buf[frame_start + 4 ..][0..4], .little);
                var crc = Crc32.init();
                crc.update(self.recv_buf[frame_start..][0..4]); // len bytes
                crc.update(self.recv_buf[frame_start + 8 ..][0..total - 8]); // payload
                if (crc.final() != stored_crc) {
                    self.terminate(.shutdown);
                    return;
                }

                self.advance_pos = frame_start + total;
                // Loop to validate next frame if bytes are available.
            }
        }

        /// Deliver validated, unconsumed frames to the consumer.
        /// Compacts the recv buffer once after all frames are drained.
        fn try_drain_recv(self: *Self) void {
            while (self.advance_pos > self.process_pos) {
                const len = std.mem.readInt(u32, self.recv_buf[self.process_pos..][0..4], .big);
                const frame = self.recv_buf[self.process_pos + 8 ..][0..len];

                // Advance process_pos before callback — frame data remains
                // valid until compaction (which happens after the loop).
                self.process_pos += frame_header_size + len;

                self.on_frame_fn(self.context, frame);

                // on_frame_fn may have called terminate() or suspend_recv().
                maybe(self.state == .terminating);
                if (self.state != .connected) return;
                if (self.recv_suspended) return;
            }

            // All frames consumed. Compact: move unvalidated tail to front.
            if (self.process_pos > 0) {
                const remaining = self.recv_pos - self.process_pos;
                if (remaining > 0) {
                    stdx.copy_left(.exact, u8, self.recv_buf[0..remaining], self.recv_buf[self.process_pos..][0..remaining]);
                }
                self.recv_pos = remaining;
                self.advance_pos = 0;
                self.process_pos = 0;
            }

            if (!self.recv_suspended and self.state == .connected) {
                self.submit_recv();
            }
        }

        // =====================================================================
        // Send internals
        // =====================================================================

        /// Top-level send loop. Try send_now fast path, then async.
        fn do_send(self: *Self) void {
            assert(self.state == .connected);
            self.send_now();
            if (self.state != .connected) return; // send_now may have terminated
            if (self.send_queue.empty()) return; // all drained
            self.submit_send();
        }

        /// Non-blocking send via IO layer. Drains as many queued frames
        /// as the kernel buffer accepts without blocking.
        fn send_now(self: *Self) void {
            while (self.send_queue.head_ptr()) |entry| {
                const buf = entry.buf[0..entry.len];

                while (self.send_pos < entry.len) {
                    // send_now returns null for WouldBlock AND errors.
                    // On null, fall back to async send which handles
                    // errors via the full error union in send_callback.
                    const n = self.io.send_now(self.fd, buf[self.send_pos..]) orelse return;
                    self.send_pos += @intCast(n);
                }

                // Frame fully sent. Advance head (don't pop — avoids
                // copying 256KB SendEntry by value).
                self.send_queue.advance_head();
                self.send_pos = 0;
            }
        }

        fn submit_send(self: *Self) void {
            assert(!self.send_submitted);
            assert(!self.send_queue.empty());
            const entry = self.send_queue.head_ptr().?;
            self.send_submitted = true;
            self.io.send(
                self.fd,
                entry.buf[self.send_pos..entry.len],
                &self.send_completion,
                @ptrCast(self),
                send_callback,
            );
        }

        fn send_callback(ctx: *anyopaque, result: i32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            defer self.invariants();
            self.send_submitted = false;

            if (self.state == .terminating) {
                self.terminate_join();
                return;
            }
            assert(self.state == .connected);

            if (result <= 0) {
                self.terminate(.no_shutdown);
                return;
            }

            self.send_pos += @intCast(result);
            const entry = self.send_queue.head_ptr().?;
            assert(self.send_pos <= entry.len);
            if (self.send_pos == entry.len) {
                self.send_queue.advance_head();
                self.send_pos = 0;
            }

            self.do_send();
        }

        // =====================================================================
        // Termination (3-phase, TB pattern)
        // =====================================================================

        fn terminate_join(self: *Self) void {
            assert(self.state == .terminating);
            if (self.recv_submitted) return; // callback will re-call us
            if (self.send_submitted) return; // callback will re-call us
            self.terminate_close();
        }

        fn terminate_close(self: *Self) void {
            assert(self.state == .terminating);
            assert(!self.recv_submitted);
            assert(!self.send_submitted);
            defer self.invariants();

            // Set both submitted flags TRUE to prevent terminate_join
            // re-entry during close (TB pattern).
            self.recv_submitted = true;
            self.send_submitted = true;

            // Drain send queue.
            self.send_queue.clear();

            self.io.close(self.fd);

            // Reset all state.
            self.fd = -1;
            self.recv_pos = 0;
            self.advance_pos = 0;
            self.process_pos = 0;
            self.recv_submitted = false;
            self.send_submitted = false;
            self.recv_suspended = false;
            self.send_pos = 0;
            self.state = .closed;
        }

        // =====================================================================
        // Invariants
        // =====================================================================

        pub fn invariants(self: *const Self) void {
            // Position chain.
            assert(self.process_pos <= self.advance_pos);
            assert(self.advance_pos <= self.recv_pos);
            assert(self.recv_pos <= recv_buf_max);

            // Send queue bounds.
            assert(self.send_queue.count <= send_queue_max);
            if (!self.send_queue.empty()) {
                assert(self.send_pos <= self.send_queue.head_ptr_const().?.len);
            } else {
                assert(self.send_pos == 0);
            }

            // Submitted guards.
            if (self.recv_submitted) assert(self.state == .connected or self.state == .terminating);
            if (self.send_submitted) {
                assert(self.state == .connected or self.state == .terminating);
                assert(!self.send_queue.empty());
            }

            // State consistency.
            switch (self.state) {
                .closed => {
                    assert(self.fd == -1);
                    assert(!self.recv_submitted);
                    assert(!self.send_submitted);
                    assert(self.recv_pos == 0);
                    assert(self.advance_pos == 0);
                    assert(self.process_pos == 0);
                    assert(self.send_queue.empty());
                },
                .connected => assert(self.fd != -1),
                .terminating => assert(self.fd != -1),
            }

            // Suspension consistency.
            if (self.recv_suspended) assert(!self.recv_submitted);
        }
    };
}

pub const Options = struct {
    /// Max queued outgoing frames. Sidecar: 2 (serial).
    /// Worker: 4 (concurrent dispatch). Must be >= 2 for
    /// CALL + QUERY_RESULT to coexist.
    send_queue_max: u32 = 4,
    /// Max frame payload size. Consumer sets this to match their
    /// protocol's frame_max. No default — must be explicit.
    frame_max: u32,
};

/// Lifecycle manager. Owns one Connection. Handles listen, accept,
/// reconnect-on-disconnect. The Connection doesn't know it exists.
///
/// Parameterized at comptime so each consumer declares its bounds:
///   const SidecarBus = MessageBusType(IO, .{ .send_queue_max = 2 });
pub fn MessageBusType(comptime IO: type, comptime options: Options) type {
    const Connection = ConnectionType(IO, options);

    return struct {
        const Self = @This();

        io: *IO,
        connection: Connection,

        // Listen/accept — one connection only.
        listen_fd: IO.fd_t,
        accept_completion: IO.Completion,
        accept_pending: bool,

        // Consumer callback — stored here, passed to connection on init.
        on_frame_fn: *const fn (*anyopaque, []const u8) void,
        context: *anyopaque,

        pub fn init_listener(self: *Self, io: *IO, path: []const u8, context: *anyopaque, on_frame_fn: *const fn (*anyopaque, []const u8) void) void {
            self.io = io;
            self.listen_fd = -1; // Set before listen() — if listen fails, tick_accept guards on this.
            self.connection = .{
                .io = io,
                .state = .closed,
                .fd = -1,
                .recv_buf = undefined,
                .recv_pos = 0,
                .advance_pos = 0,
                .process_pos = 0,
                .recv_completion = .{},
                .recv_submitted = false,
                .recv_suspended = false,
                .send_queue = Connection.SendQueue.init(),
                .send_pos = 0,
                .send_completion = .{},
                .send_submitted = false,
                .on_frame_fn = on_frame_fn,
                .context = context,
            };
            self.accept_completion = .{};
            self.accept_pending = false;
            self.on_frame_fn = on_frame_fn;
            self.context = context;

            self.listen(path);
        }

        fn listen(self: *Self, path: []const u8) void {
            assert(self.connection.state == .closed);
            assert(path.len > 0);
            assert(path.len < 108); // sockaddr_un.path max

            // Unlink stale socket file.
            var unlink_path: [108]u8 = undefined;
            @memcpy(unlink_path[0..path.len], path);
            unlink_path[path.len] = 0;
            posix.unlinkZ(@ptrCast(unlink_path[0 .. path.len + 1])) catch {};

            const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0) catch |err| {
                log.warn("socket: {}", .{err});
                return;
            };

            var addr: posix.sockaddr.un = .{ .path = undefined };
            @memcpy(addr.path[0..path.len], path);
            addr.path[path.len] = 0;

            posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| {
                log.warn("bind: {}", .{err});
                posix.close(fd);
                return;
            };

            posix.listen(fd, 1) catch |err| {
                log.warn("listen: {}", .{err});
                posix.close(fd);
                return;
            };

            self.listen_fd = fd;
            log.info("listening on {s}", .{path});
        }

        /// Called every tick. Submits accept if connection is closed
        /// and no accept is in-flight.
        pub fn tick_accept(self: *Self) void {
            if (self.listen_fd == -1) return; // listen() failed
            if (self.connection.state != .closed) return;
            if (self.accept_pending) return;
            self.accept_pending = true;
            self.io.accept(
                self.listen_fd,
                &self.accept_completion,
                @ptrCast(self),
                accept_callback,
            );
        }

        fn accept_callback(ctx: *anyopaque, result: i32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.accept_pending = false;

            if (result < 0) return; // try again next tick

            const accepted_fd: IO.fd_t = result;

            // Set SO_SNDBUF to hold the full send queue.
            const sndbuf_size: c_int = @intCast(Connection.send_queue_max * Connection.send_buf_max);
            posix.setsockopt(
                accepted_fd,
                posix.SOL.SOCKET,
                posix.SO.SNDBUF,
                &std.mem.toBytes(sndbuf_size),
            ) catch {};

            log.info("accepted fd={d}", .{accepted_fd});
            self.connection.init(self.io, accepted_fd, self.context, self.on_frame_fn);
        }

        // --- Delegation to connection ---

        pub fn send_frame(self: *Self, data: []const u8) void {
            self.connection.send_frame(data);
        }

        pub fn suspend_recv(self: *Self) void {
            self.connection.suspend_recv();
        }

        pub fn resume_recv(self: *Self) void {
            self.connection.resume_recv();
        }
    };
}

// =========================================================================
// Tests
// =========================================================================

const testing = std.testing;

fn test_socketpair() [2]posix.fd_t {
    var fds: [2]posix.fd_t = undefined;
    const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK, 0, &fds);
    assert(rc == 0);
    return fds;
}

/// Build a wire frame (len + crc + payload) into buf. Returns the framed slice.
fn test_build_frame(buf: []u8, payload: []const u8) []const u8 {
    assert(payload.len <= 256 * 1024); // frame_max for tests
    const len: u32 = @intCast(payload.len);
    const total = 8 + payload.len;
    assert(total <= buf.len);

    std.mem.writeInt(u32, buf[0..4], len, .big);
    @memcpy(buf[8..][0..payload.len], payload);

    var crc = Crc32.init();
    crc.update(buf[0..4]);
    crc.update(buf[8..][0..payload.len]);
    std.mem.writeInt(u32, buf[4..8], crc.final(), .little);

    return buf[0..total];
}

/// Minimal IO that completes operations synchronously for unit tests.
/// Uses real unix sockets (socketpair) — send/recv are real syscalls.
/// send_now uses MSG.DONTWAIT on the real fd.
///
/// TODO: Delete after Phase 3 (FuzzIO). See plan: "After Phase 3:
/// delete TestIO from message_bus.zig".
const TestIO = struct {
    pub const fd_t = posix.fd_t;
    pub const Completion = struct {
        fd: fd_t = 0,
        operation: Op = .none,
        context: *anyopaque = undefined,
        callback: *const fn (*anyopaque, i32) void = undefined,
        buffer: ?[]u8 = null,
        buffer_const: ?[]const u8 = null,

        const Op = enum { none, accept, recv, send, readable };
    };

    pub fn recv(_: *TestIO, fd: fd_t, buffer: []u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        completion.* = .{ .fd = fd, .operation = .recv, .context = context, .callback = callback, .buffer = buffer };
    }

    pub fn send(_: *TestIO, fd: fd_t, buffer: []const u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        completion.* = .{ .fd = fd, .operation = .send, .context = context, .callback = callback, .buffer_const = buffer };
    }

    pub fn send_now(_: *TestIO, fd: fd_t, buffer: []const u8) ?usize {
        const result = posix.send(fd, buffer, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL);
        if (result) |bytes| return bytes else |_| return null;
    }

    pub fn accept(_: *TestIO, _: fd_t, _: *Completion, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}

    pub fn shutdown(_: *TestIO, fd: fd_t, how: posix.ShutdownHow) void {
        posix.shutdown(fd, how) catch {};
    }

    pub fn close(_: *TestIO, fd: fd_t) void {
        posix.close(fd);
    }

    /// Drive one pending completion by doing the actual syscall.
    fn tick(completion: *Completion) void {
        const op = completion.operation;
        if (op == .none) return;
        completion.operation = .none;

        switch (op) {
            .recv => {
                const buf = completion.buffer.?;
                const result = posix.recv(completion.fd, buf, posix.MSG.DONTWAIT);
                const n: i32 = if (result) |bytes| @intCast(bytes) else |_| -1;
                completion.callback(completion.context, n);
            },
            .send => {
                const buf = completion.buffer_const.?;
                const result = posix.send(completion.fd, buf, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL);
                const n: i32 = if (result) |bytes| @intCast(bytes) else |_| -1;
                completion.callback(completion.context, n);
            },
            else => {},
        }
    }
};

const TestConnection = ConnectionType(TestIO, .{ .send_queue_max = 4, .frame_max = 256 * 1024 });

/// Test context that records delivered frames.
const TestContext = struct {
    frames: [16][]const u8,
    frame_bufs: [16][1024]u8,
    frame_count: u32,
    conn: *TestConnection,

    fn init(conn: *TestConnection) TestContext {
        return .{
            .frames = undefined,
            .frame_bufs = undefined,
            .frame_count = 0,
            .conn = conn,
        };
    }

    fn on_frame(ctx_ptr: *anyopaque, frame: []const u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx_ptr));
        assert(self.frame_count < 16);
        const i = self.frame_count;
        @memcpy(self.frame_bufs[i][0..frame.len], frame);
        self.frames[i] = self.frame_bufs[i][0..frame.len];
        self.frame_count += 1;
    }
};

test "Connection: send and receive a frame" {
    var io = TestIO{};
    const pair = test_socketpair();
    const server_fd = pair[0];
    const client_fd = pair[1];

    var conn: TestConnection = undefined;
    conn.state = .closed;
    var ctx = TestContext.init(&conn);
    conn.init(&io, server_fd, @ptrCast(&ctx), TestContext.on_frame);

    // Write a frame from the "client" side.
    const payload = "hello, message bus!";
    var frame_buf: [1024]u8 = undefined;
    const frame = test_build_frame(&frame_buf, payload);
    const written = posix.send(client_fd, frame, 0) catch unreachable;
    assert(written == frame.len);

    // Drive the recv completion — the Connection has a pending recv.
    TestIO.tick(&conn.recv_completion);

    // The frame should have been delivered.
    try testing.expectEqual(@as(u32, 1), ctx.frame_count);
    try testing.expectEqualSlices(u8, payload, ctx.frames[0]);

    conn.invariants();

    // Close the client fd to trigger orderly shutdown on next recv tick.
    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: send queue delivers multiple frames in order" {
    var io = TestIO{};
    const pair = test_socketpair();
    const server_fd = pair[0];
    const client_fd = pair[1];
    defer posix.close(client_fd);

    var conn: TestConnection = undefined;
    conn.state = .closed;
    var ctx = TestContext.init(&conn);
    conn.init(&io, server_fd, @ptrCast(&ctx), TestContext.on_frame);

    // Queue 3 frames.
    conn.send_frame("frame-one");
    conn.send_frame("frame-two");
    conn.send_frame("frame-three");

    // Read all data from client side and verify frames arrive in order.
    var read_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    for (0..10) |_| {
        const n = posix.recv(client_fd, read_buf[total_read..], posix.MSG.DONTWAIT) catch break;
        if (n == 0) break;
        total_read += n;
    }

    // Parse received frames — each is [len:4][crc:4][payload].
    var pos: usize = 0;
    var frame_count: u32 = 0;
    var received_payloads: [4][]const u8 = undefined;
    while (pos + 8 <= total_read) {
        const len = std.mem.readInt(u32, read_buf[pos..][0..4], .big);
        const payload_data = read_buf[pos + 8 ..][0..len];
        received_payloads[frame_count] = payload_data;
        frame_count += 1;
        pos += 8 + len;
    }

    try testing.expectEqual(@as(u32, 3), frame_count);
    try testing.expectEqualSlices(u8, "frame-one", received_payloads[0]);
    try testing.expectEqualSlices(u8, "frame-two", received_payloads[1]);
    try testing.expectEqualSlices(u8, "frame-three", received_payloads[2]);

    conn.invariants();
    conn.terminate(.no_shutdown);
}

test "Connection: CRC mismatch terminates" {
    var io = TestIO{};
    const pair = test_socketpair();
    const server_fd = pair[0];
    const client_fd = pair[1];
    defer posix.close(client_fd);

    var conn: TestConnection = undefined;
    conn.state = .closed;
    var ctx = TestContext.init(&conn);
    conn.init(&io, server_fd, @ptrCast(&ctx), TestContext.on_frame);

    // Build a valid frame, then corrupt the CRC.
    var frame_buf: [1024]u8 = undefined;
    const frame = test_build_frame(&frame_buf, "corrupted");
    // Flip a bit in the CRC field.
    frame_buf[4] ^= 0x01;
    const written = posix.send(client_fd, frame, 0) catch unreachable;
    assert(written == frame.len);

    // Drive recv — should terminate on CRC mismatch.
    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(TestConnection.State.closed, conn.state);
    try testing.expectEqual(@as(u32, 0), ctx.frame_count); // no frame delivered
}

test "Connection: orderly shutdown (0 bytes) terminates with no_shutdown" {
    var io = TestIO{};
    const pair = test_socketpair();
    const server_fd = pair[0];
    const client_fd = pair[1];

    var conn: TestConnection = undefined;
    conn.state = .closed;
    var ctx = TestContext.init(&conn);
    conn.init(&io, server_fd, @ptrCast(&ctx), TestContext.on_frame);

    // Close the client side — next recv will get 0 bytes.
    posix.close(client_fd);

    // Drive recv — should get 0 bytes → orderly shutdown.
    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: backpressure suspend and resume" {
    var io = TestIO{};
    const pair = test_socketpair();
    const server_fd = pair[0];
    const client_fd = pair[1];
    defer posix.close(client_fd);

    // Context that suspends after first frame.
    const SuspendCtx = struct {
        frames: [16][]const u8,
        frame_bufs: [16][1024]u8,
        frame_count: u32,
        conn_ptr: *TestConnection,

        fn on_frame(ctx_ptr: *anyopaque, frame: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const i = self.frame_count;
            @memcpy(self.frame_bufs[i][0..frame.len], frame);
            self.frames[i] = self.frame_bufs[i][0..frame.len];
            self.frame_count += 1;
            // Suspend after first frame.
            if (self.frame_count == 1) {
                self.conn_ptr.suspend_recv();
            }
        }
    };

    var conn: TestConnection = undefined;
    conn.state = .closed;
    var ctx = SuspendCtx{
        .frames = undefined,
        .frame_bufs = undefined,
        .frame_count = 0,
        .conn_ptr = &conn,
    };
    conn.init(&io, server_fd, @ptrCast(&ctx), SuspendCtx.on_frame);

    // Send two frames from client.
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const f1 = test_build_frame(&buf1, "first");
    const f2 = test_build_frame(&buf2, "second");

    // Write both frames.
    _ = posix.send(client_fd, f1, 0) catch unreachable;
    _ = posix.send(client_fd, f2, 0) catch unreachable;

    // Drive recv — should deliver first frame, then suspend.
    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(@as(u32, 1), ctx.frame_count);
    try testing.expectEqualSlices(u8, "first", ctx.frames[0]);
    try testing.expect(conn.recv_suspended);

    // Resume — should deliver second frame.
    conn.resume_recv();

    // The second frame may still be in the buffer from the first recv,
    // or we need another recv tick. Check if it was delivered.
    if (ctx.frame_count == 1) {
        // Need another recv to get the second frame.
        TestIO.tick(&conn.recv_completion);
    }

    try testing.expectEqual(@as(u32, 2), ctx.frame_count);
    try testing.expectEqualSlices(u8, "second", ctx.frames[1]);

    conn.invariants();
    conn.terminate(.no_shutdown);
}

test "Connection: invariants hold in closed state" {
    var conn: TestConnection = undefined;
    conn.state = .closed;
    conn.fd = -1;
    conn.recv_pos = 0;
    conn.advance_pos = 0;
    conn.process_pos = 0;
    conn.recv_submitted = false;
    conn.send_submitted = false;
    conn.recv_suspended = false;
    conn.send_queue = TestConnection.SendQueue.init();
    conn.send_pos = 0;
    conn.invariants();
}
