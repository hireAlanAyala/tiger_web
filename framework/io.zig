const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const assert = std.debug.assert;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.io));

const InnerIO = switch (builtin.target.os.tag) {
    .linux => @import("io/linux.zig").IO,
    .macos, .ios, .tvos, .watchos => @import("io/darwin.zig").IO,
    else => @compileError("IO not supported on this platform"),
};

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

        /// Operation state — for assertion compatibility with
        /// connection.zig. **Principled addition to TB's shape:**
        /// TB's `src/io/linux.zig:Completion` tracks operation kind
        /// internally via a tagged union; our wrapper's raw-i32
        /// callback shape lost that invariant, so we replay it here
        /// as a minimal enum used only by `assert(.operation == .none)`
        /// preconditions. Variant names match the public verbs.
        operation: Op = .none,
        const Op = enum { none, recv, send, connect };
    };

    pub const CallbackFn = *const fn (*anyopaque, i32) void;

    inner: InnerIO,

    pub fn init() !IO {
        return .{
            // 256 entries — enough for max_connections recv/send + timeouts.
            .inner = try InnerIO.init(256, 0),
        };
    }

    pub fn deinit(self: *IO) void {
        self.inner.deinit();
    }

    /// Create a non-blocking TCP listening socket bound to the given
    /// address. **Principled addition to TB's IO surface:** TB's
    /// `io/linux.zig` exposes `open_socket_tcp` + `listen` as separate
    /// verbs (their server.zig composes them); our wrapper fuses the
    /// pair into one synchronous helper because we only need the
    /// composed shape (socket → bind → listen). Callers that ever
    /// need them decomposed can use `posix.socket` + `posix.bind`
    /// + `posix.listen` directly.
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

    /// Create a unix socket listener. **Principled addition to TB's
    /// IO surface:** TB has no unix-socket listener analog because
    /// their VSR cluster is TCP-only; our sidecar uses a unix socket
    /// (`framework/message_bus.zig`) so this verb exists here to
    /// keep the server-setup shape symmetric with `open_listener`.
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

    const is_linux = builtin.target.os.tag == .linux;

    /// Apply TCP socket options on accepted connections.
    /// Matches TigerBeetle's io/common.zig: Linux-specific options
    /// (KEEPIDLE, KEEPINTVL, KEEPCNT, USER_TIMEOUT, NODELAY) are
    /// guarded — macOS doesn't expose the same TCP constants.
    pub fn set_tcp_options(fd: fd_t) void {
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, &std.mem.toBytes(@as(c_int, 1))) catch {};
        if (is_linux) {
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, &std.mem.toBytes(@as(c_int, 60))) catch {};
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, &std.mem.toBytes(@as(c_int, 10))) catch {};
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, &std.mem.toBytes(@as(c_int, 3))) catch {};
            posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.USER_TIMEOUT, &std.mem.toBytes(@as(c_int, 90_000))) catch {};
        }
    }

    /// Synchronous non-blocking accept. Direct syscall, not through
    /// the ring. **Principled divergence from TB:** TB uses
    /// `io.accept` as an async ring op matching their per-connection
    /// VSR lifecycle. For our shape (SQLite is the bottleneck, not
    /// syscall overhead) the async accept adds complexity with no
    /// latency gain; the synchronous variant matches our server
    /// tick model cleanly.
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

    /// Open a non-blocking TCP client socket. Companion to
    /// `open_listener` — same shape, just no bind/listen. Caller
    /// submits `connect()` to bring the socket up through the ring.
    ///
    /// **Principled addition (H.4):** TB has no client-socket helper
    /// on their IO wrapper because their VSR clients talk to replicas
    /// over a pre-established pool via `MessageBus`. Our benchmark
    /// load generator (and any future client-shape tool) needs
    /// `socket(2)` with the same NONBLOCK/CLOEXEC/NODELAY defaults
    /// `open_listener` applies. Exposing the helper here rather than
    /// open-coding it per-caller keeps the client-socket setup
    /// shape consistent across the project.
    pub fn open_client_socket(_: *IO, family: u16) !fd_t {
        const fd = try posix.socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
            0,
        );
        errdefer posix.close(fd);
        posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        return fd;
    }

    /// Submit an async connect through io_uring / kqueue.
    /// Callback fires once with result = 0 on success, -1 on error —
    /// same raw-i32 convention as recv/send.
    ///
    /// **Principled addition (H.4):** TB's `io/linux.zig` and
    /// `io/darwin.zig` already expose `connect` with typed callbacks
    /// (TB:965). We bridge that to our raw-i32 callback shape here,
    /// matching the `recv_bridge`/`send_bridge` pattern. Connect is
    /// a prerequisite for client-side code paths (benchmark load
    /// generator in benchmark_load.zig, plus any future admin-probe
    /// or health-check tool); recv/send already work for any fd, so
    /// exposing connect completes the client-shape verb set.
    pub fn connect(
        self: *IO,
        fd: fd_t,
        address: std.net.Address,
        completion: *Completion,
        context: *anyopaque,
        callback: CallbackFn,
    ) void {
        assert(completion.operation == .none);
        completion.context = context;
        completion.callback = callback;
        completion.operation = .connect;
        self.inner.connect(
            *Completion,
            completion,
            connect_bridge,
            &completion.inner,
            @intCast(fd),
            address,
        );
    }

    fn connect_bridge(completion: *Completion, _: *InnerIO.Completion, result: InnerIO.ConnectError!void) void {
        completion.operation = .none;
        const code: i32 = if (result) |_| 0 else |_| -1;
        completion.callback(completion.context, code);
    }

    /// Non-blocking send — try to send immediately without the ring.
    /// **Principled fast-path addition:** TB's `io/linux.zig` exposes
    /// `send_now` as an internal synchronous syscall to avoid ring
    /// overhead on small payloads; we forward it through the wrapper
    /// because `connection.zig`'s response-send path uses it for the
    /// common "fits in one write" case before falling back to
    /// async `send()`. TB's equivalent pattern lives in their
    /// `io.SendBuffer` fast-path logic.
    pub fn send_now(self: *IO, fd: fd_t, buffer: []const u8) ?usize {
        return self.inner.send_now(@intCast(fd), buffer);
    }

    /// Initiate graceful shutdown of a socket. **Principled
    /// addition:** thin forward to TB's `io.shutdown`; our callers
    /// (`connection.zig` on peer-close, `server.zig` on teardown)
    /// need the verb exposed at the wrapper level because they
    /// otherwise deal only in our `CallbackFn` shape. Error is
    /// swallowed — shutdown is best-effort; the fd is closed
    /// regardless.
    pub fn shutdown(self: *IO, fd: fd_t, how: posix.ShutdownHow) void {
        self.inner.shutdown(@intCast(fd), how) catch {};
    }

    pub fn close(_: *IO, fd: fd_t) void {
        posix.close(fd);
    }

    /// Run the event loop for the given duration. io_uring unified wait —
    /// one io_uring_enter() waits for recv/send completions and timeouts
    /// simultaneously. No epoll, no busy-polling.
    pub fn run_for_ns(self: *IO, ns: u64) void {
        self.inner.run_for_ns(@intCast(@min(ns, std.math.maxInt(u63)))) catch |err| {
            log.err("io_uring run_for_ns error: {}", .{err});
        };
    }

};
