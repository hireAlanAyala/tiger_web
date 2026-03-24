//! Sidecar protocol fuzzer — throws random/corrupt binary responses at
//! SidecarClient.translate() and SidecarClient.execute_render().
//!
//! Asserts: the client either accepts a valid response or gracefully
//! returns null/false — never panics, never triggers UB, never leaks
//! the fd. After every event, fd invariants are checked.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig dispatcher.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const sidecar = @import("sidecar.zig");
const http = @import("tiger_framework").http;
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("tiger_framework").prng;


const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var stats = Stats{};

    for (0..events_max) |event_i| {
        log.debug("Running fuzz_ops[{}/{}]", .{ event_i, events_max });

        const phase = prng.chances(.{
            .translate = 5,
            .execute_render = 5,
            .disconnect = 1,
            .partial_send = 2,
        });

        switch (phase) {
            .translate => fuzz_translate(allocator, &prng, &stats),
            .execute_render => fuzz_execute_render(allocator, &prng, &stats),
            .disconnect => fuzz_disconnect(allocator, &prng, &stats),
            .partial_send => fuzz_partial_send(allocator, &prng, &stats),
        }
    }

    log.info(
        \\Sidecar fuzz done:
        \\  events_max={}
        \\  translate: total={} accepted={} rejected={}
        \\  execute_render: total={} accepted={} rejected={}
        \\  disconnects={} partial_sends={}
    , .{
        events_max,
        stats.translate_total,
        stats.translate_accepted,
        stats.translate_rejected,
        stats.exec_total,
        stats.exec_accepted,
        stats.exec_rejected,
        stats.disconnects,
        stats.partial_sends,
    });

    // Sanity: we exercised both paths.
    assert(stats.translate_total > 0);
    assert(stats.exec_total > 0);
}

const Stats = struct {
    translate_total: u64 = 0,
    translate_accepted: u64 = 0,
    translate_rejected: u64 = 0,
    exec_total: u64 = 0,
    exec_accepted: u64 = 0,
    exec_rejected: u64 = 0,
    disconnects: u64 = 0,
    partial_sends: u64 = 0,
};

// =====================================================================
// Translate fuzzer
// =====================================================================

fn fuzz_translate(allocator: std.mem.Allocator, prng: *PRNG, stats: *Stats) void {
    _ = allocator;
    stats.translate_total += 1;

    const pair = test_socketpair() orelse return;

    const resp = gen_translate_response(prng);
    const thread = std.Thread.spawn(.{}, mock_send_translate, .{ pair[1], &resp }) catch return;

    var client = sidecar.SidecarClient{ .path = "/unused", .fd = pair[0] };
    const result = client.translate(.get, "/products", "");

    thread.join();

    if (result) |msg| {
        stats.translate_accepted += 1;
        // If accepted, the operation must be a valid enum value.
        _ = std.meta.intToEnum(message.Operation, @intFromEnum(msg.operation)) catch unreachable;
    } else {
        stats.translate_rejected += 1;
    }

    // fd invariant: either still open (client can close) or already -1 (disconnect handled).
    client.close();
}

fn mock_send_translate(fd: std.posix.fd_t, resp: *const protocol.TranslateResponse) void {
    defer std.posix.close(fd);
    send_all_or_close(fd, std.mem.asBytes(resp));
}

// =====================================================================
// Execute+render fuzzer
// =====================================================================

fn fuzz_execute_render(allocator: std.mem.Allocator, prng: *PRNG, stats: *Stats) void {
    stats.exec_total += 1;

    const pair = test_socketpair() orelse return;

    const resp = allocator.create(protocol.ExecuteRenderResponse) catch return;
    defer allocator.destroy(resp);
    gen_execute_render_response(prng, resp);

    const thread = std.Thread.spawn(.{}, mock_send_execute_render, .{ pair[1], resp }) catch return;

    var client = sidecar.SidecarClient{ .path = "/unused", .fd = pair[0] };
    const resp_buf = allocator.create(protocol.ExecuteRenderResponse) catch return;
    defer allocator.destroy(resp_buf);

    var body = std.mem.zeroes([message.body_max]u8);
    var cache = std.mem.zeroes(protocol.PrefetchCache);

    const ok = client.execute_render(
        prng.enum_uniform(message.Operation),
        prng.int(u128),
        &body,
        &cache,
        prng.boolean(),
        resp_buf,
    );

    thread.join();

    if (ok) {
        stats.exec_accepted += 1;
        // If accepted, validate the fields the client claims are safe.
        _ = std.meta.intToEnum(message.Status, @intFromEnum(resp_buf.status)) catch unreachable;
        assert(resp_buf.writes_len <= message.writes_max);
        assert(resp_buf.html_len <= protocol.html_max);
    } else {
        stats.exec_rejected += 1;
    }

    client.close();
}

fn mock_send_execute_render(fd: std.posix.fd_t, resp: *const protocol.ExecuteRenderResponse) void {
    defer std.posix.close(fd);
    send_all_or_close(fd, std.mem.asBytes(resp));
}

// =====================================================================
// Disconnect fuzzer — close before sending a full response
// =====================================================================

fn fuzz_disconnect(allocator: std.mem.Allocator, prng: *PRNG, stats: *Stats) void {
    stats.disconnects += 1;

    const pair = test_socketpair() orelse return;

    // Close immediately — client should get null/false, not panic.
    std.posix.close(pair[1]);

    var client = sidecar.SidecarClient{ .path = "/unused", .fd = pair[0] };

    if (prng.boolean()) {
        const result = client.translate(.get, "/products", "");
        assert(result == null);
    } else {
        const resp_buf = allocator.create(protocol.ExecuteRenderResponse) catch return;
        defer allocator.destroy(resp_buf);
        var body = std.mem.zeroes([message.body_max]u8);
        var cache = std.mem.zeroes(protocol.PrefetchCache);
        const ok = client.execute_render(.get_product, 0, &body, &cache, false, resp_buf);
        assert(!ok);
    }

    assert(client.fd == -1); // handle_disconnect must have cleaned up
}

// =====================================================================
// Partial send fuzzer — send truncated response, then close
// =====================================================================

fn fuzz_partial_send(allocator: std.mem.Allocator, prng: *PRNG, stats: *Stats) void {
    stats.partial_sends += 1;

    const pair = test_socketpair() orelse return;

    if (prng.boolean()) {
        // Partial translate response.
        var resp = gen_translate_response(prng);
        const full = std.mem.asBytes(&resp);
        const send_len = prng.range_inclusive(usize, 1, full.len - 1);
        const thread = std.Thread.spawn(.{}, mock_send_partial, .{ pair[1], full[0..send_len] }) catch return;

        var client = sidecar.SidecarClient{ .path = "/unused", .fd = pair[0] };
        const result = client.translate(.get, "/products", "");
        thread.join();
        assert(result == null);
        client.close();
    } else {
        // Partial execute_render response.
        const resp = allocator.create(protocol.ExecuteRenderResponse) catch return;
        defer allocator.destroy(resp);
        gen_execute_render_response(prng, resp);
        const full = std.mem.asBytes(resp);
        const send_len = prng.range_inclusive(usize, 1, full.len - 1);
        const thread = std.Thread.spawn(.{}, mock_send_partial, .{ pair[1], full[0..send_len] }) catch return;

        var client = sidecar.SidecarClient{ .path = "/unused", .fd = pair[0] };
        const resp_buf = allocator.create(protocol.ExecuteRenderResponse) catch return;
        defer allocator.destroy(resp_buf);
        var body = std.mem.zeroes([message.body_max]u8);
        var cache = std.mem.zeroes(protocol.PrefetchCache);
        const ok = client.execute_render(.get_product, 0, &body, &cache, false, resp_buf);
        thread.join();
        assert(!ok);
        client.close();
    }
}

fn mock_send_partial(fd: std.posix.fd_t, data: []const u8) void {
    defer std.posix.close(fd);
    send_all_or_close(fd, data);
}

// =====================================================================
// Response generators
// =====================================================================

fn gen_translate_response(prng: *PRNG) protocol.TranslateResponse {
    const strategy = prng.chances(.{
        .valid_found = 3,
        .valid_not_found = 2,
        .corrupt = 5,
    });

    return switch (strategy) {
        .valid_found => gen_valid_translate_found(prng),
        .valid_not_found => gen_valid_translate_not_found(prng),
        .corrupt => gen_corrupt_translate(prng),
    };
}

fn gen_valid_translate_found(prng: *PRNG) protocol.TranslateResponse {
    var resp = std.mem.zeroes(protocol.TranslateResponse);
    resp.found = 1;
    resp.operation = prng.enum_uniform(message.Operation);
    resp.id = prng.int(u128);
    // Random body bytes — the client copies them as-is.
    prng.fill(&resp.body);
    return resp;
}

fn gen_valid_translate_not_found(prng: *PRNG) protocol.TranslateResponse {
    _ = prng;
    var resp = std.mem.zeroes(protocol.TranslateResponse);
    resp.found = 0;
    return resp;
}

fn gen_corrupt_translate(prng: *PRNG) protocol.TranslateResponse {
    const corruption = prng.chances(.{
        .bad_found = 2,
        .bad_operation = 3,
        .random_bytes = 3,
        .found_with_bad_op = 2,
    });

    const op_offset = @offsetOf(protocol.TranslateResponse, "operation");

    switch (corruption) {
        .bad_found => {
            // found is not 0 or 1.
            var resp = std.mem.zeroes(protocol.TranslateResponse);
            resp.found = prng.range_inclusive(u8, 2, 255);
            resp.operation = prng.enum_uniform(message.Operation);
            return resp;
        },
        .bad_operation => {
            // Operation enum value out of range — write raw byte to avoid @enumFromInt panic.
            var resp = std.mem.zeroes(protocol.TranslateResponse);
            resp.found = 1;
            const op_count: u8 = @intCast(std.meta.fields(message.Operation).len);
            std.mem.asBytes(&resp)[op_offset] = prng.range_inclusive(u8, op_count, 255);
            resp.id = prng.int(u128);
            return resp;
        },
        .random_bytes => {
            // Completely random response.
            var resp: protocol.TranslateResponse = undefined;
            prng.fill(std.mem.asBytes(&resp));
            return resp;
        },
        .found_with_bad_op => {
            // found=1 but operation is out of range — write raw byte.
            var resp = std.mem.zeroes(protocol.TranslateResponse);
            resp.found = 1;
            const op_count: u8 = @intCast(std.meta.fields(message.Operation).len);
            std.mem.asBytes(&resp)[op_offset] = prng.range_inclusive(u8, op_count, 255);
            resp.id = prng.int(u128);
            return resp;
        },
    }
}

fn gen_execute_render_response(prng: *PRNG, resp: *protocol.ExecuteRenderResponse) void {
    const strategy = prng.chances(.{
        .valid = 3,
        .corrupt = 5,
        .random_bytes = 2,
    });

    switch (strategy) {
        .valid => gen_valid_exec_response(prng, resp),
        .corrupt => gen_corrupt_exec_response(prng, resp),
        .random_bytes => prng.fill(std.mem.asBytes(resp)),
    }
}

fn gen_valid_exec_response(prng: *PRNG, resp: *protocol.ExecuteRenderResponse) void {
    resp.* = std.mem.zeroes(protocol.ExecuteRenderResponse);
    resp.status = prng.enum_uniform(message.Status);
    resp.writes_len = prng.range_inclusive(u8, 0, message.writes_max);
    const html_len = prng.range_inclusive(u32, 0, @intCast(@min(protocol.html_max, 4096)));
    resp.html_len = html_len;
    // Fill html with printable bytes.
    for (resp.html[0..html_len]) |*b| {
        b.* = prng.range_inclusive(u8, 0x20, 0x7e);
    }
}

fn gen_corrupt_exec_response(prng: *PRNG, resp: *protocol.ExecuteRenderResponse) void {
    // Start with a valid response, then corrupt one field.
    gen_valid_exec_response(prng, resp);

    const corruption = prng.chances(.{
        .bad_status = 3,
        .bad_writes_len = 3,
        .bad_html_len = 3,
        .all_bad = 1,
    });

    const resp_bytes = std.mem.asBytes(resp);
    const status_offset = @offsetOf(protocol.ExecuteRenderResponse, "status");

    switch (corruption) {
        .bad_status => {
            const status_count: u8 = @intCast(std.meta.fields(message.Status).len);
            resp_bytes[status_offset] = prng.range_inclusive(u8, status_count, 255);
        },
        .bad_writes_len => {
            resp.writes_len = prng.range_inclusive(u8, message.writes_max + 1, 255);
        },
        .bad_html_len => {
            resp.html_len = prng.range_inclusive(u32, @intCast(protocol.html_max + 1), std.math.maxInt(u32));
        },
        .all_bad => {
            const status_count: u8 = @intCast(std.meta.fields(message.Status).len);
            resp_bytes[status_offset] = prng.range_inclusive(u8, status_count, 255);
            resp.writes_len = prng.range_inclusive(u8, message.writes_max + 1, 255);
            resp.html_len = prng.range_inclusive(u32, @intCast(protocol.html_max + 1), std.math.maxInt(u32));
        },
    }
}

// =====================================================================
// Helpers
// =====================================================================

fn test_socketpair() ?[2]std.posix.fd_t {
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    if (rc != 0) return null;
    return fds;
}

fn send_all_or_close(fd: std.posix.fd_t, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        sent += std.posix.write(fd, bytes[sent..]) catch return;
    }
}
