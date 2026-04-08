const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.io));

/// Thin epoll-based IO layer. Provides async accept/recv/send with completion
/// callbacks. This is the production IO seam — in simulation, the entire
/// struct is replaced by SimIO with the same interface.
pub const IO = struct {
    pub const fd_t = posix.fd_t;

    pub const Completion = struct {
        fd: fd_t = 0,
        operation: Op = .none,
        context: *anyopaque = undefined,
        callback: *const fn (*anyopaque, i32) void = undefined,
        buffer: ?[]u8 = null,
        buffer_const: ?[]const u8 = null,
        /// Result from execute, stored for deferred callback.
        result: i32 = 0,
        /// Intrusive linked list for deferred callback queue.
        next: ?*Completion = null,

        const Op = enum {
            none,
            recv,
            send,
        };
    };

    epoll_fd: fd_t,

    // io_uring for shared memory futex signaling (optional).
    // Runs alongside epoll — epoll for HTTP, uring for shm futex.
    uring: ?IoUring = null,

    // Callback for shared memory polling — set by the server when
    // shm transport is active. Called every run_for_ns iteration.
    shm_poll_fn: ?*const fn () bool = null, // returns true if work was found
    empty_polls: u32 = 0,

    pub fn init() !IO {
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        return .{
            .epoll_fd = epoll_fd,
        };
    }

    /// Initialize the io_uring ring for futex operations.
    /// Call after init() when shared memory bus is needed.
    pub fn init_uring(self: *IO) !void {
        self.uring = try IoUring.init();
        log.info("io_uring initialized: fd={d}", .{self.uring.?.fd});
    }

    pub fn deinit(self: *IO) void {
        if (self.uring) |*ring| ring.deinit();
        posix.close(self.epoll_fd);
    }

    /// Create a non-blocking TCP listening socket bound to the given address.
    pub fn open_listener(_: *IO, address: std.net.Address) !fd_t {
        const fd = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        // Allow port reuse.
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Disable Nagle's algorithm on the listener.
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        try posix.bind(fd, &address.any, address.getOsSockLen());
        try posix.listen(fd, 128);

        log.info("listener bound fd={d}", .{fd});
        return fd;
    }

    /// Create a unix socket listener. All POSIX syscalls (socket, bind,
    /// listen) live here — the bus never calls posix directly. SimIO
    /// provides a version that returns a synthetic fd from next_fd.
    pub fn open_unix_listener(_: *IO, path: []const u8) !fd_t {
        assert(path.len > 0);
        assert(path.len < 108);

        // Unlink any stale socket file.
        var unlink_path: [108]u8 = undefined;
        @memcpy(unlink_path[0..path.len], path);
        unlink_path[path.len] = 0;
        posix.unlinkZ(@ptrCast(unlink_path[0 .. path.len + 1])) catch {};

        const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(fd);

        var addr: posix.sockaddr.un = .{ .path = undefined };
        @memcpy(addr.path[0..path.len], path);
        addr.path[path.len] = 0;

        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(fd, 1);

        log.info("unix listener bound on {s} fd={d}", .{ path, fd });
        return fd;
    }

    /// Apply TCP socket options on accepted connections. Call after
    /// try_accept for TCP listen sockets (HTTP). Not for Unix sockets
    /// (sidecar). Follows TigerBeetle's tcp_options() from src/io/common.zig.
    pub fn set_tcp_options(fd: fd_t) void {
        // Disable Nagle's algorithm — send small HTTP responses immediately.
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Enable TCP keepalive.
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // 60s idle before probes (longer than TB's 5s since web clients are slower).
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &std.mem.toBytes(@as(c_int, 60))) catch {};

        // 10s between probes.
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(@as(c_int, 10))) catch {};

        // 3 failed probes = dead.
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(@as(c_int, 3))) catch {};

        // 90s total TCP user timeout (keepidle + keepintvl * keepcnt = 90s).
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, &std.mem.toBytes(@as(c_int, 90_000))) catch {};
    }

    /// Synchronous non-blocking accept. Returns the accepted fd, or
    /// null if no connection is pending (EAGAIN).
    ///
    /// Direct syscall, not epoll. The right primitive for listen sockets:
    /// - Epoll can't multiplex accepts on one fd (ONESHOT race)
    /// - No perf difference — same syscall either way, once per tick
    /// - Deterministic — always runs at the same point in the tick
    /// - Simpler — no completion, no callback, no pending state
    ///
    /// TB divergence: TB uses io_uring which batches accept + recv + send
    /// into one kernel crossing. That matters at millions of IOPS. Our
    /// bottleneck is SQLite (milliseconds per write), not syscall overhead
    /// (microseconds per crossing). The batching gain is irrelevant until
    /// storage stops being the bottleneck — which it always will be with
    /// SQLite. Direct accept is the right primitive at our scale.
    ///
    /// Do not reintroduce async accept. There is no throughput benefit
    /// and it adds complexity with no gain.
    pub fn try_accept(_: *IO, listen_fd: fd_t) ?fd_t {
        const fd = posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return null;
        return fd;
    }

    /// Submit an async recv. The callback fires when data is available.
    pub fn recv(self: *IO, fd: fd_t, buffer: []u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        assert(buffer.len > 0);
        completion.* = .{
            .fd = fd,
            .operation = .recv,
            .context = context,
            .callback = callback,
            .buffer = buffer,
        };
        self.register(completion);
    }

    /// Submit an async send. The callback fires when data has been written.
    pub fn send(self: *IO, fd: fd_t, buffer: []const u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        assert(buffer.len > 0);
        completion.* = .{
            .fd = fd,
            .operation = .send,
            .context = context,
            .callback = callback,
            .buffer_const = buffer,
        };
        self.register(completion);
    }

    /// Non-blocking send — try to send immediately without epoll.
    /// Returns bytes sent, or null if the send cannot complete now.
    /// Used by the message bus send_now fast path to skip epoll
    /// round-trips for small frames that fit in the kernel buffer.
    ///
    /// Returns null for both WouldBlock AND errors (ECONNRESET,
    /// EPIPE, etc). The caller falls back to the async send path,
    /// which handles errors via the full error union in send_callback.
    /// This matches TB's pattern — send_now is best-effort, the async
    /// path is authoritative for error handling.
    pub fn send_now(_: *IO, fd: fd_t, buffer: []const u8) ?usize {
        assert(buffer.len > 0);
        const result = posix.send(fd, buffer, posix.MSG.DONTWAIT | posix.MSG.NOSIGNAL);
        return result catch null;
    }

    /// Initiate graceful shutdown of a socket. Used by the message bus
    /// 3-phase termination: shutdown causes in-flight send/recv to fail
    /// gracefully while keeping the fd open for close.
    pub fn shutdown(_: *IO, fd: fd_t, how: posix.ShutdownHow) void {
        posix.shutdown(fd, how) catch {};
    }

    pub fn close(_: *IO, fd: fd_t) void {
        posix.close(fd);
    }

    /// Poll for IO events and fire callbacks immediately.
    /// Direct execution — no deferred queue. Each callback fires
    /// right after its syscall completes. This is correct for epoll
    /// where events are processed sequentially (no re-entrancy risk).
    ///
    /// Note: TB uses a deferred queue because io_uring collects
    /// completions from a kernel ring buffer in batches. With epoll,
    /// we execute syscalls inline — deferring adds latency (4×
    /// regression measured with sidecar). Add deferred queue back
    /// only when migrating to io_uring.
    pub fn run_for_ns(self: *IO, ns: u64) void {
        // Poll shm responses (non-blocking).
        if (self.shm_poll_fn) |poll| {
            const found_work = poll();
            if (found_work) {
                self.empty_polls = 0;
            } else {
                self.empty_polls +|= 1; // saturating add
            }
        }

        // Adaptive epoll timeout: busy-poll when active, 1ms sleep
        // when idle. On 2-core, the sidecar responds within ~128 polls
        // (~3µs) so empty_polls never reaches the threshold. On 1-core
        // the sidecar is starved — empty_polls grows quickly and the
        // 1ms sleep gives it CPU time to batch-process requests.
        const timeout_ms: i32 = if (self.shm_poll_fn != null) blk: {
            // Busy-poll with idle sleep. When no SHM frames arrive for
            // 10K empty polls, sleep 1ms in epoll_wait. This only triggers
            // when truly idle (no load) or severely contended (1-core VPS).
            // Under normal 2-core load, frames arrive within ~200 polls.
            break :blk if (self.empty_polls > 10000) @as(i32, 1) else 0;
        } else @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u31)));

        var events: [64]std.os.linux.epoll_event = undefined;
        const ready = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

        for (events[0..ready]) |event| {
            const completion: *Completion = @ptrFromInt(event.data.ptr);
            self.execute(completion);
            completion.callback(completion.context, completion.result);
        }
    }

    fn register(self: *IO, completion: *Completion) void {
        const events: u32 = switch (completion.operation) {
            .recv => linux.EPOLL.IN,
            .send => linux.EPOLL.OUT,
            .none => unreachable,
        };

        var event = linux.epoll_event{
            .events = events | linux.EPOLL.ONESHOT,
            .data = .{ .ptr = @intFromPtr(completion) },
        };

        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, completion.fd, &event) catch {
            posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, completion.fd, &event) catch unreachable;
        };
    }

    /// Execute the syscall and store the result. Callback is NOT called
    /// here — it's called from the deferred drain in run_for_ns.
    fn execute(self: *IO, completion: *Completion) void {
        _ = self;
        const op = completion.operation;
        assert(op != .none);
        completion.operation = .none;

        completion.result = switch (op) {
            .recv => blk: {
                const buf = completion.buffer.?;
                const result = posix.recv(completion.fd, buf, 0);
                break :blk if (result) |bytes| @intCast(bytes) else |_| -1;
            },
            .send => blk: {
                const buf = completion.buffer_const.?;
                const result = posix.send(completion.fd, buf, 0);
                break :blk if (result) |bytes| @intCast(bytes) else |_| -1;
            },
            .none => unreachable,
        };
    }
};

// =====================================================================
// IoUring — minimal ring for futex operations (shm bus signaling).
// Runs alongside epoll. Not a general-purpose io_uring wrapper —
// only supports FUTEX_WAIT and FUTEX_WAKE.
// =====================================================================

pub const IoUring = struct {
    fd: posix.fd_t,
    sq: SubmissionQueue,
    cq: CompletionQueue,
    mmap_sq: []align(4096) u8,
    mmap_cq: []align(4096) u8,
    mmap_sqes: []align(4096) u8,

    const ring_entries = 16; // Small — only futex ops.

    pub const FutexCompletion = struct {
        context: *anyopaque,
        callback: *const fn (*anyopaque, i32) void,
        user_data: u64,
    };

    // Pending completions — fixed pool, no allocation.
    var pending: [ring_entries]?FutexCompletion = .{null} ** ring_entries;

    const SubmissionQueue = struct {
        head: *volatile u32,
        tail: *volatile u32,
        mask: u32,
        sqes: [*]linux.io_uring_sqe,
    };

    const CompletionQueue = struct {
        head: *volatile u32,
        tail: *volatile u32,
        mask: u32,
        cqes: [*]linux.io_uring_cqe,
    };

    pub fn init() !IoUring {
        var params = std.mem.zeroes(linux.io_uring_params);
        const fd = linux.io_uring_setup(ring_entries, &params);
        if (@as(i32, @bitCast(@as(u32, @truncate(fd)))) < 0) return error.IoUringSetupFailed;
        const ring_fd: posix.fd_t = @intCast(fd);

        // Map submission queue ring.
        const sq_ring_size = params.sq_off.array + params.sq_entries * @sizeOf(u32);
        const sq_ring = posix.mmap(null, sq_ring_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, ring_fd, linux.IORING_OFF_SQ_RING) catch return error.MmapFailed;

        // Map completion queue ring.
        const cq_ring_size = params.cq_off.cqes + params.cq_entries * @sizeOf(linux.io_uring_cqe);
        const cq_ring = posix.mmap(null, cq_ring_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, ring_fd, linux.IORING_OFF_CQ_RING) catch return error.MmapFailed;

        // Map SQE array.
        const sqes_size = params.sq_entries * @sizeOf(linux.io_uring_sqe);
        const sqes_ring = posix.mmap(null, sqes_size, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .SHARED }, ring_fd, linux.IORING_OFF_SQES) catch return error.MmapFailed;

        return .{
            .fd = ring_fd,
            .sq = .{
                .head = @ptrFromInt(@intFromPtr(sq_ring.ptr) + params.sq_off.head),
                .tail = @ptrFromInt(@intFromPtr(sq_ring.ptr) + params.sq_off.tail),
                .mask = @as(*u32, @ptrFromInt(@intFromPtr(sq_ring.ptr) + params.sq_off.ring_mask)).*,
                .sqes = @ptrCast(@alignCast(sqes_ring.ptr)),
            },
            .cq = .{
                .head = @ptrFromInt(@intFromPtr(cq_ring.ptr) + params.cq_off.head),
                .tail = @ptrFromInt(@intFromPtr(cq_ring.ptr) + params.cq_off.tail),
                .mask = @as(*u32, @ptrFromInt(@intFromPtr(cq_ring.ptr) + params.cq_off.ring_mask)).*,
                .cqes = @ptrCast(@alignCast(@as([*]u8, @ptrCast(cq_ring.ptr)) + params.cq_off.cqes)),
            },
            .mmap_sq = sq_ring,
            .mmap_cq = cq_ring,
            .mmap_sqes = sqes_ring,
        };
    }

    pub fn deinit(self: *IoUring) void {
        posix.munmap(self.mmap_sq);
        posix.munmap(self.mmap_cq);
        posix.munmap(self.mmap_sqes);
        posix.close(self.fd);
    }

    /// Submit a FUTEX_WAIT: wait until *addr != expected_val.
    /// When the futex completes, the callback fires.
    pub fn submit_futex_wait(
        self: *IoUring,
        addr: *volatile u32,
        expected_val: u32,
        context: *anyopaque,
        callback: *const fn (*anyopaque, i32) void,
    ) bool {
        const tail = self.sq.tail.*;
        const head = self.sq.head.*;
        if (tail -% head >= ring_entries) return false; // Queue full.

        const idx = tail & self.sq.mask;
        const sqe = &self.sq.sqes[idx];
        sqe.* = std.mem.zeroes(linux.io_uring_sqe);
        sqe.opcode = .FUTEX_WAIT;
        sqe.addr = @intFromPtr(addr);
        sqe.len = 1; // FUTEX_WAIT expects val in fd field for comparison.
        sqe.fd = @bitCast(expected_val);
        sqe.user_data = idx;

        pending[idx] = .{
            .context = context,
            .callback = callback,
            .user_data = idx,
        };

        @atomicStore(u32, self.sq.tail, tail +% 1, .release);

        // Submit to kernel.
        _ = linux.io_uring_enter(self.fd, 1, 0, 0, null);
        return true;
    }

    /// Wake a futex address. No PRIVATE_FLAG — shared memory
    /// is cross-process (server ↔ sidecar).
    pub fn futex_wake(addr: *const u32) void {
        _ = linux.futex_wake(@ptrCast(@constCast(addr)), linux.FUTEX.WAKE, 1);
    }

    /// Drain completed futex operations. Non-blocking.
    pub fn drain_completions(self: *IoUring) void {
        var drained: u32 = 0;
        while (drained < ring_entries) : (drained += 1) {
            const head = self.cq.head.*;
            const tail = @atomicLoad(u32, self.cq.tail, .acquire);
            if (head == tail) break; // No completions.

            const idx = head & self.cq.mask;
            const cqe = &self.cq.cqes[idx];

            const pending_idx = cqe.user_data;
            if (pending_idx < ring_entries) {
                if (pending[pending_idx]) |completion| {
                    completion.callback(completion.context, cqe.res);
                    pending[pending_idx] = null;
                }
            }

            self.cq.head.* = head +% 1;
        }
    }
};
