//! FuzzIO — synthetic IO for deterministic fuzzing.
//!
//! Simulates socket operations with PRNG-driven fault injection.
//! Bidirectional socket pairs with send buffers, partial delivery,
//! error injection. Statically allocated.
//!
//! The IO simulates sockets. The fuzzer drives completions.
//! Same separation as production: IO does syscalls, the tick
//! loop drives the event model.
//!
//! Shared by message_bus_fuzz.zig and sidecar_fuzz.zig.

const std = @import("std");
const posix = std.posix;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const Ratio = PRNG.Ratio;

pub const FuzzIO = struct {
    pub const fd_t = i32;
    pub const Completion = struct {
        fd: fd_t = 0,
        operation: Op = .none,
        context: *anyopaque = undefined,
        callback: *const fn (*anyopaque, i32) void = undefined,
        buffer: ?[]u8 = null,
        buffer_const: ?[]const u8 = null,

        const Op = enum { none, accept, recv, send, readable };
    };

    const max_connections = 4;
    const send_buf_max = 64 * 1024;

    const SocketConnection = struct {
        active: bool = false,
        remote_fd: ?fd_t = null,
        closed: bool = false,
        shutdown_recv: bool = false,
        shutdown_send: bool = false,
        sending: [send_buf_max]u8 = undefined,
        sending_len: u32 = 0,
        sending_offset: u32 = 0,
    };

    prng: *PRNG,
    connections: [max_connections]SocketConnection = [_]SocketConnection{.{}} ** max_connections,
    fd_next: fd_t = 10,

    // Fault injection (swarm-tested per seed).
    recv_partial_probability: Ratio,
    send_partial_probability: Ratio,
    send_now_success_probability: Ratio,
    recv_error_probability: Ratio,
    send_error_probability: Ratio,

    pub fn init(prng: *PRNG) FuzzIO {
        return .{
            .prng = prng,
            .recv_partial_probability = PRNG.ratio(prng.range_inclusive(u64, 2, 8), 10),
            .send_partial_probability = PRNG.ratio(prng.range_inclusive(u64, 2, 8), 10),
            .send_now_success_probability = PRNG.ratio(prng.range_inclusive(u64, 3, 9), 10),
            .recv_error_probability = PRNG.ratio(prng.range_inclusive(u64, 0, 2), 10),
            .send_error_probability = PRNG.ratio(prng.range_inclusive(u64, 0, 1), 10),
        };
    }

    fn fd_index(fd: fd_t) ?usize {
        if (fd < 10 or fd >= 10 + max_connections) return null;
        return @intCast(fd - 10);
    }

    fn get_conn(self: *FuzzIO, fd: fd_t) ?*SocketConnection {
        const idx = fd_index(fd) orelse return null;
        const c = &self.connections[idx];
        if (!c.active) return null;
        return c;
    }

    // =================================================================
    // Socket simulation — used by fuzzers to set up state
    // =================================================================

    pub fn create_socketpair(self: *FuzzIO) [2]fd_t {
        const fd_a = self.fd_next;
        self.fd_next += 1;
        const fd_b = self.fd_next;
        self.fd_next += 1;

        const idx_a = fd_index(fd_a).?;
        const idx_b = fd_index(fd_b).?;

        self.connections[idx_a] = .{ .active = true, .remote_fd = fd_b };
        self.connections[idx_b] = .{ .active = true, .remote_fd = fd_a };

        return .{ fd_a, fd_b };
    }

    /// Inject data into a connection's send buffer (simulates peer writing).
    /// Returns false if data doesn't fit — caller should not track.
    pub fn inject_data(self: *FuzzIO, fd: fd_t, data: []const u8) bool {
        const c = self.get_conn(fd) orelse return false;
        if (c.closed) return false;
        const space = send_buf_max - c.sending_len;
        if (data.len > space) return false;
        @memcpy(c.sending[c.sending_len..][0..data.len], data);
        c.sending_len += @intCast(data.len);
        return true;
    }

    /// Close the peer end — the other side will see EOF on recv.
    pub fn close_peer(self: *FuzzIO, fd: fd_t) void {
        const c = self.get_conn(fd) orelse return;
        c.closed = true;
    }

    // =================================================================
    // Recv/send execution — called by fuzzer tick logic
    // =================================================================

    /// Execute a pending recv. Returns the result (bytes read, 0 = EOF,
    /// -1 = error, null = no data available, leave pending).
    /// The fuzzer checks this and decides whether to fire the callback.
    pub fn do_recv(self: *FuzzIO, fd: fd_t, buffer: []u8) ?i32 {
        const local = self.get_conn(fd) orelse return @as(i32, -1);

        if (local.closed or local.shutdown_recv) return @as(i32, 0); // EOF

        if (self.prng.chance(self.recv_error_probability)) return @as(i32, -1);

        const peer_fd = local.remote_fd orelse return null; // no peer yet
        const peer = self.get_conn(peer_fd) orelse return @as(i32, 0);

        const available = peer.sending_len - peer.sending_offset;
        if (available == 0) {
            if (peer.closed) return @as(i32, 0); // EOF
            return null; // no data — leave pending
        }

        const max_recv = @min(available, @as(u32, @intCast(buffer.len)));
        const n: u32 = if (self.prng.chance(self.recv_partial_probability))
            self.prng.range_inclusive(u32, 1, max_recv)
        else
            max_recv;

        @memcpy(buffer[0..n], peer.sending[peer.sending_offset..][0..n]);
        peer.sending_offset += n;

        if (peer.sending_offset == peer.sending_len) {
            peer.sending_len = 0;
            peer.sending_offset = 0;
        }

        return @intCast(n);
    }

    /// Execute a pending send. Returns the result (bytes written,
    /// -1 = error, null = buffer full, leave pending).
    pub fn do_send(self: *FuzzIO, fd: fd_t, buffer: []const u8) ?i32 {
        const local = self.get_conn(fd) orelse return @as(i32, -1);

        if (local.closed or local.shutdown_send) return @as(i32, -1);

        if (self.prng.chance(self.send_error_probability)) return @as(i32, -1);

        const space = send_buf_max - local.sending_len;
        if (space == 0) return null; // buffer full — leave pending

        const max_send = @min(@as(u32, @intCast(buffer.len)), @as(u32, @intCast(space)));
        const n: u32 = if (self.prng.chance(self.send_partial_probability))
            self.prng.range_inclusive(u32, 1, max_send)
        else
            max_send;

        @memcpy(local.sending[local.sending_len..][0..n], buffer[0..n]);
        local.sending_len += n;

        return @intCast(n);
    }

    // =================================================================
    // IO interface — matches SimIO/TestIO/IO contract
    // =================================================================

    pub fn accept(_: *FuzzIO, _: fd_t, _: *Completion, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}

    pub fn recv(_: *FuzzIO, fd: fd_t, buffer: []u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        completion.* = .{ .fd = fd, .operation = .recv, .context = context, .callback = callback, .buffer = buffer };
    }

    pub fn send(_: *FuzzIO, fd: fd_t, buffer: []const u8, completion: *Completion, context: *anyopaque, callback: *const fn (*anyopaque, i32) void) void {
        completion.* = .{ .fd = fd, .operation = .send, .context = context, .callback = callback, .buffer_const = buffer };
    }

    pub fn send_now(self: *FuzzIO, fd: fd_t, buffer: []const u8) ?usize {
        if (!self.prng.chance(self.send_now_success_probability)) return null;
        const local = self.get_conn(fd) orelse return null;
        if (local.closed or local.shutdown_send) return null;

        const space = send_buf_max - local.sending_len;
        if (space == 0) return null;

        const max_send = @min(@as(u32, @intCast(buffer.len)), @as(u32, @intCast(space)));
        const n: u32 = if (self.prng.chance(self.send_partial_probability))
            self.prng.range_inclusive(u32, 1, max_send)
        else
            max_send;

        @memcpy(local.sending[local.sending_len..][0..n], buffer[0..n]);
        local.sending_len += n;

        return @intCast(n);
    }

    pub fn shutdown(self: *FuzzIO, fd: fd_t, how: posix.ShutdownHow) void {
        const c = self.get_conn(fd) orelse return;
        switch (how) {
            .recv => c.shutdown_recv = true,
            .send => c.shutdown_send = true,
            .both => {
                c.shutdown_recv = true;
                c.shutdown_send = true;
            },
        }
    }

    pub fn close(self: *FuzzIO, fd: fd_t) void {
        const c = self.get_conn(fd) orelse return;
        c.closed = true;
    }
};
