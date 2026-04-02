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
//!
//! Buffer ownership follows TB's pattern: a pre-allocated MessagePool
//! holds ref-counted messages. The send queue holds *Message pointers
//! (zero-copy). The recv buffer is a *Message from the pool. Consumers
//! can ref messages to keep data alive past callbacks.

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const stdx = @import("stdx");
const maybe = stdx.maybe;
const RingBufferType = stdx.RingBufferType;
const MessagePoolType = @import("message_pool.zig").MessagePoolType;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.message_bus));

/// Transport primitive. Recv loop, send queue, frame accumulation,
/// CRC-32 validation, backpressure, 3-phase termination.
///
/// Buffer ownership: send queue holds *Message pointers from the pool.
/// Recv reads into a *Message buffer from the pool. No embedded buffers
/// in the Connection struct — idle connections hold no memory.
///
/// Parameterized at comptime so each consumer states its bounds:
///   const SidecarConn = ConnectionType(IO, .{ .send_queue_max = 2, .frame_max = 256 * 1024 });
pub fn ConnectionType(comptime IO: type, comptime options: Options) type {
    return struct {
        const Self = @This();

        // --- Frame format ---
        // [payload_len: u32 BE][crc32: u32 LE][payload bytes]
        // CRC covers len_bytes ++ payload_bytes (not just payload).
        pub const frame_header_size: u32 = 8; // 4 len + 4 crc32
        const frame_max: u32 = options.frame_max;
        pub const buf_max: u32 = frame_max + frame_header_size;
        const send_queue_max: u32 = options.send_queue_max;

        pub const Pool = MessagePoolType(buf_max);
        pub const Message = Pool.Message;
        const SendQueue = RingBufferType(*Message, .{ .array = send_queue_max });

        comptime {
            assert(frame_header_size == 8);
            assert(buf_max <= std.math.maxInt(u32));
            assert(send_queue_max >= 2); // CALL + QUERY_RESULT
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

        /// Why the connection closed. Passed to on_close_fn so the
        /// consumer can log, set metrics, or choose a recovery strategy
        /// (e.g., sidecar: terminate on crc_error, reconnect on eof).
        ///
        /// Design note: we considered making error events non-terminal
        /// ("consumer decides whether to terminate") but rejected it:
        ///
        /// - CRC error: the byte stream is desynchronized. Length-prefixed
        ///   framing has no sync markers — after a CRC failure, the
        ///   Connection can't find the next frame boundary. Continuing
        ///   reads garbage. TB terminates on CRC error for this reason.
        ///
        /// - recv/send error: the socket is broken. Nothing to "stay
        ///   connected" to. Both TB and web servers must terminate.
        ///
        /// - Half-duplex (recv dead, send alive): requires new Connection
        ///   states (recv_dead, send_dead) that the state machine has
        ///   never modeled. The complexity buys nothing — the consumer
        ///   almost always terminates on any error.
        ///
        /// The Connection's terminate-on-error behavior is correct for
        /// framed byte streams. Recovery happens above: MessageBus
        /// re-accepts, server retries. The consumer needs to know WHY
        /// the connection closed (for logging/metrics/kill decisions),
        /// not WHETHER to close it.
        pub const CloseReason = enum {
            /// recv returned 0 — peer closed gracefully.
            eof,
            /// recv returned -1 — socket error.
            recv_error,
            /// send returned <= 0 — socket error.
            send_error,
            /// CRC-32 mismatch — frame corrupted in transit.
            crc_error,
            /// Frame declares length > frame_max — malicious or
            /// protocol mismatch.
            oversized,
            /// recv buffer full with incomplete frame — peer sending
            /// data without completing a frame (slow-fill attack).
            buffer_full,
            /// Consumer called terminate() explicitly.
            shutdown,
        };

        io: *IO,
        pool: *Pool,
        state: State,
        fd: IO.fd_t,

        // --- Recv state ---
        // Recv buffer is a *Message from the pool. Frame data points
        // into this buffer. Consumer can ref it to keep data alive.
        recv_message: ?*Message,
        recv_pos: u32, // bytes received (end of data)
        advance_pos: u32, // bytes validated (checksum-checked)
        process_pos: u32, // bytes consumed by on_frame_fn
        recv_completion: IO.Completion,
        recv_submitted: bool,
        recv_suspended: bool,

        // --- Send state ---
        // Send queue holds *Message pointers from the pool.
        // Zero-copy: caller builds into message buffer, queues pointer.
        // Messages are unref'd when fully sent.
        send_queue: SendQueue,
        send_pos: u32, // bytes sent of current head message
        send_completion: IO.Completion,
        send_submitted: bool,

        // --- Consumer callbacks ---
        //
        // Uses *anyopaque + function pointers, not a typed Consumer
        // struct parameter. We investigated typed consumers
        // (ConnectionType(IO, Consumer, options)) but rejected it:
        // causes comptime cascade — SidecarClientType needs Consumer,
        // SidecarHandlersType needs Consumer, the Server IS the
        // Consumer → circular dependency.
        //
        // TB uses the same pattern: MessageBus stores a typed callback
        // function, not a typed consumer struct. The function pointer
        // breaks the circular dependency. Consumers use @fieldParentPtr
        // to recover themselves from the embedded Connection.
        //
        // on_frame_fn: Called with complete, CRC-validated frame data.
        // Frame data points into recv_message.buffer — valid during
        // this callback only. Consumer must copy data it needs to
        // retain (copy_state pattern). May call send_frame/send_message
        // re-entrantly (QUERY sub-protocol). May call terminate().
        // connection_index: which connection in the bus sent this frame.
        // Stage 1: always 0 (single connection). Stage 2+: slot index.
        on_frame_fn: *const fn (context: *anyopaque, connection_index: u8, frame: []const u8) void,
        // on_close_fn: Called when the connection closes (terminate_close).
        // Consumer should reset any in-flight state (e.g. call_state
        // to .failed). Called once, after all IO is drained.
        // CloseReason tells the consumer WHY — for logging, metrics,
        // or close decisions (sidecar: crc_error → terminate).
        // connection_index: which connection closed.
        // May be null if consumer doesn't need close notification.
        on_close_fn: ?*const fn (context: *anyopaque, connection_index: u8, reason: CloseReason) void,
        /// Which slot this connection occupies in the bus's connections
        /// array. Passed to on_frame_fn and on_close_fn so the consumer
        /// knows which connection sent the frame or closed.
        /// Stage 1: always 0. Stage 2+: set by MessageBusType.
        connection_index: u8,
        close_reason: CloseReason = .shutdown,
        context: *anyopaque,

        // =====================================================================
        // Public API
        // =====================================================================

        /// Initialize with an fd. Gets a recv message from the pool,
        /// zeros all state, kicks off recv loop.
        /// Called by MessageBus after accept, or directly in tests.
        pub fn init(
            self: *Self,
            io: *IO,
            pool: *Pool,
            fd: IO.fd_t,
            context: *anyopaque,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            on_close_fn: ?*const fn (*anyopaque, u8, CloseReason) void,
        ) void {
            assert(self.state == .closed);
            assert(self.recv_message == null);
            defer self.invariants();
            self.io = io;
            self.pool = pool;
            self.fd = fd;
            self.context = context;
            self.on_frame_fn = on_frame_fn;
            self.on_close_fn = on_close_fn;
            self.recv_message = pool.get_message();
            self.recv_pos = 0;
            self.advance_pos = 0;
            self.process_pos = 0;
            self.recv_submitted = false;
            self.recv_suspended = false;
            self.send_queue = SendQueue.init();
            self.send_pos = 0;
            self.send_submitted = false;
            self.state = .connected;
            self.submit_recv();
        }

        /// Queue a frame for sending. Gets a message from the pool,
        /// copies the payload, adds frame header + CRC, and queues
        /// the message pointer. Convenience wrapper around
        /// send_message for callers that have the payload in a
        /// separate buffer.
        pub fn send_frame(self: *Self, data: []const u8) void {
            if (self.state != .connected) return;
            assert(data.len <= frame_max);
            assert(!self.send_queue.full());

            const message = self.pool.get_message();
            @memcpy(message.buffer[frame_header_size..][0..data.len], data);
            self.send_message(message, @intCast(data.len));
        }

        /// Queue a message for sending. The caller built the payload
        /// directly into message.buffer[frame_header_size..] (zero-copy).
        /// This function writes the frame header (len + CRC), takes
        /// ownership of the message (queues it), and kicks the send loop.
        ///
        /// After this call, the caller no longer owns the message.
        /// The bus unrefs it when fully sent.
        ///
        /// TB pattern: caller gets message from pool, builds content,
        /// transfers ownership via send_message. No half-built messages
        /// in the queue.
        pub fn send_message(self: *Self, message: *Message, payload_len: u32) void {
            assert(message.references > 0); // caller must own the message
            if (self.state != .connected) {
                self.pool.unref(message);
                return;
            }
            defer self.invariants();
            assert(payload_len <= frame_max);
            assert(!self.send_queue.full());

            // Write frame header: [len: u32 BE][crc32: u32 LE]
            std.mem.writeInt(u32, message.buffer[0..4], payload_len, .big);
            var crc = Crc32.init();
            crc.update(message.buffer[0..4]);
            crc.update(message.buffer[frame_header_size..][0..payload_len]);
            std.mem.writeInt(u32, message.buffer[4..8], crc.final(), .little);

            self.send_queue.push_assume_capacity(message);
            if (!self.send_submitted) self.do_send();
        }

        /// Stop submitting io.recv — consumer needs time to process.
        /// Must only be called when recv is not in-flight (recv_submitted
        /// = false). In practice, called from on_frame_fn during
        /// try_drain_recv where recv_submitted is already cleared.
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
        pub fn terminate(self: *Self, how: enum { shutdown, no_shutdown }, reason: CloseReason) void {
            if (self.state == .terminating) return;
            assert(self.state != .closed);
            defer self.invariants();
            self.close_reason = reason;
            if (how == .shutdown) {
                self.io.shutdown(self.fd, .both);
            }
            self.state = .terminating;
            self.terminate_join();
        }

        // =====================================================================
        // Recv internals
        // =====================================================================

        fn recv_buf(self: *Self) []u8 {
            return self.recv_message.?.buffer;
        }

        fn submit_recv(self: *Self) void {
            assert(self.state == .connected);
            assert(!self.recv_submitted);
            assert(!self.recv_suspended);
            assert(self.recv_message != null);
            assert(self.recv_pos < buf_max);
            self.recv_submitted = true;
            self.io.recv(
                self.fd,
                self.recv_buf()[self.recv_pos..],
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
                self.terminate(.shutdown, .recv_error);
                return;
            }
            if (result == 0) {
                self.terminate(.no_shutdown, .eof);
                return;
            }

            const bytes: u32 = @intCast(result);
            self.recv_pos += bytes;
            assert(self.recv_pos <= buf_max);

            // Buffer full with incomplete frame — peer is stuck or malicious.
            if (self.recv_pos == buf_max and self.advance_pos < self.recv_pos) {
                self.terminate(.shutdown, .buffer_full);
                return;
            }

            self.advance();
            if (self.state != .connected) return;
            self.try_drain_recv();
        }

        /// Validate as many complete frames as possible.
        fn advance(self: *Self) void {
            const buf = self.recv_buf();
            while (true) {
                const frame_start = self.advance_pos;

                if (self.recv_pos - frame_start < 4) return;
                const len = std.mem.readInt(u32, buf[frame_start..][0..4], .big);
                if (len > frame_max) {
                    self.terminate(.shutdown, .oversized);
                    return;
                }

                const total = frame_header_size + len;
                if (self.recv_pos - frame_start < total) return;

                // Validate CRC-32 (covers len + payload, stored as little-endian).
                assert(frame_start + total <= buf_max);
                const stored_crc = std.mem.readInt(u32, buf[frame_start + 4 ..][0..4], .little);
                var crc = Crc32.init();
                crc.update(buf[frame_start..][0..4]);
                crc.update(buf[frame_start + 8 ..][0..total - 8]);
                if (crc.final() != stored_crc) {
                    self.terminate(.shutdown, .crc_error);
                    return;
                }

                self.advance_pos = frame_start + total;
            }
        }

        /// Deliver validated, unconsumed frames to the consumer.
        /// Compacts the recv buffer once after all frames are drained.
        fn try_drain_recv(self: *Self) void {
            const buf = self.recv_buf();
            while (self.advance_pos > self.process_pos) {
                const len = std.mem.readInt(u32, buf[self.process_pos..][0..4], .big);
                const frame = buf[self.process_pos + 8 ..][0..len];

                self.process_pos += frame_header_size + len;

                self.on_frame_fn(self.context, self.connection_index, frame);

                maybe(self.state == .terminating);
                if (self.state != .connected) return;
                if (self.recv_suspended) return;
            }

            // Compact: move unconsumed data to front of buffer.
            // Preserves the advance_pos offset — validated-but-undelivered
            // frames (between process_pos and advance_pos) stay validated
            // after compaction. Without this, resume_recv would re-validate
            // frames that already passed CRC, or worse, skip them.
            if (self.process_pos > 0) {
                const remaining = self.recv_pos - self.process_pos;
                if (remaining > 0) {
                    stdx.copy_left(.exact, u8, buf[0..remaining], buf[self.process_pos..][0..remaining]);
                }
                self.recv_pos = remaining;
                self.advance_pos -= self.process_pos;
                self.process_pos = 0;
            }

            if (!self.recv_suspended and self.state == .connected) {
                self.submit_recv();
            }
        }

        // =====================================================================
        // Send internals
        // =====================================================================

        /// Read the framed length from a send message's buffer.
        /// The length is encoded in the first 4 bytes (big-endian)
        /// plus the frame_header_size.
        fn send_msg_len(message: *Message) u32 {
            return frame_header_size + std.mem.readInt(u32, message.buffer[0..4], .big);
        }

        fn do_send(self: *Self) void {
            assert(self.state == .connected);
            self.send_now();
            if (self.state != .connected) return;
            if (self.send_queue.empty()) return;
            self.submit_send();
        }

        fn send_now(self: *Self) void {
            while (self.send_queue.head()) |message| {
                const total_len = send_msg_len(message);

                while (self.send_pos < total_len) {
                    const n = self.io.send_now(self.fd, message.buffer[self.send_pos..total_len]) orelse return;
                    self.send_pos += @intCast(n);
                }

                // Frame fully sent. Pop pointer and unref message.
                const sent = self.send_queue.pop().?;
                self.pool.unref(sent);
                self.send_pos = 0;
            }
        }

        fn submit_send(self: *Self) void {
            assert(!self.send_submitted);
            assert(!self.send_queue.empty());
            const message = self.send_queue.head().?;
            const total_len = send_msg_len(message);
            self.send_submitted = true;
            self.io.send(
                self.fd,
                message.buffer[self.send_pos..total_len],
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
                self.terminate(.no_shutdown, .send_error);
                return;
            }

            self.send_pos += @intCast(result);
            const message = self.send_queue.head().?;
            const total_len = send_msg_len(message);
            assert(self.send_pos <= total_len);
            if (self.send_pos == total_len) {
                const sent = self.send_queue.pop().?;
                self.pool.unref(sent);
                self.send_pos = 0;
            }

            self.do_send();
        }

        // =====================================================================
        // Termination (3-phase, TB pattern)
        // =====================================================================

        fn terminate_join(self: *Self) void {
            assert(self.state == .terminating);
            if (self.recv_submitted) return;
            if (self.send_submitted) return;
            self.terminate_close();
        }

        fn terminate_close(self: *Self) void {
            assert(self.state == .terminating);
            assert(!self.recv_submitted);
            assert(!self.send_submitted);
            defer self.invariants();

            self.recv_submitted = true;
            self.send_submitted = true;

            // Unref all queued send messages.
            while (self.send_queue.pop()) |message| {
                self.pool.unref(message);
            }

            // Unref recv message.
            if (self.recv_message) |msg| {
                self.pool.unref(msg);
                self.recv_message = null;
            }

            self.io.close(self.fd);

            self.fd = -1;
            self.recv_pos = 0;
            self.advance_pos = 0;
            self.process_pos = 0;
            self.recv_submitted = false;
            self.send_submitted = false;
            self.recv_suspended = false;
            self.send_pos = 0;
            self.state = .closed;

            // Notify consumer that the connection closed, with reason.
            if (self.on_close_fn) |on_close| {
                on_close(self.context, self.connection_index, self.close_reason);
            }
        }

        // =====================================================================
        // Invariants
        // =====================================================================

        pub fn invariants(self: *const Self) void {
            // Position chain.
            assert(self.process_pos <= self.advance_pos);
            assert(self.advance_pos <= self.recv_pos);
            assert(self.recv_pos <= buf_max);

            // Send queue bounds.
            assert(self.send_queue.count <= send_queue_max);
            if (!self.send_queue.empty()) {
                const head_len = send_msg_len(self.send_queue.head().?);
                assert(self.send_pos <= head_len);
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
                    assert(self.recv_message == null);
                },
                .connected => {
                    assert(self.fd != -1);
                    assert(self.recv_message != null);
                },
                .terminating => assert(self.fd != -1),
            }

            // Suspension consistency.
            if (self.recv_suspended) assert(!self.recv_submitted);
        }
    };
}

pub const Options = struct {
    /// Max queued outgoing frames per connection. Sidecar: 2 (serial).
    /// Worker: 4 (concurrent dispatch). Must be >= 2 for
    /// CALL + QUERY_RESULT to coexist.
    send_queue_max: u32 = 4,
    /// Max frame payload size. Consumer sets this to match their
    /// protocol's frame_max. No default — must be explicit.
    frame_max: u32,
    /// Max connections. Stage 1: 1 (default). Stage 2: 2 (hot standby).
    /// Stage 3: N (round-robin). Each connection gets its own recv
    /// message and send queue from the shared pool.
    connections_max: u8 = 1,
};

/// Lifecycle manager. Owns N Connections and a shared MessagePool.
/// Handles listen, accept into slots, reconnect-on-disconnect.
/// The Connection doesn't know it exists.
///
/// Parameterized at comptime so each consumer declares its bounds:
///   const SidecarBus = MessageBusType(IO, .{ .send_queue_max = 2, .frame_max = 256 * 1024 });
///   const SidecarBus = MessageBusType(IO, .{ .send_queue_max = 2, .frame_max = 256 * 1024, .connections_max = 2 });
pub fn MessageBusType(comptime IO: type, comptime options: Options) type {
    return struct {
        const Self = @This();
        pub const Connection = ConnectionType(IO, options);
        const Pool = Connection.Pool;

        pub const connections_max = options.connections_max;

        io: *IO,
        pool: Pool,
        connections: [connections_max]Connection,

        // Listen/accept — fills all empty slots.
        listen_fd: IO.fd_t,
        accept_completions: [connections_max]IO.Completion,
        accept_pending: [connections_max]bool,

        /// Which connection to route send_message() to. Set by the
        /// server via set_active(). null = no active connection
        /// (send silently drops). The bus stores active but never
        /// decides its value — the server owns the routing decision.
        active: ?u8,

        // Consumer callbacks — stored here, passed to connection on init.
        on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
        on_close_fn: ?*const fn (*anyopaque, u8, Connection.CloseReason) void,
        context: *anyopaque,

        /// Pool sizing: per connection 1 recv buffer + send_queue_max
        /// send entries. Plus 1 shared burst for send_frame allocations.
        const messages_max: u32 = connections_max * (1 + options.send_queue_max) + 1;

        comptime {
            assert(connections_max >= 1);
            assert(connections_max <= 8); // bounded — no unbounded arrays
        }

        /// Initialize pool and state. Does NOT start listening.
        /// Call start_listener() after the callback context is available.
        /// Two-phase init: init() sets up memory, start_listener() binds
        /// the socket. This supports cases where the callback context
        /// (e.g., the server) is created after the bus.
        pub fn init_pool(
            self: *Self,
            allocator: std.mem.Allocator,
            io: *IO,
            context: *anyopaque,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            on_close_fn: ?*const fn (*anyopaque, u8, Connection.CloseReason) void,
        ) !void {
            self.io = io;
            self.pool = try Pool.init(allocator, messages_max);
            for (&self.connections, 0..) |*conn, i| {
                conn.* = .{
                    .io = io,
                    .pool = &self.pool,
                    .state = .closed,
                    .fd = -1,
                    .recv_message = null,
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
                    .on_close_fn = on_close_fn,
                    .connection_index = @intCast(i),
                    .context = context,
                };
            }
            self.listen_fd = -1;
            for (&self.accept_completions) |*ac| ac.* = .{};
            for (&self.accept_pending) |*p| p.* = false;
            self.active = null;
            self.on_frame_fn = on_frame_fn;
            self.on_close_fn = on_close_fn;
            self.context = context;
        }

        /// Full init — init pool + start listening. Convenience for
        /// cases where the callback context is available at init time.
        pub fn init_listener(
            self: *Self,
            allocator: std.mem.Allocator,
            io: *IO,
            path: []const u8,
            context: *anyopaque,
            on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
            on_close_fn: ?*const fn (*anyopaque, u8, Connection.CloseReason) void,
        ) !void {
            try self.init_pool(allocator, io, context, on_frame_fn, on_close_fn);
            self.start_listener(path);
        }

        /// Start listening on the given unix socket path.
        /// Called after init_pool when the callback context wasn't
        /// available at init time (two-phase init).
        pub fn start_listener(self: *Self, path: []const u8) void {
            self.listen(path);
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.connections) |*conn| {
                assert(conn.state == .closed);
            }
            self.pool.deinit(allocator);
        }

        /// Create a unix socket listener via the IO layer.
        /// All POSIX syscalls live in IO.open_unix_listener — the bus
        /// never calls posix directly. TB pattern: IO owns the kernel seam.
        fn listen(self: *Self, path: []const u8) void {
            for (&self.connections) |*conn| assert(conn.state == .closed);
            self.listen_fd = self.io.open_unix_listener(path) catch |err| {
                log.warn("listen: {}", .{err});
                return;
            };
            log.info("listening on {s}", .{path});
        }

        pub fn tick_accept(self: *Self) void {
            if (self.listen_fd == -1) return;
            for (&self.connections, &self.accept_pending, &self.accept_completions) |*conn, *pending, *completion| {
                if (conn.state != .closed) continue;
                if (pending.*) continue;
                pending.* = true;
                self.io.accept(
                    self.listen_fd,
                    completion,
                    @ptrCast(self),
                    accept_callback,
                );
            }
        }

        fn accept_callback(ctx: *anyopaque, result: i32) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            if (result < 0) {
                // Clear ONE pending flag for a closed slot. We can't
                // identify which completion errored (callback doesn't
                // receive the completion pointer), but exactly one
                // outstanding accept failed. Clear the first match so
                // tick_accept can resubmit it.
                for (&self.connections, &self.accept_pending) |*conn, *pending| {
                    if (conn.state == .closed and pending.*) {
                        pending.* = false;
                        break;
                    }
                }
                return;
            }

            const accepted_fd: IO.fd_t = result;

            // Assign the fd to the first available slot. Accepts on a
            // listen socket are fungible — any accept returns the next
            // incoming fd. Slot assignment is arbitrary because sidecars
            // are interchangeable (no identity).
            for (&self.connections, &self.accept_pending, 0..) |*conn, *pending, i| {
                if (conn.state == .closed and pending.*) {
                    pending.* = false;
                    log.info("accepted fd={d} slot={d}", .{ accepted_fd, i });
                    conn.init(self.io, &self.pool, accepted_fd, self.context, self.on_frame_fn, self.on_close_fn);
                    return;
                }
            }
            // No slot available — shouldn't happen (tick_accept only
            // submits accepts for closed+non-pending slots).
            unreachable;
        }

        // --- Active connection routing ---
        //
        // send_message, is_connected, can_send route to connections[active].
        // If active is null, they silently fail (send drops, is_connected
        // returns false). TB pattern: bus.send_message_to_replica(N) drops
        // if replicas[N] is null.

        /// Set which connection send_message routes to.
        /// Called by the server after READY handshake or failover.
        pub fn set_active(self: *Self, index: ?u8) void {
            if (index) |i| {
                assert(i < connections_max);
                assert(self.connections[i].state == .connected);
            }
            self.active = index;
        }

        pub fn send_frame(self: *Self, data: []const u8) void {
            const conn = self.active_connection() orelse return;
            conn.send_frame(data);
        }

        pub fn send_message(self: *Self, message: *Connection.Message, payload_len: u32) void {
            const conn = self.active_connection() orelse {
                self.pool.unref(message);
                return;
            };
            conn.send_message(message, payload_len);
        }

        pub fn suspend_recv(self: *Self) void {
            const conn = self.active_connection() orelse return;
            conn.suspend_recv();
        }

        pub fn resume_recv(self: *Self) void {
            const conn = self.active_connection() orelse return;
            conn.resume_recv();
        }

        /// Whether the active connection is established.
        pub fn is_connected(self: *const Self) bool {
            const i = self.active orelse return false;
            return self.connections[i].state == .connected;
        }

        /// Whether the active connection's send queue can accept a message.
        pub fn can_send(self: *const Self) bool {
            const i = self.active orelse return false;
            return !self.connections[i].send_queue.full();
        }

        /// Get a message from the shared pool.
        pub fn get_message(self: *Self) *Connection.Message {
            return self.pool.get_message();
        }

        /// Return a message to the shared pool.
        pub fn unref(self: *Self, message: *Connection.Message) void {
            self.pool.unref(message);
        }

        /// Terminate the active connection.
        pub fn terminate(self: *Self) void {
            const conn = self.active_connection() orelse return;
            if (conn.state == .connected) {
                conn.terminate(.shutdown, .shutdown);
            }
        }

        /// Terminate a specific connection by index.
        pub fn terminate_connection(self: *Self, index: u8) void {
            assert(index < connections_max);
            if (self.connections[index].state == .connected) {
                self.connections[index].terminate(.shutdown, .shutdown);
            }
        }

        /// Connect an existing fd to connection slot 0.
        /// Used by fuzzers — single connection only.
        pub fn connect_fd(self: *Self, fd: IO.fd_t) void {
            assert(self.connections[0].state == .closed);
            self.connections[0].init(self.io, &self.pool, fd, self.context, self.on_frame_fn, self.on_close_fn);
            self.active = 0;
        }

        /// Frame header size — re-exported so consumers don't reach
        /// into Bus.Connection for a constant.
        pub const frame_header_size = Connection.frame_header_size;

        fn active_connection(self: *Self) ?*Connection {
            const i = self.active orelse return null;
            return &self.connections[i];
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
    assert(payload.len <= 256 * 1024);
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

/// Minimal IO for unit tests. Stores completions, caller drives
/// via tick(). Uses real unix sockets for send_now.
///
/// TODO: Delete after Phase 3 (FuzzIO).
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
        return result catch null;
    }

    pub fn accept(_: *TestIO, _: fd_t, _: *Completion, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}

    pub fn shutdown(_: *TestIO, fd: fd_t, how: posix.ShutdownHow) void {
        posix.shutdown(fd, how) catch {};
    }

    pub fn close(_: *TestIO, fd: fd_t) void {
        posix.close(fd);
    }

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

const test_frame_max = 256 * 1024;
const TestConnection = ConnectionType(TestIO, .{ .send_queue_max = 4, .frame_max = test_frame_max });

/// Test context that records delivered frames.
const TestContext = struct {
    frames: [16][]const u8,
    frame_bufs: [16][1024]u8,
    frame_count: u32,

    fn init() TestContext {
        return .{
            .frames = undefined,
            .frame_bufs = undefined,
            .frame_count = 0,
        };
    }

    fn on_frame(ctx_ptr: *anyopaque, _: u8, frame: []const u8) void {
        const self: *TestContext = @ptrCast(@alignCast(ctx_ptr));
        assert(self.frame_count < 16);
        const i = self.frame_count;
        @memcpy(self.frame_bufs[i][0..frame.len], frame);
        self.frames[i] = self.frame_bufs[i][0..frame.len];
        self.frame_count += 1;
    }
};

fn test_init_conn(conn: *TestConnection, io: *TestIO, pool: *TestConnection.Pool, fd: TestIO.fd_t, ctx: *anyopaque, on_frame_fn: *const fn (*anyopaque, u8, []const u8) void) void {
    conn.state = .closed;
    conn.recv_message = null;
    conn.init(io, pool, fd, ctx, on_frame_fn, null);
}

test "Connection: send and receive a frame" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    var ctx = TestContext.init();
    var conn: TestConnection = undefined;
    test_init_conn(&conn, &io, &pool, pair[0], @ptrCast(&ctx), TestContext.on_frame);

    const payload = "hello, message bus!";
    var frame_buf: [1024]u8 = undefined;
    const frame = test_build_frame(&frame_buf, payload);
    const written = posix.send(client_fd, frame, 0) catch unreachable;
    assert(written == frame.len);

    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(@as(u32, 1), ctx.frame_count);
    try testing.expectEqualSlices(u8, payload, ctx.frames[0]);
    conn.invariants();

    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: send queue delivers multiple frames in order" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    var ctx = TestContext.init();
    var conn: TestConnection = undefined;
    test_init_conn(&conn, &io, &pool, pair[0], @ptrCast(&ctx), TestContext.on_frame);

    conn.send_frame("frame-one");
    conn.send_frame("frame-two");
    conn.send_frame("frame-three");

    var read_buf: [4096]u8 = undefined;
    var total_read: usize = 0;
    for (0..10) |_| {
        const n = posix.recv(client_fd, read_buf[total_read..], posix.MSG.DONTWAIT) catch break;
        if (n == 0) break;
        total_read += n;
    }

    var pos: usize = 0;
    var frame_count: u32 = 0;
    var received_payloads: [4][]const u8 = undefined;
    while (pos + 8 <= total_read) {
        const len = std.mem.readInt(u32, read_buf[pos..][0..4], .big);
        received_payloads[frame_count] = read_buf[pos + 8 ..][0..len];
        frame_count += 1;
        pos += 8 + len;
    }

    try testing.expectEqual(@as(u32, 3), frame_count);
    try testing.expectEqualSlices(u8, "frame-one", received_payloads[0]);
    try testing.expectEqualSlices(u8, "frame-two", received_payloads[1]);
    try testing.expectEqualSlices(u8, "frame-three", received_payloads[2]);

    conn.invariants();

    // Close client fd and drive recv to complete 3-phase termination.
    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: CRC mismatch terminates" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    var ctx = TestContext.init();
    var conn: TestConnection = undefined;
    test_init_conn(&conn, &io, &pool, pair[0], @ptrCast(&ctx), TestContext.on_frame);

    var frame_buf: [1024]u8 = undefined;
    const frame = test_build_frame(&frame_buf, "corrupted");
    frame_buf[4] ^= 0x01;
    const written = posix.send(client_fd, frame, 0) catch unreachable;
    assert(written == frame.len);

    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(TestConnection.State.closed, conn.state);
    try testing.expectEqual(@as(u32, 0), ctx.frame_count);
    posix.close(client_fd);
}

test "Connection: orderly shutdown (0 bytes)" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    var ctx = TestContext.init();
    var conn: TestConnection = undefined;
    test_init_conn(&conn, &io, &pool, pair[0], @ptrCast(&ctx), TestContext.on_frame);

    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: backpressure suspend and resume" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    const SuspendCtx = struct {
        frames: [16][]const u8,
        frame_bufs: [16][1024]u8,
        frame_count: u32,
        conn_ptr: *TestConnection,

        fn on_frame(ctx_ptr: *anyopaque, _: u8, frame: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const i = self.frame_count;
            @memcpy(self.frame_bufs[i][0..frame.len], frame);
            self.frames[i] = self.frame_bufs[i][0..frame.len];
            self.frame_count += 1;
            if (self.frame_count == 1) {
                self.conn_ptr.suspend_recv();
            }
        }
    };

    var conn: TestConnection = undefined;
    conn.state = .closed;
    conn.recv_message = null;
    var ctx = SuspendCtx{
        .frames = undefined,
        .frame_bufs = undefined,
        .frame_count = 0,
        .conn_ptr = &conn,
    };
    conn.init(&io, &pool, pair[0], @ptrCast(&ctx), SuspendCtx.on_frame, null);

    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    _ = posix.send(client_fd, test_build_frame(&buf1, "first"), 0) catch unreachable;
    _ = posix.send(client_fd, test_build_frame(&buf2, "second"), 0) catch unreachable;

    TestIO.tick(&conn.recv_completion);

    try testing.expectEqual(@as(u32, 1), ctx.frame_count);
    try testing.expectEqualSlices(u8, "first", ctx.frames[0]);
    try testing.expect(conn.recv_suspended);

    conn.resume_recv();

    if (ctx.frame_count == 1) {
        TestIO.tick(&conn.recv_completion);
    }

    try testing.expectEqual(@as(u32, 2), ctx.frame_count);
    try testing.expectEqualSlices(u8, "second", ctx.frames[1]);

    conn.invariants();

    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: send_message zero-copy path" {
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    var ctx = TestContext.init();
    var conn: TestConnection = undefined;
    test_init_conn(&conn, &io, &pool, pair[0], @ptrCast(&ctx), TestContext.on_frame);

    // Zero-copy: get message from pool, build payload directly, send.
    const message = pool.get_message();
    const payload = "zero-copy!";
    @memcpy(message.buffer[TestConnection.frame_header_size..][0..payload.len], payload);
    conn.send_message(message, payload.len);

    // Read from client side and verify.
    var read_buf: [1024]u8 = undefined;
    var total_read: usize = 0;
    for (0..10) |_| {
        const n = posix.recv(client_fd, read_buf[total_read..], posix.MSG.DONTWAIT) catch break;
        if (n == 0) break;
        total_read += n;
    }

    try testing.expect(total_read >= 8 + payload.len);
    const recv_len = std.mem.readInt(u32, read_buf[0..4], .big);
    try testing.expectEqual(@as(u32, payload.len), recv_len);
    try testing.expectEqualSlices(u8, payload, read_buf[8..][0..payload.len]);

    // Verify CRC.
    const stored_crc = std.mem.readInt(u32, read_buf[4..8], .little);
    var crc = Crc32.init();
    crc.update(read_buf[0..4]);
    crc.update(read_buf[8..][0..payload.len]);
    try testing.expectEqual(crc.final(), stored_crc);

    conn.invariants();
    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: invariants hold in closed state" {
    var conn: TestConnection = undefined;
    conn.state = .closed;
    conn.fd = -1;
    conn.recv_message = null;
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

test "Connection: re-entrancy — send_frame from on_frame" {
    // Exercises the try_drain_recv → on_frame_fn → send_frame path.
    // This is the QUERY sub-protocol pattern: the consumer sends a
    // response frame while receiving a request frame.
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    const ReentrantSendCtx = struct {
        send_count: u32 = 0,
        conn_ptr: *TestConnection,
        pool_ptr: *TestConnection.Pool,

        fn on_frame(ctx_ptr: *anyopaque, _: u8, _frame: []const u8) void {
            _ = _frame;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            // Re-entrant: send a frame from inside on_frame.
            if (self.conn_ptr.state == .connected and
                self.conn_ptr.send_queue.count < 4)
            {
                self.conn_ptr.send_frame("reply");
                self.send_count += 1;
            }
        }
    };

    var conn: TestConnection = undefined;
    conn.state = .closed;
    conn.recv_message = null;
    var ctx = ReentrantSendCtx{ .conn_ptr = &conn, .pool_ptr = &pool };
    conn.init(&io, &pool, pair[0], @ptrCast(&ctx), ReentrantSendCtx.on_frame, null);

    // Inject a valid frame from the client side.
    const payload = "request";
    var frame_buf: [1024]u8 = undefined;
    const frame = test_build_frame(&frame_buf, payload);
    const written = posix.send(client_fd, frame, 0) catch unreachable;
    assert(written == frame.len);

    // Tick recv — delivers the frame, on_frame sends a reply.
    TestIO.tick(&conn.recv_completion);

    // Assert re-entrant send happened.
    try testing.expectEqual(@as(u32, 1), ctx.send_count);
    try testing.expect(conn.state == .connected);
    conn.invariants();

    // Verify reply was sent to client.
    var read_buf: [1024]u8 = undefined;
    var total_read: usize = 0;
    for (0..10) |_| {
        const n = posix.recv(client_fd, read_buf[total_read..], posix.MSG.DONTWAIT) catch break;
        if (n == 0) break;
        total_read += n;
    }
    // Reply frame: 8 header + 5 ("reply")
    try testing.expect(total_read >= 8 + 5);
    try testing.expectEqualSlices(u8, "reply", read_buf[8..13]);

    // Clean up.
    posix.close(client_fd);
    TestIO.tick(&conn.recv_completion);
    try testing.expectEqual(TestConnection.State.closed, conn.state);
}

test "Connection: re-entrancy — terminate from on_frame" {
    // Exercises the try_drain_recv → on_frame_fn → terminate path.
    // After terminate, try_drain_recv must stop iterating (checks
    // state != .connected after on_frame_fn returns).
    var io = TestIO{};
    var pool = try TestConnection.Pool.init(testing.allocator, 8);
    defer pool.deinit(testing.allocator);
    const pair = test_socketpair();
    const client_fd = pair[1];

    const TerminateCtx = struct {
        terminated: bool = false,
        conn_ptr: *TestConnection,

        fn on_frame(ctx_ptr: *anyopaque, _: u8, _frame: []const u8) void {
            _ = _frame;
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            if (self.conn_ptr.state == .connected) {
                self.conn_ptr.terminate(.no_shutdown, .shutdown);
                self.terminated = true;
            }
        }
    };

    var conn: TestConnection = undefined;
    conn.state = .closed;
    conn.recv_message = null;
    var ctx = TerminateCtx{ .conn_ptr = &conn };
    conn.init(&io, &pool, pair[0], @ptrCast(&ctx), TerminateCtx.on_frame, null);

    // Inject TWO valid frames. The first triggers terminate.
    // The second must NOT be delivered (try_drain_recv stops).
    var buf1: [1024]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    _ = posix.send(client_fd, test_build_frame(&buf1, "first"), 0) catch unreachable;
    _ = posix.send(client_fd, test_build_frame(&buf2, "second"), 0) catch unreachable;

    // Tick recv — delivers first frame, on_frame terminates.
    TestIO.tick(&conn.recv_completion);

    // Assert terminate happened and only one frame was delivered.
    try testing.expect(ctx.terminated);
    // Connection should be .closed (terminate_close runs because
    // recv_submitted was cleared before try_drain_recv, and
    // send_submitted is false — no in-flight IO to wait for).
    try testing.expectEqual(TestConnection.State.closed, conn.state);

    posix.close(client_fd);
}
