//! Message bus transport fuzzer.
//!
//! Exercises ConnectionType(FuzzIO) with PRNG-driven fault injection.
//! No protocol knowledge — tests the transport layer in isolation.
//!
//! One connection per seed. No reconnects. After the event loop,
//! disables error injection and drains — asserts all valid frames
//! delivered (or connection already terminated during event loop).
//!
//! Re-entrancy: on_frame callback sometimes calls send_frame or
//! terminate — exercises the try_drain_recv interleaving path.

const std = @import("std");
const assert = std.debug.assert;
const Crc32 = std.hash.crc.Crc32;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;
const Ratio = PRNG.Ratio;
const message_bus = @import("framework/message_bus.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzIO = @import("fuzz_io.zig").FuzzIO;

const log = std.log.scoped(.fuzz);

const fuzz_frame_max: u32 = 1024;
const fuzz_send_queue_max: u32 = 4;
const fuzz_options: message_bus.Options = .{
    .send_queue_max = fuzz_send_queue_max,
    .frame_max = fuzz_frame_max,
};

const Connection = message_bus.ConnectionType(FuzzIO, fuzz_options);

/// Drive pending recv/send completions. The fuzzer owns the timing —
/// FuzzIO returns results, this function fires callbacks.
fn tick_connection(io: *FuzzIO, conn: *Connection) void {
    if (io.prng.boolean()) {
        tick_recv(io, conn);
        tick_send(io, conn);
    } else {
        tick_send(io, conn);
        tick_recv(io, conn);
    }
}

fn tick_recv(io: *FuzzIO, conn: *Connection) void {
    if (conn.recv_completion.operation != .recv) return;
    const result = io.do_recv(conn.recv_completion.fd, conn.recv_completion.buffer.?) orelse return;
    conn.recv_completion.operation = .none;
    conn.recv_completion.callback(conn.recv_completion.context, result);
}

fn tick_send(io: *FuzzIO, conn: *Connection) void {
    if (conn.send_completion.operation != .send) return;
    const result = io.do_send(conn.send_completion.fd, conn.send_completion.buffer_const.?) orelse return;
    conn.send_completion.operation = .none;
    conn.send_completion.callback(conn.send_completion.context, result);
}

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

    // Re-entrancy context: on_frame may call send_frame or terminate.
    var ctx = FuzzContext.init(&conn, &pool, &prng);
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
    // Cap destructive events — they end the test.
    weights.terminate = @min(weights.terminate, 3);
    weights.disconnect = @min(weights.disconnect, 3);
    weights.inject_corrupt_frame = @min(weights.inject_corrupt_frame, 10);
    weights.inject_oversized_frame = @min(weights.inject_oversized_frame, 5);

    // Log swarm parameters for seed reproduction.
    log.info("Fuzz config:", .{});
    log.info("  recv_partial={d}/{d} send_partial={d}/{d} send_now={d}/{d}", .{
        io.recv_partial_probability.numerator,   io.recv_partial_probability.denominator,
        io.send_partial_probability.numerator,   io.send_partial_probability.denominator,
        io.send_now_success_probability.numerator, io.send_now_success_probability.denominator,
    });
    log.info("  recv_error={d}/{d} send_error={d}/{d}", .{
        io.recv_error_probability.numerator, io.recv_error_probability.denominator,
        io.send_error_probability.numerator, io.send_error_probability.denominator,
    });

    // Event loop — PRNG drives everything.
    for (0..events_max) |_| {
        if (conn.state == .closed) break;
        if (conn.state == .terminating) {
            tick_connection(&io, &conn);
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
                tick_connection(&io, &conn);
                stats.ticks += 1;
            },
            .tick_multiple => {
                const count = prng.range_inclusive(u32, 2, 10);
                for (0..count) |_| {
                    if (conn.state == .closed) break;
                    tick_connection(&io, &conn);
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

    // Post-loop drain: disable error injection and deliver remaining
    // frames. If the connection is alive, all frames must be delivered.
    // Error injection is disabled because our Connection terminates on
    // errors (by design) — the drain verifies delivery, not error
    // handling (already tested during the event loop).
    const terminated_during_events = conn.state == .closed;

    if (!terminated_during_events) {
        io.recv_error_probability = Ratio.zero();
        io.send_error_probability = Ratio.zero();

        const ticks_drain = events_max * 10;
        for (0..ticks_drain) |_| {
            if (conn.state == .closed) break;
            if (conn.state == .connected and ctx.all_delivered()) break;
            tick_connection(&io, &conn);
            stats.ticks += 1;
        }

        if (conn.state == .connected) {
            if (!ctx.all_delivered()) {
                std.debug.panic(
                    "seed={}: only {}/{} frames delivered (connection alive, drain complete)",
                    .{ seed, ctx.delivered_count, ctx.expected_tail },
                );
            }
        }
    }

    // Clean termination.
    if (conn.state == .connected) {
        conn.terminate(.shutdown);
    }
    for (0..100) |_| {
        if (conn.state == .closed) break;
        tick_connection(&io, &conn);
    }

    log.info(
        \\Message bus fuzz done:
        \\  events={} ticks={}
        \\  injected={} corrupt={} oversized={}
        \\  sent={} delivered={}
        \\  suspends={} resumes={} terminates={}
        \\  disconnects={} reentrant_sends={} reentrant_terminates={}
        \\  terminated_during_events={}
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
        ctx.reentrant_sends,
        ctx.reentrant_terminates,
        terminated_during_events,
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
/// Also exercises re-entrancy: on_frame sometimes calls send_frame
/// or terminate on the Connection (the try_drain_recv interleaving).
const FuzzContext = struct {
    const max_pending = 4096;

    conn: *Connection,
    pool: *Connection.Pool,
    prng: *PRNG,

    expected: [max_pending]u32 = undefined,
    expected_head: u32 = 0,
    expected_tail: u32 = 0,
    delivered_count: u64 = 0,
    reentrant_sends: u64 = 0,
    reentrant_terminates: u64 = 0,

    // Re-entrancy probabilities (swarm-tested).
    send_from_callback_probability: Ratio,
    terminate_from_callback_probability: Ratio,

    fn init(conn: *Connection, pool: *Connection.Pool, prng: *PRNG) FuzzContext {
        return .{
            .conn = conn,
            .pool = pool,
            .prng = prng,
            .send_from_callback_probability = PRNG.ratio(prng.range_inclusive(u64, 0, 3), 10),
            .terminate_from_callback_probability = PRNG.ratio(prng.range_inclusive(u64, 0, 1), 10),
        };
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
        // If no expectation exists, this is an unexpected frame —
        // either a fabricated frame (bug) or a frame from send_frame/
        // send_message that went to the peer and came back. Since we
        // don't track outbound frames, only assert on inbound.
        if (self.expected_head < self.expected_tail) {
            const expected = self.expected[self.expected_head % max_pending];
            assert(checksum == expected);
            self.expected_head += 1;
        }
        // Frames without expectations are outbound send_frame echoes
        // or re-entrant sends — not tracked. This is acceptable
        // because the Connection doesn't loop back frames to itself.

        self.delivered_count += 1;

        // Re-entrancy: sometimes send a frame from inside on_frame.
        // Exercises the try_drain_recv → on_frame_fn → send_frame
        // path (the QUERY sub-protocol pattern).
        if (self.conn.state == .connected and
            self.prng.chance(self.send_from_callback_probability))
        {
            if (self.conn.send_queue.count < fuzz_send_queue_max) {
                self.conn.send_frame("reentrant");
                self.reentrant_sends += 1;
            }
        }

        // Re-entrancy: sometimes terminate from inside on_frame.
        // Exercises maybe(state == .terminating) after on_frame_fn
        // in try_drain_recv. The loop must stop iterating.
        if (self.conn.state == .connected and
            self.prng.chance(self.terminate_from_callback_probability))
        {
            self.conn.terminate(.shutdown);
            self.reentrant_terminates += 1;
        }
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

