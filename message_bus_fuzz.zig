//! Message bus transport fuzzer.
//!
//! Exercises ConnectionType(FuzzIO) with PRNG-driven fault injection.
//! No protocol knowledge — tests the transport layer in isolation.
//!
//! One connection per seed. No reconnects — disconnect or terminate
//! ends the test. After the event loop, assert all valid frames
//! delivered (or connection cleanly terminated). TB pattern:
//! assert delivery at the end, not cooperatively during the run.
//!
//! FuzzIO is embedded here (TB pattern: IO simulation is purpose-built
//! for the fuzzer, not a reusable module).

const std = @import("std");
const posix = std.posix;
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const Ratio = PRNG.Ratio;
const message_bus = @import("framework/message_bus.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const fuzz_lib = @import("fuzz_lib.zig");

const log = std.log.scoped(.fuzz);

const fuzz_frame_max: u32 = 1024;
const fuzz_send_queue_max: u32 = 4;
const fuzz_options: message_bus.Options = .{
    .send_queue_max = fuzz_send_queue_max,
    .frame_max = fuzz_frame_max,
};

const Connection = message_bus.ConnectionType(FuzzIO, fuzz_options);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var io = FuzzIO.init(&prng);

    var pool = try Connection.Pool.init(allocator, 8);
    defer pool.deinit(allocator);

    const pair = io.create_socketpair();

    var conn: Connection = undefined;
    conn.state = .closed;
    conn.recv_message = null;
    conn.recv_completion = .{};
    conn.send_completion = .{};

    var ctx = FuzzContext.init();
    conn.init(&io, &pool, pair[0], @ptrCast(&ctx), FuzzContext.on_frame, null);

    var stats = Stats{};

    const Event = enum {
        inject_valid_frame,
        inject_corrupt_frame,
        inject_oversized_frame,
        send_frame,
        send_message_zerocopy,
        tick,
        tick_multiple,
        suspend_recv,
        resume_recv,
        terminate,
        disconnect,
    };
    var weights = fuzz_lib.random_enum_weights(&prng, Event);
    if (weights.tick == 0 and weights.tick_multiple == 0) weights.tick = 1;
    if (weights.inject_valid_frame == 0) weights.inject_valid_frame = 1;
    // Cap destructive events — they end the test. Without caps,
    // most seeds terminate in the first few events and never
    // exercise sustained frame exchanges.
    weights.terminate = @min(weights.terminate, 3);
    weights.disconnect = @min(weights.disconnect, 3);
    weights.inject_corrupt_frame = @min(weights.inject_corrupt_frame, 10);
    weights.inject_oversized_frame = @min(weights.inject_oversized_frame, 5);

    // Event loop — PRNG drives everything. No cooperative mode.
    for (0..events_max) |_| {
        // Connection dead — stop. One connection per seed.
        if (conn.state == .closed) break;
        if (conn.state == .terminating) {
            io.tick(&conn);
            stats.ticks += 1;
            continue;
        }

        const event = prng.enum_weighted(Event, weights);

        switch (event) {
            .inject_valid_frame => {
                const payload_len = prng.range_inclusive(u32, 0, fuzz_frame_max);
                var payload: [fuzz_frame_max]u8 = undefined;
                prng.fill(payload[0..payload_len]);

                var frame_buf: [fuzz_frame_max + 8]u8 = undefined;
                const frame = build_wire_frame(&frame_buf, payload[0..payload_len]);

                if (!io.inject_data(pair[1], frame)) continue;

                ctx.expect_frame(payload[0..payload_len]);
                stats.frames_injected += 1;
            },
            .inject_corrupt_frame => {
                const payload_len = prng.range_inclusive(u32, 1, fuzz_frame_max);
                var payload: [fuzz_frame_max]u8 = undefined;
                prng.fill(payload[0..payload_len]);

                var frame_buf: [fuzz_frame_max + 8]u8 = undefined;
                _ = build_wire_frame(&frame_buf, payload[0..payload_len]);

                const frame_total = 8 + payload_len;
                const corrupt_pos = prng.range_inclusive(u32, 0, frame_total - 1);
                frame_buf[corrupt_pos] ^= prng.range_inclusive(u8, 1, 255);

                _ = io.inject_data(pair[1], frame_buf[0..frame_total]);
                stats.frames_corrupt += 1;
            },
            .inject_oversized_frame => {
                var buf: [8]u8 = undefined;
                const bad_len = fuzz_frame_max + prng.range_inclusive(u32, 1, 1000);
                std.mem.writeInt(u32, buf[0..4], bad_len, .big);
                prng.fill(buf[4..8]);
                _ = io.inject_data(pair[1], &buf);
                stats.oversized_frames += 1;
            },
            .send_frame => {
                if (conn.state != .connected) continue;
                if (conn.send_queue.count >= fuzz_send_queue_max) continue;
                const payload_len = prng.range_inclusive(u32, 0, @min(256, fuzz_frame_max));
                var payload: [fuzz_frame_max]u8 = undefined;
                prng.fill(payload[0..payload_len]);
                conn.send_frame(payload[0..payload_len]);
                stats.frames_sent += 1;
            },
            .send_message_zerocopy => {
                if (conn.state != .connected) continue;
                if (conn.send_queue.count >= fuzz_send_queue_max) continue;
                const msg = pool.get_message();
                const payload_len = prng.range_inclusive(u32, 0, @min(256, fuzz_frame_max));
                prng.fill(msg.buffer[Connection.frame_header_size..][0..payload_len]);
                conn.send_message(msg, payload_len);
                stats.frames_sent += 1;
            },
            .tick => {
                io.tick(&conn);
                stats.ticks += 1;
            },
            .tick_multiple => {
                const count = prng.range_inclusive(u32, 2, 10);
                for (0..count) |_| {
                    if (conn.state == .closed) break;
                    io.tick(&conn);
                    stats.ticks += 1;
                }
            },
            .suspend_recv => {
                if (conn.state != .connected) continue;
                if (conn.recv_suspended) continue;
                if (conn.recv_submitted) continue;
                conn.suspend_recv();
                stats.suspends += 1;
            },
            .resume_recv => {
                if (conn.state != .connected) continue;
                if (!conn.recv_suspended) continue;
                conn.resume_recv();
                stats.resumes += 1;
            },
            .terminate => {
                if (conn.state != .connected) continue;
                conn.terminate(.shutdown);
                stats.terminates += 1;
            },
            .disconnect => {
                if (conn.state != .connected) continue;
                io.close_peer(pair[1]);
                stats.disconnects += 1;
            },
        }
    }

    // Post-loop: tick remaining IO to deliver pending frames.
    // Error injection stays on — the transport must deliver despite
    // errors, or terminate cleanly. No cooperative mode.
    const ticks_drain = events_max * 10;
    for (0..ticks_drain) |_| {
        if (conn.state == .closed) break;
        if (conn.state == .connected and ctx.all_delivered()) break;
        io.tick(&conn);
        stats.ticks += 1;
    }

    // Final assertion: if connection is alive, all frames must be
    // delivered. If connection died (error, disconnect, corrupt),
    // that's a valid outcome — but we track it.
    if (conn.state == .connected) {
        if (!ctx.all_delivered()) {
            std.debug.panic(
                "seed={}: only {}/{} frames delivered (connection still alive)",
                .{ seed, ctx.delivered_count, ctx.expected_tail },
            );
        }
    }

    // Clean termination.
    if (conn.state == .connected) {
        conn.terminate(.shutdown);
    }
    for (0..100) |_| {
        if (conn.state == .closed) break;
        io.tick(&conn);
    }

    log.info(
        \\Message bus fuzz done:
        \\  events={} ticks={}
        \\  injected={} corrupt={} oversized={}
        \\  sent={} delivered={}
        \\  suspends={} resumes={} terminates={}
        \\  disconnects={} connection_alive={}
    , .{
        events_max,
        stats.ticks,
        stats.frames_injected,
        stats.frames_corrupt,
        stats.oversized_frames,
        stats.frames_sent,
        ctx.delivered_count,
        stats.suspends,
        stats.resumes,
        stats.terminates,
        stats.disconnects,
        conn.state != .closed,
    });

    assert(stats.ticks > 0);
}

const Stats = struct {
    frames_injected: u64 = 0,
    frames_corrupt: u64 = 0,
    frames_sent: u64 = 0,
    oversized_frames: u64 = 0,
    ticks: u64 = 0,
    suspends: u64 = 0,
    resumes: u64 = 0,
    terminates: u64 = 0,
    disconnects: u64 = 0,
};

/// Tracks expected and delivered frames for verification.
/// Delivered frames must match injected frames in order.
const FuzzContext = struct {
    const max_pending = 4096;

    expected: [max_pending]u32 = undefined,
    expected_head: u32 = 0,
    expected_tail: u32 = 0,
    delivered_count: u64 = 0,

    fn init() FuzzContext {
        return .{};
    }

    fn all_delivered(self: *const FuzzContext) bool {
        return self.expected_head == self.expected_tail;
    }

    fn expect_frame(self: *FuzzContext, payload: []const u8) void {
        assert(self.expected_tail - self.expected_head < max_pending);
        self.expected[self.expected_tail % max_pending] = frame_checksum(payload);
        self.expected_tail += 1;
    }

    fn on_frame(ctx_ptr: *anyopaque, frame: []const u8) void {
        const self: *FuzzContext = @ptrCast(@alignCast(ctx_ptr));
        const checksum = frame_checksum(frame);

        // Verify delivered frame matches next expected.
        if (self.expected_head < self.expected_tail) {
            const expected = self.expected[self.expected_head % max_pending];
            assert(checksum == expected);
            self.expected_head += 1;
        }

        self.delivered_count += 1;
    }
};

fn frame_checksum(payload: []const u8) u32 {
    var crc = Crc32.init();
    crc.update(payload);
    return crc.final();
}

fn build_wire_frame(buf: []u8, payload: []const u8) []const u8 {
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

// =====================================================================
// FuzzIO — synthetic IO for transport fuzzing
// =====================================================================

const FuzzIO = struct {
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

    const max_connections = 4; // Only need one socketpair
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

    recv_partial_probability: Ratio,
    send_partial_probability: Ratio,
    send_now_success_probability: Ratio,
    recv_error_probability: Ratio,

    fn init(prng: *PRNG) FuzzIO {
        return .{
            .prng = prng,
            .recv_partial_probability = PRNG.ratio(prng.range_inclusive(u64, 2, 8), 10),
            .send_partial_probability = PRNG.ratio(prng.range_inclusive(u64, 2, 8), 10),
            .send_now_success_probability = PRNG.ratio(prng.range_inclusive(u64, 3, 9), 10),
            .recv_error_probability = PRNG.ratio(prng.range_inclusive(u64, 0, 1), 10),
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

    fn create_socketpair(self: *FuzzIO) [2]fd_t {
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

    fn inject_data(self: *FuzzIO, fd: fd_t, data: []const u8) bool {
        const c = self.get_conn(fd) orelse return false;
        if (c.closed) return false;
        const space = send_buf_max - c.sending_len;
        if (data.len > space) return false;
        @memcpy(c.sending[c.sending_len..][0..data.len], data);
        c.sending_len += @intCast(data.len);
        return true;
    }

    fn close_peer(self: *FuzzIO, fd: fd_t) void {
        const c = self.get_conn(fd) orelse return;
        c.closed = true;
    }

    /// Drive pending IO. Only completes when data is available or
    /// error/EOF. Randomly chooses recv-first or send-first.
    fn tick(self: *FuzzIO, conn: *Connection) void {
        if (self.prng.boolean()) {
            self.tick_recv(conn);
            self.tick_send(conn);
        } else {
            self.tick_send(conn);
            self.tick_recv(conn);
        }
    }

    fn tick_recv(self: *FuzzIO, conn: *Connection) void {
        if (conn.recv_completion.operation != .recv) return;

        const fd = conn.recv_completion.fd;
        const local = self.get_conn(fd) orelse {
            conn.recv_completion.operation = .none;
            conn.recv_completion.callback(conn.recv_completion.context, -1);
            return;
        };

        if (local.closed or local.shutdown_recv) {
            conn.recv_completion.operation = .none;
            conn.recv_completion.callback(conn.recv_completion.context, 0);
            return;
        }

        if (self.prng.chance(self.recv_error_probability)) {
            conn.recv_completion.operation = .none;
            conn.recv_completion.callback(conn.recv_completion.context, -1);
            return;
        }

        const peer_fd = local.remote_fd orelse return;
        const peer = self.get_conn(peer_fd) orelse {
            conn.recv_completion.operation = .none;
            conn.recv_completion.callback(conn.recv_completion.context, 0);
            return;
        };

        const available = peer.sending_len - peer.sending_offset;
        if (available == 0) {
            if (peer.closed) {
                conn.recv_completion.operation = .none;
                conn.recv_completion.callback(conn.recv_completion.context, 0);
                return;
            }
            return; // No data — leave pending
        }

        const buffer = conn.recv_completion.buffer.?;
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

        conn.recv_completion.operation = .none;
        conn.recv_completion.callback(conn.recv_completion.context, @intCast(n));
    }

    fn tick_send(self: *FuzzIO, conn: *Connection) void {
        if (conn.send_completion.operation != .send) return;

        const fd = conn.send_completion.fd;
        const local = self.get_conn(fd) orelse {
            conn.send_completion.operation = .none;
            conn.send_completion.callback(conn.send_completion.context, -1);
            return;
        };

        if (local.closed or local.shutdown_send) {
            conn.send_completion.operation = .none;
            conn.send_completion.callback(conn.send_completion.context, -1);
            return;
        }

        const buffer = conn.send_completion.buffer_const.?;
        const space = send_buf_max - local.sending_len;
        if (space == 0) return; // Buffer full — leave pending

        const max_send = @min(@as(u32, @intCast(buffer.len)), @as(u32, @intCast(space)));
        const n: u32 = if (self.prng.chance(self.send_partial_probability))
            self.prng.range_inclusive(u32, 1, max_send)
        else
            max_send;

        @memcpy(local.sending[local.sending_len..][0..n], buffer[0..n]);
        local.sending_len += n;

        conn.send_completion.operation = .none;
        conn.send_completion.callback(conn.send_completion.context, @intCast(n));
    }

    // IO interface
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
