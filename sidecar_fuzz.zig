//! CALL/RESULT protocol fuzzer.
//!
//! Exercises the sidecar client state machine (call_submit, on_recv)
//! with PRNG-driven malformed responses. The client must never crash —
//! always transition to .failed and recover to .idle.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const sidecar = @import("sidecar.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var stats = Stats{};

    for (0..events_max) |_| {
        const event = prng.chances(.{
            .result_valid = 3,
            .pend_resume = 3,
            .pend_resume_with_query = 3,
            .result_corrupt = 4,
            .result_truncated = 3,
            .result_wrong_tag = 2,
            .disconnect_after_call = 3,
            .disconnect_mid_query = 2,
            .query_result_corrupt = 4,
            .query_result_wrong_id = 2,
            .query_during_no_query = 2,
            .query_count_exceeded = 2,
            .recover_after_failure = 3,
        });

        switch (event) {
            .result_valid => fuzz_result_valid(&prng, &stats),
            .pend_resume => fuzz_pend_resume(&prng, &stats),
            .pend_resume_with_query => fuzz_pend_resume_with_query(&prng, &stats),
            .result_corrupt => fuzz_result_corrupt(&prng, &stats),
            .result_truncated => fuzz_result_truncated(&prng, &stats),
            .result_wrong_tag => fuzz_result_wrong_tag(&prng, &stats),
            .disconnect_after_call => fuzz_disconnect_after_call(&stats),
            .disconnect_mid_query => fuzz_disconnect_mid_query(&prng, &stats),
            .query_result_corrupt => fuzz_query_result_corrupt(&prng, &stats),
            .query_result_wrong_id => fuzz_query_result_wrong_id(&prng, &stats),
            .query_during_no_query => fuzz_query_during_no_query(&prng, &stats),
            .query_count_exceeded => fuzz_query_count_exceeded(&prng, &stats),
            .recover_after_failure => fuzz_recover_after_failure(&prng, &stats),
        }
    }

    log.info(
        \\Sidecar CALL/RESULT fuzz done:
        \\  events={}
        \\  pend_resume={} pend_resume_with_query={}
        \\  result: valid={} corrupt={} truncated={} wrong_tag={}
        \\  disconnect: after_call={} mid_query={}
        \\  query_result: corrupt={} wrong_id={}
        \\  query_during_no_query={} query_count_exceeded={}
        \\  recover_after_failure={}
    , .{
        events_max,
        stats.pend_resume,
        stats.pend_resume_with_query,
        stats.result_valid,
        stats.result_corrupt,
        stats.result_truncated,
        stats.result_wrong_tag,
        stats.disconnect_after_call,
        stats.disconnect_mid_query,
        stats.query_result_corrupt,
        stats.query_result_wrong_id,
        stats.query_during_no_query,
        stats.query_count_exceeded,
        stats.recover_after_failure,
    });

    assert(stats.result_valid > 0);
    assert(stats.pend_resume > 0);
    assert(stats.pend_resume_with_query > 0);
    assert(stats.result_corrupt > 0);
    assert(stats.result_truncated > 0);
    assert(stats.disconnect_after_call > 0);
    assert(stats.query_result_corrupt > 0);
    assert(stats.recover_after_failure > 0);
}

const Stats = struct {
    result_valid: u64 = 0,
    pend_resume: u64 = 0,
    pend_resume_with_query: u64 = 0,
    result_corrupt: u64 = 0,
    result_truncated: u64 = 0,
    result_wrong_tag: u64 = 0,
    disconnect_after_call: u64 = 0,
    disconnect_mid_query: u64 = 0,
    query_result_corrupt: u64 = 0,
    query_result_wrong_id: u64 = 0,
    query_during_no_query: u64 = 0,
    query_count_exceeded: u64 = 0,
    recover_after_failure: u64 = 0,
};

// =====================================================================
// Pend/resume — exercises the async path (call_submit + on_recv)
// without run_to_completion. This is the path commit_dispatch uses
// for sidecar prefetch and render.
// =====================================================================

fn fuzz_pend_resume(prng: *PRNG, stats: *Stats) void {
    stats.pend_resume += 1;
    const pair = test_socketpair() orelse return;

    // Mock thread: read CALL, send valid RESULT.
    const thread = std.Thread.spawn(.{}, mock_valid_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);

    // Step 1: call_submit — sends CALL, transitions to .receiving.
    client.reset_call_state();
    if (!client.call_submit("test", "args")) {
        thread.join();
        return;
    }
    assert(client.call_state == .receiving);

    // Step 2: on_recv — driven one frame at a time (epoll pattern).
    // No run_to_completion. This is the async path.
    const state = client.on_recv(null, null, 0);
    assert(state == .complete or state == .failed);

    if (state == .complete) {
        assert(client.result_flag == .success or client.result_flag == .failure);
    }

    client.reset_call_state();
    assert(client.call_state == .idle);

    thread.join();
    client.close();
}

fn fuzz_pend_resume_with_query(prng: *PRNG, stats: *Stats) void {
    stats.pend_resume_with_query += 1;
    const pair = test_socketpair() orelse return;

    // Mock thread: read CALL, send QUERY, read QUERY_RESULT, send RESULT.
    const thread = std.Thread.spawn(.{}, mock_valid_query_exchange_then_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    var dummy_ctx: u8 = 0;

    // Step 1: call_submit.
    client.reset_call_state();
    if (!client.call_submit("test", "args")) {
        thread.join();
        return;
    }
    assert(client.call_state == .receiving);

    // Step 2: on_recv — first frame is QUERY, client handles it
    // (executes query, sends QUERY_RESULT). Still .receiving.
    var state = client.on_recv(test_query_fn, @ptrCast(&dummy_ctx), 10);
    if (state == .receiving) {
        // Step 3: on_recv — second frame is RESULT. Now .complete.
        state = client.on_recv(test_query_fn, @ptrCast(&dummy_ctx), 10);
    }

    assert(state == .complete or state == .failed);
    if (state == .complete) {
        assert(client.result_flag == .success);
    }

    client.reset_call_state();
    assert(client.call_state == .idle);

    thread.join();
    client.close();
}

// =====================================================================
// Valid RESULT — client should parse successfully
// =====================================================================

fn fuzz_result_valid(prng: *PRNG, stats: *Stats) void {
    stats.result_valid += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_valid_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "args")) {
        _ = client.run_to_completion(null, null, 0);
        if (client.call_state == .complete) {
            assert(client.result_flag == .success or client.result_flag == .failure);
        }
    }
    client.reset_call_state();

    thread.join();
    client.close();
}

// =====================================================================
// Corrupt RESULT — random bytes as frame payload
// =====================================================================

fn fuzz_result_corrupt(prng: *PRNG, stats: *Stats) void {
    stats.result_corrupt += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_random_frame, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        // Must be failed — random bytes can't be a valid RESULT.
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
    // fd is -1 after disconnect.
}

// =====================================================================
// Truncated RESULT — valid tag but not enough bytes
// =====================================================================

fn fuzz_result_truncated(prng: *PRNG, stats: *Stats) void {
    stats.result_truncated += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_truncated_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Wrong tag — send a CALL tag (server→sidecar) instead of RESULT
// =====================================================================

fn fuzz_result_wrong_tag(prng: *PRNG, stats: *Stats) void {
    stats.result_wrong_tag += 1;
    const pair = test_socketpair() orelse return;
    _ = prng;

    const thread = std.Thread.spawn(.{}, mock_wrong_tag, .{pair[1]}) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Disconnect after CALL sent — peer closes before RESULT
// =====================================================================

fn fuzz_disconnect_after_call(stats: *Stats) void {
    stats.disconnect_after_call += 1;
    const pair = test_socketpair() orelse return;

    // Close peer immediately.
    std.posix.close(pair[1]);

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .failed);
        assert(client.fd == -1); // disconnected
    }
    client.reset_call_state();
}

// =====================================================================
// Disconnect mid-QUERY — peer closes after sending QUERY frame
// =====================================================================

fn fuzz_disconnect_mid_query(prng: *PRNG, stats: *Stats) void {
    stats.disconnect_mid_query += 1;
    const pair = test_socketpair() orelse return;

    // Send a QUERY frame then close.
    const thread = std.Thread.spawn(.{}, mock_query_then_disconnect, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        // Allow queries — the mock sends QUERY then disconnects.
        var dummy_ctx: u8 = 0;
        _ = client.run_to_completion(test_query_fn, @ptrCast(&dummy_ctx), 10);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Corrupt QUERY_RESULT — valid QUERY exchange but corrupt RESULT after
// =====================================================================

fn fuzz_query_result_corrupt(prng: *PRNG, stats: *Stats) void {
    stats.query_result_corrupt += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_query_then_corrupt_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        var dummy_ctx: u8 = 0;
        _ = client.run_to_completion(test_query_fn, @ptrCast(&dummy_ctx), 10);
        // Either failed (corrupt) or complete (if the random bytes
        // happened to form a valid RESULT — unlikely but possible).
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Wrong query_id — QUERY_RESULT with non-matching query_id
// =====================================================================

fn fuzz_query_result_wrong_id(prng: *PRNG, stats: *Stats) void {
    stats.query_result_wrong_id += 1;
    const pair = test_socketpair() orelse return;

    // Send valid QUERY, receive QUERY_RESULT (client handles it),
    // then send RESULT with data. The query_id mismatch doesn't
    // cause an error on the Zig side — query_id is echoed for the
    // TS side's Promise matching. The Zig side ignores it.
    const thread = std.Thread.spawn(.{}, mock_valid_query_exchange_then_result, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        var dummy_ctx: u8 = 0;
        _ = client.run_to_completion(test_query_fn, @ptrCast(&dummy_ctx), 10);
    }
    client.reset_call_state();

    thread.join();
    client.close();
}

// =====================================================================
// QUERY during no-query CALL — protocol violation
// =====================================================================

fn fuzz_query_during_no_query(prng: *PRNG, stats: *Stats) void {
    stats.query_during_no_query += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_send_query_frame, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        // No queries allowed (null query_fn).
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Query count exceeded — more QUERY frames than queries_max
// =====================================================================

fn fuzz_query_count_exceeded(prng: *PRNG, stats: *Stats) void {
    stats.query_count_exceeded += 1;
    const pair = test_socketpair() orelse return;

    const thread = std.Thread.spawn(.{}, mock_many_queries, .{ pair[1], prng.int(u64) }) catch return;

    var client = test_client(pair[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        // Allow only 2 queries — mock sends 5.
        var dummy_ctx2: u8 = 0;
        _ = client.run_to_completion(test_query_fn, @ptrCast(&dummy_ctx2), 2);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();

    thread.join();
}

// =====================================================================
// Recovery — failure then successful exchange
// =====================================================================

fn fuzz_recover_after_failure(prng: *PRNG, stats: *Stats) void {
    stats.recover_after_failure += 1;

    // First: disconnect (failure).
    const pair1 = test_socketpair() orelse return;
    std.posix.close(pair1[1]);

    var client = test_client(pair1[0]);
    client.reset_call_state();
    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .failed);
    }
    client.reset_call_state();
    assert(client.call_state == .idle);

    // Second: valid exchange on a new socketpair.
    const pair2 = test_socketpair() orelse return;
    client.fd = pair2[0];

    const thread = std.Thread.spawn(.{}, mock_valid_result, .{ pair2[1], prng.int(u64) }) catch return;

    if (client.call_submit("test", "")) {
        _ = client.run_to_completion(null, null, 0);
        assert(client.call_state == .complete);
    }
    client.reset_call_state();

    thread.join();
    client.close();
}

// =====================================================================
// Mock sidecar threads — write frames to the peer socket
// =====================================================================

fn mock_valid_result(peer_fd: std.posix.fd_t, seed: u64) void {
    var prng = PRNG.from_seed(seed);

    // Read and discard the CALL frame.
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send valid RESULT: [tag][request_id][flag][data...]
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.result);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    const flag: u8 = if (prng.boolean()) @intFromEnum(protocol.ResultFlag.success) else @intFromEnum(protocol.ResultFlag.failure);
    buf[5] = flag;
    const data_len = prng.range_inclusive(u8, 0, 20);
    for (0..data_len) |i| buf[6 + i] = prng.int(u8);
    _ = protocol.write_frame(peer_fd, buf[0 .. 6 + data_len]);
    std.posix.close(peer_fd);
}

fn mock_random_frame(peer_fd: std.posix.fd_t, seed: u64) void {
    var prng = PRNG.from_seed(seed);

    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Random bytes as a frame.
    var buf: [128]u8 = undefined;
    const len = prng.range_inclusive(u8, 1, 128);
    for (0..len) |i| buf[i] = prng.int(u8);
    _ = protocol.write_frame(peer_fd, buf[0..len]);
    std.posix.close(peer_fd);
}

fn mock_truncated_result(peer_fd: std.posix.fd_t, seed: u64) void {
    var prng = PRNG.from_seed(seed);

    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // RESULT tag but truncated — less than 6 bytes (tag + request_id + flag).
    var buf: [4]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.result);
    const len = prng.range_inclusive(u8, 1, 4);
    _ = protocol.write_frame(peer_fd, buf[0..len]);
    std.posix.close(peer_fd);
}

fn mock_wrong_tag(peer_fd: std.posix.fd_t) void {
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send CALL tag (0x10) — server→sidecar, not sidecar→server.
    var buf: [16]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.call);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    std.mem.writeInt(u16, buf[5..7], 4, .big);
    @memcpy(buf[7..11], "test");
    _ = protocol.write_frame(peer_fd, buf[0..11]);
    std.posix.close(peer_fd);
}

fn mock_query_then_disconnect(peer_fd: std.posix.fd_t, seed: u64) void {
    _ = seed;
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send a QUERY frame.
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.query);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    std.mem.writeInt(u16, buf[5..7], 0, .big); // query_id
    const sql = "SELECT 1";
    std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
    @memcpy(buf[9..17], sql);
    buf[17] = @intFromEnum(protocol.QueryMode.query);
    buf[18] = 0; // param_count
    _ = protocol.write_frame(peer_fd, buf[0..19]);

    // Read QUERY_RESULT (client sends it), then disconnect.
    _ = protocol.read_frame(peer_fd, &discard);
    std.posix.close(peer_fd);
}

fn mock_query_then_corrupt_result(peer_fd: std.posix.fd_t, seed: u64) void {
    var prng = PRNG.from_seed(seed);

    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send QUERY, read QUERY_RESULT, then send random bytes as RESULT.
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.query);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    std.mem.writeInt(u16, buf[5..7], 0, .big);
    const sql = "SELECT 1";
    std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
    @memcpy(buf[9..17], sql);
    buf[17] = @intFromEnum(protocol.QueryMode.query);
    buf[18] = 0;
    _ = protocol.write_frame(peer_fd, buf[0..19]);

    _ = protocol.read_frame(peer_fd, &discard);

    // Random bytes as "RESULT".
    var rbuf: [64]u8 = undefined;
    const len = prng.range_inclusive(u8, 1, 64);
    for (0..len) |i| rbuf[i] = prng.int(u8);
    _ = protocol.write_frame(peer_fd, rbuf[0..len]);
    std.posix.close(peer_fd);
}

fn mock_valid_query_exchange_then_result(peer_fd: std.posix.fd_t, seed: u64) void {
    _ = seed;
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // QUERY with query_id=99.
    var buf: [64]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.query);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    std.mem.writeInt(u16, buf[5..7], 99, .big); // query_id
    const sql = "SELECT 1";
    std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
    @memcpy(buf[9..17], sql);
    buf[17] = @intFromEnum(protocol.QueryMode.query);
    buf[18] = 0;
    _ = protocol.write_frame(peer_fd, buf[0..19]);

    // Read QUERY_RESULT.
    _ = protocol.read_frame(peer_fd, &discard);

    // Send valid RESULT.
    buf[0] = @intFromEnum(protocol.CallTag.result);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    buf[5] = @intFromEnum(protocol.ResultFlag.success);
    _ = protocol.write_frame(peer_fd, buf[0..6]);
    std.posix.close(peer_fd);
}

fn mock_send_query_frame(peer_fd: std.posix.fd_t, seed: u64) void {
    _ = seed;
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send QUERY frame — protocol violation if queries not allowed.
    var buf: [32]u8 = undefined;
    buf[0] = @intFromEnum(protocol.CallTag.query);
    std.mem.writeInt(u32, buf[1..5], 0, .big);
    std.mem.writeInt(u16, buf[5..7], 0, .big);
    const sql = "SELECT 1";
    std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
    @memcpy(buf[9..17], sql);
    buf[17] = @intFromEnum(protocol.QueryMode.query);
    buf[18] = 0;
    _ = protocol.write_frame(peer_fd, buf[0..19]);
    std.posix.close(peer_fd);
}

fn mock_many_queries(peer_fd: std.posix.fd_t, seed: u64) void {
    _ = seed;
    var discard: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(peer_fd, &discard);

    // Send 5 QUERY frames — exceeds queries_max=2.
    for (0..5) |i| {
        var buf: [32]u8 = undefined;
        buf[0] = @intFromEnum(protocol.CallTag.query);
        std.mem.writeInt(u32, buf[1..5], 0, .big);
        std.mem.writeInt(u16, buf[5..7], @intCast(i), .big);
        const sql = "SELECT 1";
        std.mem.writeInt(u16, buf[7..9], @intCast(sql.len), .big);
        @memcpy(buf[9..17], sql);
        buf[17] = @intFromEnum(protocol.QueryMode.query);
        buf[18] = 0;
        if (!protocol.write_frame(peer_fd, buf[0..19])) break;

        // Read QUERY_RESULT (if client sends one).
        _ = protocol.read_frame(peer_fd, &discard);
    }
    std.posix.close(peer_fd);
}

// =====================================================================
// Test helpers
// =====================================================================

/// Dummy query function for on_recv — returns empty row set.
fn test_query_fn(
    _: ?*anyopaque,
    _: []const u8,
    _: []const u8,
    _: u8,
    _: protocol.QueryMode,
    _: []u8,
) ?[]const u8 {
    return "";
}

fn test_client(fd: std.posix.fd_t) sidecar.SidecarClient {
    var client = sidecar.SidecarClient.init("/unused");
    client.fd = fd;
    return client;
}

fn test_socketpair() ?[2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return null;
    return fds;
}
