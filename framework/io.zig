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

        const Op = enum {
            none,
            accept,
            recv,
            send,
        };
    };

    epoll_fd: fd_t,
    completions: [max_completions]*Completion,
    completion_count: u32,

    const max_completions = 128;

    pub fn init() !IO {
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        return .{
            .epoll_fd = epoll_fd,
            .completions = undefined,
            .completion_count = 0,
        };
    }

    pub fn deinit(self: *IO) void {
        posix.close(self.epoll_fd);
    }

    /// Create a non-blocking TCP listening socket bound to the given address.
    pub fn open_listener(address: std.net.Address) !fd_t {
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

    /// Apply TCP socket options on accepted connections. Follows TigerBeetle's
    /// tcp_options() pattern from src/io/common.zig.
    fn set_tcp_options(fd: fd_t) void {
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

    /// Submit an async accept. The callback fires when a connection is ready.
    pub fn accept(self: *IO, listen_fd: fd_t, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        assert(completion.operation == .none);
        completion.* = .{
            .fd = listen_fd,
            .operation = .accept,
            .context = context,
            .callback = callback,
        };
        self.register(completion);
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

    pub fn close(_: *IO, fd: fd_t) void {
        posix.close(fd);
    }

    /// Poll for IO events and fire callbacks. Returns after at most `ns` nanoseconds.
    pub fn run_for_ns(self: *IO, ns: u64) void {
        const timeout_ms: i32 = @intCast(@min(ns / std.time.ns_per_ms, std.math.maxInt(u31)));

        var events: [64]std.os.linux.epoll_event = undefined;
        const ready = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

        for (events[0..ready]) |event| {
            const completion: *Completion = @ptrFromInt(event.data.ptr);
            self.execute(completion);
        }
    }

    fn register(self: *IO, completion: *Completion) void {
        const events: u32 = switch (completion.operation) {
            .accept, .recv => linux.EPOLL.IN,
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

    fn execute(self: *IO, completion: *Completion) void {
        _ = self;
        const op = completion.operation;
        assert(op != .none);
        completion.operation = .none;

        switch (op) {
            .accept => {
                const result = posix.accept(completion.fd, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
                if (result) |fd| {
                    set_tcp_options(fd);
                    completion.callback(completion.context, fd);
                } else |_| {
                    completion.callback(completion.context, -1);
                }
            },
            .recv => {
                const buf = completion.buffer.?;
                const result = posix.recv(completion.fd, buf, 0);
                const n: i32 = if (result) |bytes| @intCast(bytes) else |_| -1;
                completion.callback(completion.context, n);
            },
            .send => {
                const buf = completion.buffer_const.?;
                const result = posix.send(completion.fd, buf, 0);
                const n: i32 = if (result) |bytes| @intCast(bytes) else |_| -1;
                completion.callback(completion.context, n);
            },
            .none => unreachable,
        }
    }
};
