const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = std.debug.assert;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.io));

const InnerIO = @import("io/linux.zig").IO;

/// IO layer — wraps TigerBeetle's io_uring implementation with the
/// callback signature used by connection.zig and message_bus.zig.
///
/// TB's IO uses typed callbacks: `fn(Context, *Completion, RecvError!usize)`.
/// Our consumers use raw callbacks: `fn(*anyopaque, i32)`.
/// This wrapper bridges the two: each operation stores the raw callback,
/// submits to TB's ring, and the bridge callback unwraps the typed result
/// to i32 before calling our callback.
///
/// This is the production IO seam — in simulation, the entire struct is
/// replaced by SimIO with the same interface.
pub const IO = struct {
    pub const fd_t = posix.fd_t;

    pub const Completion = struct {
        /// Raw callback — fires with (context, i32 result).
        context: *anyopaque = undefined,
        callback: CallbackFn = undefined,

        /// Embedded TB completion — used by the io_uring ring.
        inner: InnerIO.Completion = undefined,

        /// Intrusive linked list for deferred callback queue.
        next: ?*Completion = null,

        /// Operation state — for assertion compatibility with connection.zig.
        operation: Op = .none,
        const Op = enum { none, recv, send };
    };

    pub const CallbackFn = *const fn (*anyopaque, i32) void;

    inner: InnerIO,

    /// Compatibility shims — kept to avoid changing server.zig wire_sidecar.
    shm_poll_fn: ?*const fn () bool = null,
    uring: ?void = null,

    pub fn init() !IO {
        return .{
            // 256 entries — enough for max_connections recv/send + timeouts.
            .inner = try InnerIO.init(256, 0),
        };
    }

    pub fn deinit(self: *IO) void {
        self.inner.deinit();
    }

    /// Create a non-blocking TCP listening socket bound to the given address.
    pub fn open_listener(_: *IO, address: std.net.Address) !fd_t {
        const fd = try posix.socket(
            address.any.family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);

        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1))) catch {};
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        try posix.bind(fd, &address.any, address.getOsSockLen());
        try posix.listen(fd, 128);

        log.info("listener bound fd={d}", .{fd});
        return fd;
    }

    /// Create a unix socket listener.
    pub fn open_unix_listener(_: *IO, path: []const u8) !fd_t {
        assert(path.len > 0);
        assert(path.len < 108);

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

    /// Apply TCP socket options on accepted connections.
    pub fn set_tcp_options(fd: fd_t) void {
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch {};
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &std.mem.toBytes(@as(c_int, 60))) catch {};
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(@as(c_int, 10))) catch {};
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(@as(c_int, 3))) catch {};
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, &std.mem.toBytes(@as(c_int, 90_000))) catch {};
    }

    /// Synchronous non-blocking accept. Direct syscall, not through the ring.
    /// SQLite is the bottleneck, not syscall overhead. Async accept adds
    /// complexity with no gain at our scale.
    pub fn try_accept(_: *IO, listen_fd: fd_t) ?fd_t {
        const fd = posix.accept(listen_fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch return null;
        return fd;
    }

    /// Submit an async recv through io_uring.
    pub fn recv(self: *IO, fd: fd_t, buffer: []u8, completion: *Completion, context: *anyopaque, callback: CallbackFn) void {
        assert(buffer.len > 0);
        assert(completion.operation == .none);
        completion.context = context;
        completion.callback = callback;
        completion.operation = .recv;
        self.inner.recv(
            *Completion,
            completion,
            recv_bridge,
            &completion.inner,
            @intCast(fd),
            buffer,
        );
    }

    fn recv_bridge(completion: *Completion, _: *InnerIO.Completion, result: InnerIO.RecvError!usize) void {
        completion.operation = .none;
        const bytes: i32 = if (result) |n| @intCast(n) else |_| -1;
        completion.callback(completion.context, bytes);
    }

    /// Submit an async send through io_uring.
    pub fn send(self: *IO, fd: fd_t, buffer: []const u8, completion: *Completion, context: *anyopaque, callback: CallbackFn) void {
        assert(buffer.len > 0);
        assert(completion.operation == .none);
        completion.context = context;
        completion.callback = callback;
        completion.operation = .send;
        self.inner.send(
            *Completion,
            completion,
            send_bridge,
            &completion.inner,
            @intCast(fd),
            buffer,
        );
    }

    fn send_bridge(completion: *Completion, _: *InnerIO.Completion, result: InnerIO.SendError!usize) void {
        completion.operation = .none;
        const bytes: i32 = if (result) |n| @intCast(n) else |_| -1;
        completion.callback(completion.context, bytes);
    }

    /// Non-blocking send — try to send immediately without the ring.
    pub fn send_now(self: *IO, fd: fd_t, buffer: []const u8) ?usize {
        return self.inner.send_now(@intCast(fd), buffer);
    }

    /// Initiate graceful shutdown of a socket.
    pub fn shutdown(self: *IO, fd: fd_t, how: posix.ShutdownHow) void {
        self.inner.shutdown(@intCast(fd), how) catch {};
    }

    pub fn close(_: *IO, fd: fd_t) void {
        posix.close(fd);
    }

    /// Run the event loop for the given duration. io_uring unified wait —
    /// one io_uring_enter() waits for recv/send completions, futex wakeups,
    /// and timeouts simultaneously. No epoll, no busy-polling.
    pub fn run_for_ns(self: *IO, ns: u64) void {
        self.inner.run_for_ns(@intCast(@min(ns, std.math.maxInt(u63)))) catch |err| {
            log.err("io_uring run_for_ns error: {}", .{err});
        };
    }

    /// Init uring — no-op, the ring is created in init().
    pub fn init_uring(_: *IO) !void {}
};
