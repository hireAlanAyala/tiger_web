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

    pub fn init() !IO {
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        return .{
            .epoll_fd = epoll_fd,
        };
    }

    pub fn deinit(self: *IO) void {
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

    /// Poll for IO events and fire callbacks. Returns after at most `ns` nanoseconds.
    ///
    /// TB pattern: deferred callback queue. Collect completions from epoll,
    /// execute the syscalls (recv/send), store results, then drain callbacks
    /// in a separate pass. This prevents re-entrancy — a callback that
    /// submits new IO won't have its completion processed mid-drain.
    pub fn run_for_ns(self: *IO, ns: u64) void {
        const timeout_ms: i32 = @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u31)));

        var events: [64]std.os.linux.epoll_event = undefined;
        const ready = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

        // Phase 1: Execute syscalls and queue results.
        var completed_head: ?*Completion = null;
        var completed_tail: ?*Completion = null;
        for (events[0..ready]) |event| {
            const completion: *Completion = @ptrFromInt(event.data.ptr);
            self.execute(completion);
            // Push to completed list.
            completion.next = null;
            if (completed_tail) |tail| {
                tail.next = completion;
            } else {
                completed_head = completion;
            }
            completed_tail = completion;
        }

        // Phase 2: Drain callbacks. Callbacks may submit new IO,
        // which goes to epoll for the NEXT run_for_ns call.
        var current = completed_head;
        while (current) |c| {
            current = c.next;
            c.next = null;
            c.callback(c.context, c.result);
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
