//! Sidecar binary protocol fuzzer.
//!
//! Exercises the sidecar client (translate, execute_prefetch,
//! send_prefetch_recv_handle, execute_writes, execute_render) with
//! random/corrupt sidecar responses. The client must never crash —
//! always return null or handle disconnect gracefully.
//!
//! Also fuzzes DeclIterator and skip_params with random binary data.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const sidecar = @import("sidecar.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

const Storage = @import("storage.zig").SqliteStorage;

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    // In-memory storage for execute_prefetch fuzzing.
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    var stats = Stats{};

    for (0..events_max) |_| {
        const event = prng.chances(.{
            .translate_valid = 3,
            .translate_corrupt = 4,
            .translate_disconnect = 2,
            .handle_corrupt = 4,
            .render_corrupt = 3,
            .decl_iterator = 3,
            .prefetch_with_storage = 3,
        });

        switch (event) {
            .translate_valid => fuzz_translate_valid(&prng, &stats),
            .translate_corrupt => fuzz_translate_corrupt(&prng, &stats),
            .translate_disconnect => fuzz_translate_disconnect(&stats),
            .handle_corrupt => fuzz_handle_corrupt(&prng, &stats),
            .render_corrupt => fuzz_render_corrupt(&prng, &stats),
            .decl_iterator => fuzz_decl_iterator(&prng, &stats),
            .prefetch_with_storage => fuzz_prefetch_with_storage(&prng, &stats, &storage),
        }
    }

    log.info(
        \\Sidecar fuzz done:
        \\  events={}
        \\  translate: valid={} corrupt={} disconnect={}
        \\  handle_corrupt={} render_corrupt={}
        \\  decl_iterator={} decl_rejected={}
        \\  prefetch_with_storage={} prefetch_rejected={}
    , .{
        events_max,
        stats.translate_valid,
        stats.translate_corrupt,
        stats.translate_disconnect,
        stats.handle_corrupt,
        stats.render_corrupt,
        stats.decl_iterator,
        stats.decl_rejected,
        stats.prefetch_with_storage,
        stats.prefetch_rejected,
    });

    assert(stats.translate_valid > 0);
    assert(stats.translate_corrupt > 0);
    assert(stats.handle_corrupt > 0);
    assert(stats.decl_iterator > 0);
    assert(stats.prefetch_with_storage > 0);
}

const Stats = struct {
    translate_valid: u64 = 0,
    translate_corrupt: u64 = 0,
    translate_disconnect: u64 = 0,
    handle_corrupt: u64 = 0,
    render_corrupt: u64 = 0,
    decl_iterator: u64 = 0,
    decl_rejected: u64 = 0,
    prefetch_with_storage: u64 = 0,
    prefetch_rejected: u64 = 0,
};

// =====================================================================
// Translate fuzzing
// =====================================================================

fn fuzz_translate_valid(prng: *PRNG, stats: *Stats) void {
    stats.translate_valid += 1;
    const pair = test_socketpair() orelse return;

    // Mock thread sends a valid route_prefetch_response.
    const thread = std.Thread.spawn(.{}, mock_valid_route_response, .{ pair[1], prng.int(u64) }) catch return;

    var client = sidecar.SidecarClient.init("/unused");
    client.fd = pair[0];
    const result = client.translate(.get, "/products/00000000000000000000000000000001", "");

    thread.join();

    // Valid response should parse successfully.
    if (result) |msg| {
        _ = std.meta.intToEnum(message.Operation, @intFromEnum(msg.operation)) catch unreachable;
    }
    client.close();
}

fn fuzz_translate_corrupt(prng: *PRNG, stats: *Stats) void {
    stats.translate_corrupt += 1;
    const pair = test_socketpair() orelse return;

    // Mock thread sends random bytes as a frame.
    const thread = std.Thread.spawn(.{}, mock_random_frame, .{ pair[1], prng.int(u64) }) catch return;

    var client = sidecar.SidecarClient.init("/unused");
    client.fd = pair[0];
    _ = client.translate(.get, "/products", "");

    thread.join();
    client.close();
}

fn fuzz_translate_disconnect(stats: *Stats) void {
    stats.translate_disconnect += 1;
    const pair = test_socketpair() orelse return;

    // Close immediately — client must not crash.
    std.posix.close(pair[1]);

    var client = sidecar.SidecarClient.init("/unused");
    client.fd = pair[0];
    const result = client.translate(.get, "/products", "");

    assert(result == null);
    assert(client.fd == -1);
}

// =====================================================================
// Handle response fuzzing (RT2)
// =====================================================================

fn fuzz_handle_corrupt(prng: *PRNG, stats: *Stats) void {
    stats.handle_corrupt += 1;
    const pair = test_socketpair() orelse return;

    // Mock sends valid RT1 then random RT2 response.
    const thread = std.Thread.spawn(.{}, mock_valid_rt1_random_rt2, .{ pair[1], prng.int(u64) }) catch return;

    var client = sidecar.SidecarClient.init("/unused");
    client.fd = pair[0];

    const msg = client.translate(.get, "/products/00000000000000000000000000000001", "");
    if (msg == null) {
        thread.join();
        client.close();
        return;
    }

    // Build a dummy prefetch result frame (just the tag + empty row set).
    var send_buf = client.send_buf;
    send_buf[0] = @intFromEnum(protocol.MessageTag.prefetch_results);
    std.mem.writeInt(u16, send_buf[1..3], 0, .big); // 0 columns
    std.mem.writeInt(u32, send_buf[3..7], 0, .big); // 0 rows

    _ = client.send_prefetch_recv_handle(7);

    thread.join();
    client.close();
}

// =====================================================================
// Render response fuzzing (RT3)
// =====================================================================

fn fuzz_render_corrupt(prng: *PRNG, stats: *Stats) void {
    stats.render_corrupt += 1;
    const pair = test_socketpair() orelse return;

    // Mock sends valid RT1, valid RT2, then random RT3 response.
    const thread = std.Thread.spawn(.{}, mock_valid_rt1_rt2_random_rt3, .{ pair[1], prng.int(u64) }) catch return;

    var client = sidecar.SidecarClient.init("/unused");
    client.fd = pair[0];

    const msg = client.translate(.get, "/products/00000000000000000000000000000001", "");
    if (msg == null) {
        thread.join();
        client.close();
        return;
    }

    // Dummy prefetch frame.
    var send_buf = client.send_buf;
    send_buf[0] = @intFromEnum(protocol.MessageTag.prefetch_results);
    std.mem.writeInt(u16, send_buf[1..3], 0, .big);
    std.mem.writeInt(u32, send_buf[3..7], 0, .big);

    const status = client.send_prefetch_recv_handle(7);
    if (status == null) {
        thread.join();
        client.close();
        return;
    }

    // Dummy render results frame.
    send_buf[0] = @intFromEnum(protocol.MessageTag.render_results);

    // Mock storage for execute_render — needs query_raw method.
    // Use a null-returning stub since we're testing protocol handling.
    _ = client.execute_render(NullStorage{});

    thread.join();
    client.close();
}

const NullStorage = struct {
    pub fn query_raw(_: NullStorage, _: []const u8, _: []const u8, _: u8, _: protocol.QueryMode, _: []u8) ?[]const u8 {
        return null;
    }
};

// =====================================================================
// DeclIterator fuzzing — random binary input
// =====================================================================

fn fuzz_decl_iterator(prng: *PRNG, stats: *Stats) void {
    stats.decl_iterator += 1;

    var buf: [512]u8 = undefined;
    const len = prng.range_inclusive(usize, 0, buf.len);
    prng.fill(buf[0..len]);

    const data = buf[0..len];
    var iter = sidecar.SidecarClient.DeclIterator.init(data) orelse {
        stats.decl_rejected += 1;
        return;
    };

    // Iterate — must not crash.
    while (iter.next()) |_| {}

    // Also fuzz skip_params directly.
    if (len > 1) {
        const param_count = data[0];
        _ = sidecar.SidecarClient.skip_params(data, 1, param_count);
    }
}

// =====================================================================
// Prefetch with real storage — random declarations → parse → SQL → row set
// =====================================================================

fn fuzz_prefetch_with_storage(prng: *PRNG, stats: *Stats, storage: *Storage) void {
    stats.prefetch_with_storage += 1;

    // Build random prefetch declarations.
    var decl_buf: [512]u8 = undefined;
    var dpos: usize = 0;

    const strategy = prng.chances(.{
        .random_bytes = 3,
        .valid_sql = 3,
        .bad_sql = 2,
    });

    switch (strategy) {
        .random_bytes => {
            // Fully random — exercises parsing rejection.
            const len = prng.range_inclusive(usize, 0, decl_buf.len);
            prng.fill(decl_buf[0..len]);
            dpos = len;
        },
        .valid_sql => {
            // Structurally valid declaration with real SQL.
            decl_buf[dpos] = 1; // 1 query
            dpos += 1;
            const key = "test";
            decl_buf[dpos] = key.len;
            dpos += 1;
            @memcpy(decl_buf[dpos..][0..key.len], key);
            dpos += key.len;
            // SQL that works against any SQLite db.
            const sql = "SELECT 1 AS val";
            std.mem.writeInt(u16, decl_buf[dpos..][0..2], sql.len, .big);
            dpos += 2;
            @memcpy(decl_buf[dpos..][0..sql.len], sql);
            dpos += sql.len;
            decl_buf[dpos] = @intFromEnum(protocol.QueryMode.query);
            dpos += 1;
            decl_buf[dpos] = 0; // 0 params
            dpos += 1;
        },
        .bad_sql => {
            // Structurally valid declaration but SQL is garbage.
            decl_buf[dpos] = 1;
            dpos += 1;
            const key = "x";
            decl_buf[dpos] = key.len;
            dpos += 1;
            decl_buf[dpos] = 'x';
            dpos += 1;
            const sql = "NOT VALID SQL AT ALL";
            std.mem.writeInt(u16, decl_buf[dpos..][0..2], sql.len, .big);
            dpos += 2;
            @memcpy(decl_buf[dpos..][0..sql.len], sql);
            dpos += sql.len;
            decl_buf[dpos] = @intFromEnum(protocol.QueryMode.query);
            dpos += 1;
            decl_buf[dpos] = 0;
            dpos += 1;
        },
    }

    // Create a client with the random declarations as prefetch_decl.
    var client = sidecar.SidecarClient.init("/unused");
    // Don't connect — we're only testing execute_prefetch, not socket IO.
    // Set prefetch_decl directly. The data is in a stack buffer (not
    // recv_buf), so aliasing is not a concern for the fuzz test.
    client.prefetch_decl = decl_buf[0..dpos];

    // Execute prefetch with real storage. Must not crash.
    const ro = Storage.ReadView.init(storage);
    const result = client.execute_prefetch(ro);

    if (result == null) {
        stats.prefetch_rejected += 1;
    }
}

// =====================================================================
// Mock sidecar threads
// =====================================================================

fn mock_valid_route_response(fd: std.posix.fd_t, seed: u64) void {
    defer std.posix.close(fd);
    var prng = PRNG.from_seed(seed);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(fd, &recv_buf) orelse return;

    // Build valid response.
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.route_prefetch_response);
    pos += 1;
    buf[pos] = 1; // found
    pos += 1;
    // Random valid operation (skip root at index 0).
    const op = prng.enum_uniform(message.Operation);
    buf[pos] = @intFromEnum(if (op == .root) message.Operation.get_product else op);
    pos += 1;
    // Random ID.
    prng.fill(buf[pos..][0..16]);
    pos += 16;
    // 0 prefetch declarations.
    buf[pos] = 0;
    pos += 1;

    _ = protocol.write_frame(fd, buf[0..pos]);
}

fn mock_random_frame(fd: std.posix.fd_t, seed: u64) void {
    defer std.posix.close(fd);
    var prng = PRNG.from_seed(seed);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    _ = protocol.read_frame(fd, &recv_buf) orelse return;

    // Send random bytes as a frame.
    var buf: [256]u8 = undefined;
    const len = prng.range_inclusive(usize, 0, buf.len);
    prng.fill(buf[0..len]);
    _ = protocol.write_frame(fd, buf[0..len]);
}

fn mock_valid_rt1_random_rt2(fd: std.posix.fd_t, seed: u64) void {
    defer std.posix.close(fd);
    var prng = PRNG.from_seed(seed);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;

    // RT1: valid response.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.route_prefetch_response);
    pos += 1;
    buf[pos] = 1; // found
    pos += 1;
    buf[pos] = @intFromEnum(message.Operation.get_product);
    pos += 1;
    @memset(buf[pos..][0..15], 0);
    buf[pos + 15] = 1;
    pos += 16;
    buf[pos] = 0; // 0 prefetch declarations
    pos += 1;
    _ = protocol.write_frame(fd, buf[0..pos]);

    // RT2: receive prefetch results, send random response.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;
    var rt2_buf: [256]u8 = undefined;
    const len = prng.range_inclusive(usize, 0, rt2_buf.len);
    prng.fill(rt2_buf[0..len]);
    _ = protocol.write_frame(fd, rt2_buf[0..len]);
}

fn mock_valid_rt1_rt2_random_rt3(fd: std.posix.fd_t, seed: u64) void {
    defer std.posix.close(fd);
    var prng = PRNG.from_seed(seed);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;

    // RT1: valid.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.route_prefetch_response);
    pos += 1;
    buf[pos] = 1;
    pos += 1;
    buf[pos] = @intFromEnum(message.Operation.get_product);
    pos += 1;
    @memset(buf[pos..][0..15], 0);
    buf[pos + 15] = 1;
    pos += 16;
    buf[pos] = 0;
    pos += 1;
    _ = protocol.write_frame(fd, buf[0..pos]);

    // RT2: valid handle response — ok, 0 writes, 0 render decls.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;
    pos = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.handle_render_response);
    pos += 1;
    buf[pos] = @intFromEnum(message.Status.ok);
    pos += 1;
    buf[pos] = 0; // 0 writes
    pos += 1;
    buf[pos] = 0; // 0 render decls
    pos += 1;
    _ = protocol.write_frame(fd, buf[0..pos]);

    // RT3: receive render results, send random response.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;
    var rt3_buf: [256]u8 = undefined;
    const len = prng.range_inclusive(usize, 0, rt3_buf.len);
    prng.fill(rt3_buf[0..len]);
    _ = protocol.write_frame(fd, rt3_buf[0..len]);
}

fn test_socketpair() ?[2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return null;
    return fds;
}
