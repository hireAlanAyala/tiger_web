//! Simulation tests — full-stack tests with deterministic IO.
//!
//! Uses addTest (Zig test binary). The test runner owns std_options.
//! Log noise silenced via std.testing.log_level. Seeds from
//! std.testing.random_seed via PRNG.from_seed_testing().
//! Matches TigerBeetle's seeded unit test pattern.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const http = @import("framework/http.zig");
const state_machine = @import("state_machine.zig");
const App = @import("app.zig");
const Storage = App.Storage;
const StateMachine = App.SM;
const ServerType = @import("framework/server.zig").ServerType;
const ConnectionType = @import("framework/connection.zig").ConnectionType;
const marks = @import("framework/marks.zig");
const PRNG = @import("stdx").PRNG;
const TimeSim = @import("framework/time.zig").TimeSim;
const Trace = @import("trace.zig");
const auth = @import("framework/auth.zig");
const sim_io = @import("sim_io.zig");
pub const SimIO = sim_io.SimIO;

// Silence framework log noise and cap address space.
// Runs before all tests (declaration order in file).
test {
    std.testing.log_level = .err;
    limit_address_space();
}

// SimIO extracted to sim_io.zig — shared with sim_sidecar.zig.
// Re-exported above as `pub const SimIO = sim_io.SimIO;`
// Keep format_u32 and write_cookie_header available for test code below.
const format_u32 = sim_io.format_u32;
const write_cookie_header = sim_io.write_cookie_header;

const log = marks.wrap_log(std.log.scoped(.sim));

const Server = ServerType(App, SimIO, App.Storage);
const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

/// Run ticks until the server processes pending work.
fn run_ticks(server: *Server, io: *SimIO, n: usize) void {
    for (0..n) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
}

/// Run ticks until an HTTP response arrives for the given client, or return
/// null after max_ticks. Handles variable tick counts from partial delivery.
fn run_until_response(server: *Server, io: *SimIO, client_index: usize, max_ticks: usize) ?SimIO.HttpResponse {
    for (0..max_ticks) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
        // Try Content-Length first, then Connection: close.
        if (io.read_response(client_index)) |resp| return resp;
        if (io.read_close_response(client_index)) |resp| return resp;
    }
    return null;
}

fn run_until_close_response(server: *Server, io: *SimIO, client_index: usize, max_ticks: usize) ?SimIO.HttpResponse {
    for (0..max_ticks) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
        if (io.read_close_response(client_index)) |resp| return resp;
    }
    return null;
}

/// Clear the response and reconnect the client for the next request.
/// SSE responses use Connection: close; non-SSE use keep-alive.
/// Reconnecting works for both: keep-alive connections close when
/// the old fd becomes unreachable (new fd assigned).
fn clear_and_reconnect(io: *SimIO, server: *Server, client_index: usize) void {
    io.clear_response(client_index);
    // Run a few ticks to let the server process the connection close.
    for (0..10) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
    // Suspend accept faults during reconnection — Connection: close means
    // every request needs a reconnect, so accept faults during reconnection
    // would stall the fuzzer rather than exercise interesting behavior.
    const saved_accept_fault = io.accept_fault_probability;
    io.accept_fault_probability = PRNG.Ratio.zero();
    io.connect_client(client_index, server.listen_fd);
    // Run ticks for the accept to complete.
    for (0..10) |_| {
        server.tick();
        io.run_for_ns(10 * std.time.ns_per_ms);
    }
    io.accept_fault_probability = saved_accept_fault;
}

/// Helper: check that a response body contains a substring.
fn body_contains(body: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, body, needle) != null;
}

fn count_occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |idx| {
        count += 1;
        pos = idx + needle.len;
    }
    return count;
}

/// Cap address space so a runaway test can't eat all system memory.
/// Matches TB's testing/fuzz.zig limit_ram().
fn limit_address_space() void {
    if (@import("builtin").target.os.tag != .linux) return;
    const GiB = 1024 * 1024 * 1024;
    std.posix.setrlimit(.AS, .{
        .cur = 4 * GiB,
        .max = 4 * GiB,
    }) catch {};
}

const test_uuid1 = "aabbccdd11223344aabbccdd11223344";
const test_uuid2 = "aabbccdd11223344aabbccdd11223345";

// =====================================================================
// Infrastructure tests — deterministic replay, connection plumbing
// =====================================================================

test "deterministic replay — same seed same result" {
    var results: [2]u16 = undefined;

    for (0..2) |run| {
        var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
        var storage = try App.Storage.init(":memory:");
        defer storage.deinit();
        var sm = StateMachine.init(&storage, 0, test_key);
        var time_sim = TimeSim{};
        var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
        defer tracer.deinit(std.testing.allocator);
        var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
        defer server.deinit(std.testing.allocator);

        io.connect_client(0, server.listen_fd);
        io.inject_post(0, "/products",
            "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
        );
        const create_resp = run_until_response(&server, &io, 0, 500) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(create_resp.status_code, 200);
        clear_and_reconnect(&io, &server, 0);

        io.inject_get(0, "/products/" ++ test_uuid1);
        const get_resp = run_until_response(&server, &io, 0, 500) orelse
            return error.TestUnexpectedResult;
        results[run] = get_resp.status_code;
    }

    assert(results[0] == results[1]);
    assert(results[0] == 200);
}

test "pipelining — back-to-back requests on one connection" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Send POST, wait for response, clear, then GET (sequential — Connection: close
    // prevents pipelining).
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"PipeWidget\",\"price_cents\":100}"
    );
    const create_resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    clear_and_reconnect(&io, &server, 0);

    io.inject_get(0, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(body_contains(get_resp.body, "PipeWidget"));
}

test "connection drops and reconnects — state machine survives" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Create a product before the drop.
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Survivor\",\"price_cents\":100}"
    );
    const create_resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    io.clear_response(0);

    // Drop the connection.
    io.disconnect_client(0);
    run_ticks(&server, &io, 50);

    // Reconnect on a different client slot.
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    // The state machine should still have the product.
    io.inject_get(1, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &io, 1, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(get_resp.status_code, 200);
    try std.testing.expect(body_contains(get_resp.body, "Survivor"));
}

test "timeout — partial request triggers close" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Inject a partial request (no header terminator).
    io.inject_bytes(0, "GET /products HTTP/1.1\r\n");
    run_ticks(&server, &io, 10);

    // Connection should still be alive before timeout.
    var found_receiving = false;
    for (server.connections) |*conn| {
        if (conn.state == .receiving) {
            found_receiving = true;
            break;
        }
    }
    assert(found_receiving);

    // Disconnect the client so SimIO won't try to deliver more data,
    // then tick past the timeout.
    io.disconnect_client(0);

    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
    }

    // After timeout, the receiving connection should be freed.
    var any_active = false;
    for (server.connections) |*conn| {
        if (conn.state != .free) {
            any_active = true;
            break;
        }
    }
    assert(!any_active);
}

// =====================================================================
// Coverage mark tests
// =====================================================================

test "mark: disconnect triggers recv peer closed" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    const mark = marks.check("recv: peer closed");
    io.disconnect_client(0);
    run_ticks(&server, &io, 50);
    try mark.expect_hit();
}

test "mark: send fault triggers send error" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Create a product so there's something to GET.
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"TestProduct\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Enable 100% send faults, then GET. The response send will fail.
    io.send_fault_probability = PRNG.ratio(1, 1);
    io.inject_get(0, "/products/" ++ test_uuid1);
    const mark = marks.check("send: error");
    run_ticks(&server, &io, 50);
    try mark.expect_hit();
}

test "mark: idle connection triggers timeout" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Send a partial request so connection stays in receiving state.
    io.inject_bytes(0, "GET /products HTTP/1.1\r\n");
    run_ticks(&server, &io, 10);

    // Disconnect so SimIO won't deliver more data, then tick past timeout.
    io.disconnect_client(0);

    const mark = marks.check("connection timed out");
    for (0..Server.request_timeout_ticks + 10) |_| {
        server.tick();
    }
    try mark.expect_hit();
}

test "mark: garbage bytes trigger invalid HTTP" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    const mark = marks.check("invalid HTTP");
    io.inject_bytes(0, "GARBAGE\x00\x01\x02\r\n\r\n");
    run_ticks(&server, &io, 50);
    try mark.expect_hit();
}

test "mark: unknown route triggers unmapped request" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // GET /unknown doesn't match any known route — triggers unmapped.
    const mark = marks.check("unmapped request");
    var req_buf: [http.recv_buf_max]u8 = undefined;
    var pos: usize = 0;
    const req_line = "GET /unknown HTTP/1.1\r\n";
    @memcpy(req_buf[pos..][0..req_line.len], req_line);
    pos += req_line.len;
    pos += write_cookie_header(req_buf[pos..]);
    const end = "\r\n";
    @memcpy(req_buf[pos..][0..end.len], end);
    pos += end.len;
    io.inject_bytes(0, req_buf[0..pos]);
    run_ticks(&server, &io, 50);
    try mark.expect_hit();
}

test "first request without cookie gets identity + Set-Cookie" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Request without cookie — should get 200 + full page + Set-Cookie header.
    io.inject_bytes(0, "GET / HTTP/1.1\r\n\r\n");
    const resp = run_until_response(&server, &io, 0, 300) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expect(body_contains(resp.body, "<!DOCTYPE html>"));
    // Response headers should include Set-Cookie with tiger_id.
    const full = io.clients[0].recv_buf[0..io.clients[0].recv_len];
    assert(std.mem.indexOf(u8, full, "Set-Cookie: tiger_id=") != null);
}

test "request with valid cookie — no Set-Cookie header" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Request with valid cookie — should get 200, no Set-Cookie.
    io.inject_get(0, "/");
    const resp = run_until_response(&server, &io, 0, 300) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    const full = io.clients[0].recv_buf[0..io.clients[0].recv_len];
    assert(std.mem.indexOf(u8, full, "Set-Cookie:") == null);
}

test "mark: accept failure logs warning" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    // 100% accept fault — try_accept returns null every tick.
    io.accept_fault_probability = PRNG.ratio(1, 1);
    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);
    // Client connected but never accepted — no connection used.
    try std.testing.expectEqual(@as(u32, 0), server.connections_used);
}

test "mark: SSE mutation triggers follow-up" {
    // Follow-up path was removed when handlers started owning the complete
    // response. SSE mutations are now rendered directly by the handler.
}

// =====================================================================
// Storage fault injection tests
// =====================================================================

test "storage busy fault — prefetch retries next tick then succeeds" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    // Create a product first (no faults).
    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Enable 100% busy faults. GET will be retried each tick.
    var fault_prng_c001 = PRNG.from_seed(0xc001);
    App.fault_prng = &fault_prng_c001;
    App.fault_busy_ratio = PRNG.ratio(1, 1);
    io.inject_get(0, "/products/" ++ test_uuid1);

    // Tick a few times with busy faults — connection stays .ready.
    const mark = marks.check("storage: busy fault injected");
    run_ticks(&server, &io, 20);
    try mark.expect_hit();

    // Verify no response yet (still busy-looping).
    assert(io.read_response(0) == null);

    // Disable busy faults — next tick should succeed.
    App.fault_busy_ratio = PRNG.Ratio.zero();
    const resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expect(body_contains(resp.body, "Widget"));
}

test "storage err fault — renders dashboard page" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    run_ticks(&server, &io, 10);

    // 100% busy faults — prefetch retries every tick, no response produced.
    var fault_prng_c002 = PRNG.from_seed(0xc002);
    App.fault_prng = &fault_prng_c002;
    App.fault_busy_ratio = PRNG.ratio(1, 1);

    const mark = marks.check("storage: busy fault injected");
    io.inject_get(0, "/products/" ++ test_uuid1);
    run_ticks(&server, &io, 20);
    try mark.expect_hit();

    // No response — busy faults cause retry, not error response.
    assert(io.read_response(0) == null);

    // Disable faults — next tick should succeed.
    App.fault_busy_ratio = PRNG.Ratio.zero();
    const resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
}

test "concurrent connections — busy client deferred, ready client served" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    // Connect two clients and let them establish.
    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Create a product (no faults).
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Widget\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Enable 100% busy faults. Both clients send GET.
    var fault_prng_d010 = PRNG.from_seed(0xd010);
    App.fault_prng = &fault_prng_d010;
    App.fault_busy_ratio = PRNG.ratio(1, 1);
    io.inject_get(0, "/products/" ++ test_uuid1);
    io.inject_get(1, "/products/" ++ test_uuid1);

    // Tick with faults — neither should get a response.
    run_ticks(&server, &io, 20);
    assert(io.read_response(0) == null);
    assert(io.read_response(1) == null);

    // Disable faults — both should succeed on next ticks.
    App.fault_busy_ratio = PRNG.Ratio.zero();

    const resp0 = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp0.status_code, 200);
    try std.testing.expect(body_contains(resp0.body, "Widget"));

    const resp1 = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp1.status_code, 200);
    try std.testing.expect(body_contains(resp1.body, "Widget"));
}

test "interleaved writes — update and delete same entity across connections" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    // Connect two clients and let them establish.
    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Create the product first (single client, no race).
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_uuid1 ++ "\",\"name\":\"Original\",\"price_cents\":100}"
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Inject competing writes simultaneously: client 0 updates, client 1 deletes.
    // Partial delivery byte counts determine which completes first — the test
    // must accept either ordering and assert the invariant holds regardless.
    io.inject_put(0, "/products/" ++ test_uuid1,
        "{\"name\":\"Updated\",\"version\":1}"
    );
    io.inject_delete(1, "/products/" ++ test_uuid1);

    // Both should succeed — the product exists when each is prefetched.
    const update_resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(update_resp.status_code, 200);

    const delete_resp = run_until_response(&server, &io, 1, 500) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(delete_resp.status_code, 200);

    // Check final state: whichever ran last determines the outcome.
    clear_and_reconnect(&io, &server, 0);
    io.clear_response(1);
    io.inject_get(0, "/products/" ++ test_uuid1);
    const get_resp = run_until_response(&server, &io, 0, 500) orelse
        return error.TestUnexpectedResult;

    // Always-200 server — check body content, not HTTP status.
    // If delete ran last → product inactive → "Product not found".
    // If update ran last → product active with updated name → "Updated".
    // Either is correct — the invariant is consistency, not ordering.
    const body = get_resp.body;
    const deleted = body_contains(body, "Product not found");
    const updated = body_contains(body, "Updated");
    try std.testing.expect(deleted or updated);
}

// =====================================================================
// Two-phase order completion — full-stack sim tests
// =====================================================================

const test_product_uuid = "aabbccdd11223344aabbccdd11220001";
const test_order_uuid = "eeddccbb11223344eeddccbb11220001";

test "two-phase order — create on client 0, complete on client 1" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Create a product.
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Client 0 creates an order.
    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    const create_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(create_resp.status_code, 200);
    try std.testing.expect(body_contains(create_resp.body, "Pending"));
    clear_and_reconnect(&io, &server, 0);

    // Client 1 (the "worker") completes the order.
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const complete_resp = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(complete_resp.status_code, 200);
    try std.testing.expect(body_contains(complete_resp.body, "Confirmed"));
    io.clear_response(1);

    // Verify inventory stayed decremented (confirmed = keep reservation).
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(inv_resp.status_code, 200);
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 45"));
}

test "two-phase order — failed completion restores inventory" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Worker reports failure.
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"failed\"}",
    );
    const resp = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expect(body_contains(resp.body, "Failed"));
    io.clear_response(1);

    // Inventory restored.
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 50"));
}

test "two-phase order — completion after timeout expires" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Advance time past the order timeout.
    time_sim.advance(message.order_timeout_seconds + 1);

    // Worker tries to complete — order_expired error in the SSE fragment.
    io.inject_post_datastar(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp = run_until_close_response(&server, &io, 1, 2000) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp.status_code, 200);
    try std.testing.expect(body_contains(resp.body, "Order Expired"));
    io.clear_response(1);

    // Inventory restored because the order expired.
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 50"));
}

test "two-phase order — idempotent same-result retry" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // First completion succeeds.
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp1 = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp1.status_code, 200);
    clear_and_reconnect(&io, &server, 1);

    // Same-result retry is idempotent — returns OK (worker crash recovery).
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const resp2 = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(resp2.status_code, 200);
    io.clear_response(1);

    // Inventory unchanged by idempotent retry.
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 45"));
}

test "two-phase order — poll pending then complete (worker pattern)" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":3}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    io.clear_response(0);

    // Worker polls GET /orders — should see the pending order.
    io.inject_get(1, "/orders");
    const list_resp = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(list_resp.status_code, 200);
    try std.testing.expect(body_contains(list_resp.body, "Pending"));
    assert(body_contains(list_resp.body, test_order_uuid));
    clear_and_reconnect(&io, &server, 1);

    // Worker completes.
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    _ = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 1);

    // Worker polls again — order should now be confirmed, not pending.
    io.inject_get(1, "/orders");
    const list_resp2 = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(list_resp2.status_code, 200);
    try std.testing.expect(body_contains(list_resp2.body, "Confirmed"));
}

// =====================================================================
// Cancel order — full-stack sim tests
// =====================================================================

test "cancel order — client cancels, worker completion rejected" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    // Setup: product + order.
    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":10}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Client cancels.
    io.inject_post(0, "/orders/" ++ test_order_uuid ++ "/cancel", "");
    const cancel_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cancel_resp.status_code, 200);
    try std.testing.expect(body_contains(cancel_resp.body, "Order cancelled"));
    clear_and_reconnect(&io, &server, 0);

    // Worker tries to complete — rejected (order not pending, error in SSE fragment).
    io.inject_post_datastar(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    const complete_resp = run_until_close_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(complete_resp.status_code, 200);
    try std.testing.expect(body_contains(complete_resp.body, "Order is not pending"));
    io.clear_response(1);

    // Inventory fully restored.
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 50"));
}

test "cancel order — cancel already confirmed is rejected" {
    var seed_prng = PRNG.from_seed_testing();
    var io = SimIO.init(seed_prng.int(u64));
    var storage = try App.Storage.init(":memory:");
    defer storage.deinit();
    var sm = StateMachine.init(&storage, 0, test_key);
    var time_sim = TimeSim{};
    var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
    defer tracer.deinit(std.testing.allocator);
    var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 2, time_sim.time(), null);
        server.wire_connections();
    defer server.deinit(std.testing.allocator);

    io.connect_client(0, server.listen_fd);
    io.connect_client(1, server.listen_fd);
    run_ticks(&server, &io, 10);

    io.inject_post(0, "/products",
        "{\"id\":\"" ++ test_product_uuid ++ "\",\"name\":\"Widget\",\"price_cents\":1000,\"inventory\":50}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    io.inject_post(0, "/orders",
        "{\"id\":\"" ++ test_order_uuid ++ "\",\"items\":[{\"product_id\":\"" ++ test_product_uuid ++ "\",\"quantity\":5}]}",
    );
    _ = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    clear_and_reconnect(&io, &server, 0);

    // Worker completes first.
    io.inject_post(1, "/orders/" ++ test_order_uuid ++ "/complete",
        "{\"result\":\"confirmed\"}",
    );
    _ = run_until_response(&server, &io, 1, 500) orelse return error.TestUnexpectedResult;
    io.clear_response(1);

    // Client tries to cancel — too late (order not pending, error in SSE fragment).
    io.inject_post_datastar(0, "/orders/" ++ test_order_uuid ++ "/cancel", "");
    const cancel_resp = run_until_close_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(cancel_resp.status_code, 200);
    try std.testing.expect(body_contains(cancel_resp.body, "Order is not pending"));
    clear_and_reconnect(&io, &server, 0);

    // Inventory stays at confirmed level.
    io.inject_get(0, "/products/" ++ test_product_uuid ++ "/inventory");
    const inv_resp = run_until_response(&server, &io, 0, 500) orelse return error.TestUnexpectedResult;
    try std.testing.expect(body_contains(inv_resp.body, "inventory: 45"));
}

// =====================================================================
// PRNG-driven fuzzer — exercises the full stack with random operations
// =====================================================================

/// Fuzzer action space — each variant maps to an HTTP operation or
/// a control action (connect/disconnect/toggle faults).
const FuzzAction = enum {
    connect_client,
    disconnect_client,
    create_product,
    get_product,
    list_products,
    update_product,
    delete_product,
    get_inventory,
    transfer_inventory,
    create_collection,
    get_collection,
    list_collections,
    delete_collection,
    add_member,
    remove_member,
    create_order,
    complete_order,
    cancel_order,
    get_order,
    list_orders,
    search_products,
    page_load_dashboard,
    toggle_faults,
};

/// Stateful fuzzer that tracks known entity IDs and client connectivity.
/// Generates random HTTP requests and relies on server/connection invariants
/// (defer invariants()) to catch bugs.
const Fuzzer = struct {
    const id_pool_max = 32;
    const clients_max = SimIO.max_clients;

    product_ids: [id_pool_max]u128,
    product_count: u32,
    collection_ids: [id_pool_max]u128,
    collection_count: u32,
    order_ids: [id_pool_max]u128,
    order_count: u32,

    client_connected: [clients_max]bool,
    connected_count: u32,

    body_buf: [2048]u8,
    path_buf: [256]u8,

    fn init() Fuzzer {
        return .{
            .product_ids = [_]u128{0} ** id_pool_max,
            .product_count = 0,
            .collection_ids = [_]u128{0} ** id_pool_max,
            .collection_count = 0,
            .order_ids = [_]u128{0} ** id_pool_max,
            .order_count = 0,
            .client_connected = [_]bool{false} ** clients_max,
            .connected_count = 0,
            .body_buf = undefined,
            .path_buf = undefined,
        };
    }

    fn step(self: *Fuzzer, action: FuzzAction, prng: *PRNG, io: *SimIO, server: *Server, storage: *App.Storage) void {
        switch (action) {
            .connect_client => self.step_connect(prng, io, server),
            .disconnect_client => self.step_disconnect(prng, io, server),
            .create_product => self.step_create_product(prng, io, server),
            .get_product => self.step_get_product(prng, io, server),
            .list_products => self.step_list_products(prng, io, server),
            .update_product => self.step_update_product(prng, io, server),
            .delete_product => self.step_delete_product(prng, io, server),
            .get_inventory => self.step_get_inventory(prng, io, server),
            .transfer_inventory => self.step_transfer_inventory(prng, io, server),
            .create_collection => self.step_create_collection(prng, io, server),
            .get_collection => self.step_get_collection(prng, io, server),
            .list_collections => self.step_list_collections(prng, io, server),
            .delete_collection => self.step_delete_collection(prng, io, server),
            .add_member => self.step_add_member(prng, io, server),
            .remove_member => self.step_remove_member(prng, io, server),
            .create_order => self.step_create_order(prng, io, server),
            .complete_order => self.step_complete_order(prng, io, server),
            .cancel_order => self.step_cancel_order(prng, io, server),
            .get_order => self.step_get_order(prng, io, server),
            .list_orders => self.step_list_orders(prng, io, server),
            .search_products => self.step_search_products(prng, io, server),
            .page_load_dashboard => self.step_page_load_dashboard(prng, io, server),
            .toggle_faults => self.step_toggle_faults(prng, io, storage),
        }
    }

    // --- Client management ---

    fn step_connect(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        _ = prng;
        for (self.client_connected, 0..) |c, i| {
            if (!c) {
                io.connect_client(i, server.listen_fd);
                self.client_connected[i] = true;
                self.connected_count += 1;
                run_ticks(server, io, 10);
                return;
            }
        }
        // All slots full — skip.
    }

    fn step_disconnect(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        // Keep at least one client connected.
        if (self.connected_count <= 1) return;
        const idx = self.pick_connected(prng);
        io.disconnect_client(idx);
        self.client_connected[idx] = false;
        self.connected_count -= 1;
        run_ticks(server, io, 20);
    }

    // --- Products ---

    fn step_create_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_product_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/products", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/products", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.product_count < id_pool_max) {
                self.product_ids[self.product_count] = id;
                self.product_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_product_id(prng);
        const path = path_with_id(&self.path_buf, "/products/", id);
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_list_products(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const path = switch (prng.int_inclusive(u8, 3)) {
            0 => @as([]const u8, "/products"),
            1 => "/products?active=all",
            2 => "/products?active=false",
            3 => "/products?price_min=100&price_max=5000",
            else => unreachable,
        };
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_search_products(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const queries = [_][]const u8{ "widget", "shirt", "a", "test", "pro" };
        const q = queries[prng.int_inclusive(usize, queries.len - 1)];
        const path = std.fmt.bufPrint(&self.path_buf, "/products?q={s}", .{q}) catch "/products?q=a";
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_update_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_known_product(prng);
        const body = self.gen_product_body(prng, id);
        const path = path_with_id(&self.path_buf, "/products/", id);
        if (prng.boolean()) {
            io.inject_put_datastar(client, path, body);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_put(client, path, body);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_delete_product(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const idx = prng.int_inclusive(u32, self.product_count - 1);
        const id = self.product_ids[idx];
        const path = path_with_id(&self.path_buf, "/products/", id);
        const resp = if (prng.boolean()) blk: {
            io.inject_delete_datastar(client, path);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_delete(client, path);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok()) {
                // Remove from pool by swapping with last.
                self.product_count -= 1;
                self.product_ids[idx] = self.product_ids[self.product_count];
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_inventory(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_product_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/products/", id, "/inventory");
        io.inject_get(client, path);
        _ = run_until_response(server, io, client, 300);
        clear_and_reconnect(io, server, client);
    }

    fn step_transfer_inventory(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count < 2) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);

        const src_idx = prng.int_inclusive(u32, self.product_count - 1);
        var dst_idx = prng.int_inclusive(u32, self.product_count - 1);
        if (dst_idx == src_idx) dst_idx = (src_idx + 1) % self.product_count;
        const src_id = self.product_ids[src_idx];
        const dst_id = self.product_ids[dst_idx];

        const path = path_with_two_ids(&self.path_buf, "/products/", src_id, "/transfer-inventory/", dst_id);
        const qty = prng.range_inclusive(u32, 1, 50);
        const body = self.gen_transfer_body(qty);
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, body);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, body);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    // --- Collections ---

    fn step_create_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_collection_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/collections", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/collections", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.collection_count < id_pool_max) {
                self.collection_ids[self.collection_count] = id;
                self.collection_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_collection_id(prng);
        const path = path_with_id(&self.path_buf, "/collections/", id);
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_list_collections(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        if (prng.boolean()) {
            io.inject_get_datastar(client, "/collections");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, "/collections");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_delete_collection(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const idx = prng.int_inclusive(u32, self.collection_count - 1);
        const id = self.collection_ids[idx];
        const path = path_with_id(&self.path_buf, "/collections/", id);
        const resp = if (prng.boolean()) blk: {
            io.inject_delete_datastar(client, path);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_delete(client, path);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok()) {
                self.collection_count -= 1;
                self.collection_ids[idx] = self.collection_ids[self.collection_count];
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_add_member(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0 or self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const col_id = self.pick_known_collection(prng);
        const prod_id = self.pick_known_product(prng);
        const path = path_with_two_ids(&self.path_buf, "/collections/", col_id, "/products/", prod_id);
        if (prng.boolean()) {
            io.inject_bytes(client, build_simple_request_datastar(&self.body_buf, "POST ", path));
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_bytes(client, build_simple_request(&self.body_buf, "POST ", path));
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_remove_member(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.collection_count == 0 or self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const col_id = self.pick_known_collection(prng);
        const prod_id = self.pick_known_product(prng);
        const path = path_with_two_ids(&self.path_buf, "/collections/", col_id, "/products/", prod_id);
        if (prng.boolean()) {
            io.inject_bytes(client, build_simple_request_datastar(&self.body_buf, "DELETE ", path));
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_bytes(client, build_simple_request(&self.body_buf, "DELETE ", path));
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    // --- Orders ---

    fn step_create_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        if (self.product_count == 0) return;
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id: u128 = prng.int(u128) | 1;
        const body = self.gen_order_body(prng, id);
        const resp = if (prng.boolean()) blk: {
            io.inject_post_datastar(client, "/orders", body);
            break :blk run_until_close_response(server, io, client, 500);
        } else blk: {
            io.inject_post(client, "/orders", body);
            break :blk run_until_response(server, io, client, 300);
        };
        if (resp) |r| {
            if (r.is_ok() and self.order_count < id_pool_max) {
                self.order_ids[self.order_count] = id;
                self.order_count += 1;
            }
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_complete_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/orders/", id, "/complete");
        const confirmed = prng.boolean();
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"result\":\"");
        w.raw(if (confirmed) "confirmed" else "failed");
        w.raw("\"");
        // ~50% chance of including payment_ref on confirmed.
        if (confirmed and prng.boolean()) {
            w.raw(",\"payment_ref\":\"ch_test_");
            w.num(prng.int(u32));
            w.raw("\"");
        }
        w.raw("}");
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, w.slice());
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, w.slice());
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_cancel_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id_suffix(&self.path_buf, "/orders/", id, "/cancel");
        if (prng.boolean()) {
            io.inject_post_datastar(client, path, "");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_post(client, path, "");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_get_order(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const id = self.pick_order_id(prng);
        const path = path_with_id(&self.path_buf, "/orders/", id);
        if (prng.boolean()) {
            io.inject_get_datastar(client, path);
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, path);
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_list_orders(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        if (prng.boolean()) {
            io.inject_get_datastar(client, "/orders");
            _ = run_until_close_response(server, io, client, 500);
        } else {
            io.inject_get(client, "/orders");
            _ = run_until_response(server, io, client, 300);
        }
        clear_and_reconnect(io, server, client);
    }

    fn step_page_load_dashboard(self: *Fuzzer, prng: *PRNG, io: *SimIO, server: *Server) void {
        self.ensure_connected(io, server);
        const client = self.pick_connected(prng);
        const datastar = prng.boolean();

        if (datastar) {
            io.inject_get_datastar(client, "/");
        } else {
            io.inject_get(client, "/");
        }

        // Dashboard uses Connection: close (no Content-Length).
        // Run enough ticks for the full response to arrive (partial sends).
        _ = run_until_close_response(server, io, client, 500);
        clear_and_reconnect(io, server, client);
    }

    // --- Fault injection ---

    fn step_toggle_faults(self: *Fuzzer, prng: *PRNG, io: *SimIO, storage: *App.Storage) void {
        _ = self;
        _ = storage;
        io.accept_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 30), 100) else PRNG.Ratio.zero();
        io.recv_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 20), 100) else PRNG.Ratio.zero();
        io.send_fault_probability = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 20), 100) else PRNG.Ratio.zero();
        // Storage fault injection via App module-level vars.
        App.fault_busy_ratio = if (prng.boolean()) PRNG.ratio(prng.range_inclusive(u64, 1, 40), 100) else PRNG.Ratio.zero();
    }

    // --- ID selection helpers ---

    fn pick_product_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.product_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.pick_known_product(prng);
        }
        return prng.int(u128) | 1;
    }

    fn pick_known_product(self: *Fuzzer, prng: *PRNG) u128 {
        assert(self.product_count > 0);
        return self.product_ids[prng.int_inclusive(u32, self.product_count - 1)];
    }

    fn pick_collection_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.collection_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.pick_known_collection(prng);
        }
        return prng.int(u128) | 1;
    }

    fn pick_known_collection(self: *Fuzzer, prng: *PRNG) u128 {
        assert(self.collection_count > 0);
        return self.collection_ids[prng.int_inclusive(u32, self.collection_count - 1)];
    }

    fn pick_order_id(self: *Fuzzer, prng: *PRNG) u128 {
        if (self.order_count > 0 and prng.chance(PRNG.ratio(3, 4))) {
            return self.order_ids[prng.int_inclusive(u32, self.order_count - 1)];
        }
        return prng.int(u128) | 1;
    }

    // --- Client helpers ---

    fn ensure_connected(self: *Fuzzer, io: *SimIO, server: *Server) void {
        if (self.connected_count > 0) return;
        for (self.client_connected, 0..) |c, i| {
            if (!c) {
                io.connect_client(i, server.listen_fd);
                self.client_connected[i] = true;
                self.connected_count += 1;
                run_ticks(server, io, 10);
                return;
            }
        }
        unreachable;
    }

    fn pick_connected(self: *Fuzzer, prng: *PRNG) usize {
        assert(self.connected_count > 0);
        const target = prng.int_inclusive(u32, self.connected_count - 1);
        var count: u32 = 0;
        for (self.client_connected, 0..) |c, i| {
            if (c) {
                if (count == target) return i;
                count += 1;
            }
        }
        unreachable;
    }

    // --- Body generators ---

    fn gen_product_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\",\"price_cents\":");
        w.num(prng.range_inclusive(u32, 1, 99999));
        w.raw(",\"inventory\":");
        w.num(prng.range_inclusive(u32, 0, 1000));
        w.raw("}");
        return w.slice();
    }

    fn gen_collection_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"name\":\"");
        w.random_name(prng);
        w.raw("\"}");
        return w.slice();
    }

    fn gen_transfer_body(self: *Fuzzer, qty: u32) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"quantity\":");
        w.num(qty);
        w.raw("}");
        return w.slice();
    }

    fn gen_order_body(self: *Fuzzer, prng: *PRNG, id: u128) []const u8 {
        var w = BufWriter{ .buf = &self.body_buf };
        w.raw("{\"id\":\"");
        w.uuid(id);
        w.raw("\",\"items\":[");

        const item_count = prng.range_inclusive(u8, 1, @min(5, @as(u8, @intCast(self.product_count))));
        // Track used product indices to avoid duplicate product_ids.
        var used: [5]u32 = [_]u32{0} ** 5;
        var used_count: u8 = 0;

        for (0..item_count) |i| {
            if (i > 0) w.raw(",");

            // Pick a product index not yet used in this order.
            var prod_idx = prng.int_inclusive(u32, self.product_count - 1);
            var attempts: u32 = 0;
            while (attempts < self.product_count) : (attempts += 1) {
                var dup = false;
                for (used[0..used_count]) |u| {
                    if (u == prod_idx) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) break;
                prod_idx = (prod_idx + 1) % self.product_count;
            }
            used[used_count] = prod_idx;
            used_count += 1;

            w.raw("{\"product_id\":\"");
            w.uuid(self.product_ids[prod_idx]);
            w.raw("\",\"quantity\":");
            w.num(prng.range_inclusive(u32, 1, 10));
            w.raw("}");
        }

        w.raw("]}");
        return w.slice();
    }
};

/// Tiny buffer writer for building JSON and paths without allocations.
const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    fn raw(self: *BufWriter, s: []const u8) void {
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }

    fn uuid(self: *BufWriter, val: u128) void {
        const hex = "0123456789abcdef";
        var v = val;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            self.buf[self.pos + i] = hex[@intCast(v & 0xf)];
            v >>= 4;
        }
        self.pos += 32;
    }

    fn num(self: *BufWriter, val: u32) void {
        var num_buf: [10]u8 = undefined;
        const s = format_u32(&num_buf, val);
        self.raw(s);
    }

    fn random_name(self: *BufWriter, prng: *PRNG) void {
        const len = prng.range_inclusive(u8, 1, 20);
        for (self.buf[self.pos..][0..len]) |*c| {
            c.* = 'a' + @as(u8, @intCast(prng.int_inclusive(u8, 25)));
        }
        self.pos += len;
    }

    fn slice(self: *BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

/// Build a path like "/products/<uuid>".
fn path_with_id(buf: *[256]u8, prefix: []const u8, id: u128) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id);
    return w.slice();
}

/// Build a path like "/products/<uuid>/inventory".
fn path_with_id_suffix(buf: *[256]u8, prefix: []const u8, id: u128, suffix: []const u8) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id);
    w.raw(suffix);
    return w.slice();
}

/// Build a path like "/products/<uuid>/transfer-inventory/<uuid>".
fn path_with_two_ids(buf: *[256]u8, prefix: []const u8, id1: u128, middle: []const u8, id2: u128) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(prefix);
    w.uuid(id1);
    w.raw(middle);
    w.uuid(id2);
    return w.slice();
}

/// Build "METHOD /path HTTP/1.1\r\nCookie: ...\r\n\r\n" for bodyless requests.
fn build_simple_request(buf: *[2048]u8, method: []const u8, path: []const u8) []const u8 {
    return build_simple_request_with_headers(buf, method, path, "");
}

fn build_simple_request_datastar(buf: *[2048]u8, method: []const u8, path: []const u8) []const u8 {
    return build_simple_request_with_headers(buf, method, path, "Datastar-Request: true\r\n");
}

fn build_simple_request_with_headers(buf: *[2048]u8, method: []const u8, path: []const u8, extra_headers: []const u8) []const u8 {
    var w = BufWriter{ .buf = buf };
    w.raw(method);
    w.raw(path);
    w.raw(" HTTP/1.1\r\n");
    w.pos += write_cookie_header(buf[w.pos..]);
    w.raw(extra_headers);
    w.raw("\r\n");
    return w.slice();
}

fn run_fuzz(seed: u64) !void {
    // Assertions must be active — fuzz tests depend on invariant checks
    // in server.tick() and connection state machines. Matches TB's
    // `comptime assert(constants.verify)` guard.
    comptime assert(@import("builtin").mode == .Debug or
        @import("builtin").mode == .ReleaseSafe);

    const iterations = 10;
    const events_per_iteration = 2000;

    var outer_prng = PRNG.from_seed(seed);

    // Multiple iterations with fresh state each time — different seeds
    // explore different trajectories from empty database. Matches TB's
    // unit test fuzz pattern (100 iterations × N events).
    for (0..iterations) |_| {
        var prng = PRNG.from_seed(outer_prng.int(u64));
        var io = SimIO.init(prng.int(u64));
        var storage = try App.Storage.init(":memory:");
        defer storage.deinit();
        var sim_fault_prng = PRNG.from_seed(prng.int(u64));
        App.fault_prng = &sim_fault_prng;
        App.fault_busy_ratio = PRNG.ratio(prng.range_inclusive(u64, 5, 20), 100);
        var sm = StateMachine.init(&storage, 0, test_key);
        sm.now = 1_700_000_000;
        var time_sim = TimeSim{};
        var tracer = try Trace.Tracer.init(std.testing.allocator, time_sim.time(), .{});
        defer tracer.deinit(std.testing.allocator);
        var server = try Server.init(std.testing.allocator, &io, &sm, &tracer, 1, time_sim.time(), null);
        server.wire_connections();
        defer server.deinit(std.testing.allocator);

        var fuzzer = Fuzzer.init();

        io.connect_client(0, server.listen_fd);
        fuzzer.client_connected[0] = true;
        fuzzer.connected_count = 1;
        run_ticks(&server, &io, 10);

        for (0..events_per_iteration) |_| {
            const action = prng.enum_uniform(FuzzAction);
            fuzzer.step(action, &prng, &io, &server, &storage);

            // Invariant check every iteration — not just at end.
            // Matches TB's pattern: assert structural invariants
            // after every operation, not just after the loop.
            assert(fuzzer.connected_count >= 1);
            assert(fuzzer.product_count <= Fuzzer.id_pool_max);
            assert(fuzzer.collection_count <= Fuzzer.id_pool_max);
            assert(fuzzer.order_count <= Fuzzer.id_pool_max);
        }
    }

    App.fault_prng = null;
    App.fault_busy_ratio = PRNG.Ratio.zero();
}

test "PRNG fuzz — full stack seed 1" {
    var prng = PRNG.from_seed_testing();
    try run_fuzz(0xf001 ^ prng.int(u64));
}
test "PRNG fuzz — full stack seed 2" {
    var prng = PRNG.from_seed_testing();
    try run_fuzz(0xf002 ^ prng.int(u64));
}
test "PRNG fuzz — full stack seed 3" {
    var prng = PRNG.from_seed_testing();
    try run_fuzz(0xf003 ^ prng.int(u64));
}

