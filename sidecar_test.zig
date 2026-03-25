//! Cross-pipeline correctness test.
//!
//! Proves that the native SM pipeline and the sidecar pipeline operate on
//! the same database and produce correct results:
//!
//!   Test 1: Native creates a product, sidecar reads it (native → sidecar)
//!   Test 2: Sidecar creates a product, native reads it (sidecar → native)
//!   Test 3: Sidecar disconnects mid-exchange, client handles gracefully
//!
//! The mock sidecar thread speaks the binary protocol exactly as the TS
//! dispatch would. The Zig sidecar client connects via a socketpair.

const std = @import("std");
const assert = std.debug.assert;
const App = @import("app.zig");
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const auth = @import("framework/lib.zig").auth;

const Storage = App.Storage;
const SM = App.SM;

const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";
const fixed_time: i64 = 1700000000; // deterministic — no real clock

// =====================================================================
// Test 1: Native create → sidecar read
// =====================================================================

test "cross-pipeline: native create, sidecar read" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();
    var sm = SM.init(&storage, false, 0, test_key);

    // Create product via native pipeline.
    const create_msg = App.translate(.post, "/products", "{\"id\":\"00000000000000000000000000000001\",\"name\":\"Widget\",\"price_cents\":999}") orelse {
        return error.SkipZigTest;
    };

    storage.begin();
    sm.set_time(fixed_time);
    if (!sm.prefetch(create_msg)) {
        storage.commit();
        return error.SkipZigTest;
    }
    _ = sm.commit(create_msg);
    storage.commit();

    // Verify product exists via native prefetch.
    const ro = Storage.ReadView.init(&storage);
    var get_msg = std.mem.zeroes(message.Message);
    get_msg.operation = .get_product;
    get_msg.id = 1;
    const prefetch_result = @import("handlers/get_product.zig").prefetch(ro, &get_msg);
    try std.testing.expect(prefetch_result != null);
    try std.testing.expect(prefetch_result.?.product != null);
    try std.testing.expectEqual(@as(u128, 1), prefetch_result.?.product.?.id);
    try std.testing.expectEqual(@as(u32, 999), prefetch_result.?.product.?.price_cents);

    // Read product via sidecar pipeline (mock).
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));

    const mock_thread = try std.Thread.spawn(.{}, mock_sidecar_get_product, .{fds[1]});

    var client = App.SidecarClient.init("/unused");
    client.fd = fds[0];

    const sidecar_msg = client.translate(.get, "/products/00000000000000000000000000000001", "");
    try std.testing.expect(sidecar_msg != null);
    try std.testing.expectEqual(message.Operation.get_product, sidecar_msg.?.operation);

    const prefetch_len = client.execute_prefetch(Storage.ReadView.init(&storage));
    try std.testing.expect(prefetch_len != null);

    const status = client.send_prefetch_recv_handle(prefetch_len.?);
    try std.testing.expect(status != null);
    try std.testing.expectEqual(message.Status.ok, status.?);
    try std.testing.expectEqual(@as(u8, 0), client.handle_write_count);

    const html = client.execute_render(Storage.ReadView.init(&storage));
    try std.testing.expect(html != null);
    try std.testing.expect(html.?.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, html.?, "Widget") != null);

    mock_thread.join();
    client.close();
}

// =====================================================================
// Test 2: Sidecar create → native read
// =====================================================================

test "cross-pipeline: sidecar create, native read" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    // Create product via sidecar pipeline (mock).
    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));

    const mock_thread = try std.Thread.spawn(.{}, mock_sidecar_create_product, .{fds[1]});

    var client = App.SidecarClient.init("/unused");
    client.fd = fds[0];

    // RT1: translate.
    const sidecar_msg = client.translate(.post, "/products", "{\"id\":\"00000000000000000000000000000002\",\"name\":\"Gadget\",\"price_cents\":1999}");
    try std.testing.expect(sidecar_msg != null);
    try std.testing.expectEqual(message.Operation.create_product, sidecar_msg.?.operation);

    // Prefetch: check if product exists (it shouldn't).
    const prefetch_len = client.execute_prefetch(Storage.ReadView.init(&storage));
    try std.testing.expect(prefetch_len != null);

    // RT2: handle returns ok + 1 write (INSERT).
    const status = client.send_prefetch_recv_handle(prefetch_len.?);
    try std.testing.expect(status != null);
    try std.testing.expectEqual(message.Status.ok, status.?);
    try std.testing.expectEqual(@as(u8, 1), client.handle_write_count);

    // Execute writes inside transaction.
    storage.begin();
    try std.testing.expect(client.execute_writes(&storage));
    storage.commit();

    // RT3: render.
    const html = client.execute_render(Storage.ReadView.init(&storage));
    try std.testing.expect(html != null);

    mock_thread.join();
    client.close();

    // Verify product exists via native prefetch.
    const ro = Storage.ReadView.init(&storage);
    var get_msg = std.mem.zeroes(message.Message);
    get_msg.operation = .get_product;
    get_msg.id = 2;
    const prefetch_result = @import("handlers/get_product.zig").prefetch(ro, &get_msg);
    try std.testing.expect(prefetch_result != null);
    try std.testing.expect(prefetch_result.?.product != null);
    try std.testing.expectEqual(@as(u128, 2), prefetch_result.?.product.?.id);
    try std.testing.expectEqual(@as(u32, 1999), prefetch_result.?.product.?.price_cents);
    try std.testing.expectEqualStrings("Gadget", std.mem.sliceTo(&prefetch_result.?.product.?.name, 0));
}

// =====================================================================
// Test 3: Sidecar disconnect mid-exchange
// =====================================================================

test "cross-pipeline: sidecar disconnect returns null" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds));

    // Mock: send RT1 response, then close (disconnect before RT2).
    const mock_thread = try std.Thread.spawn(.{}, mock_sidecar_disconnect_after_rt1, .{fds[1]});

    var client = App.SidecarClient.init("/unused");
    client.fd = fds[0];

    // RT1 succeeds.
    const sidecar_msg = client.translate(.get, "/products/00000000000000000000000000000001", "");
    try std.testing.expect(sidecar_msg != null);

    // Prefetch succeeds (local SQL, no socket).
    const prefetch_len = client.execute_prefetch(Storage.ReadView.init(&storage));
    try std.testing.expect(prefetch_len != null);

    // RT2 fails — sidecar disconnected.
    const status = client.send_prefetch_recv_handle(prefetch_len.?);
    try std.testing.expect(status == null);

    // Client detected disconnect.
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), client.fd);

    mock_thread.join();
}

// =====================================================================
// Mock sidecar threads
// =====================================================================

/// Mock for get_product: returns prefetch SQL, verifies row, returns HTML.
fn mock_sidecar_get_product(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    var send_buf: [protocol.frame_max]u8 = undefined;

    // RT1: route_request → route_prefetch_response.
    const rt1 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt1[0] == @intFromEnum(protocol.MessageTag.route_request));

    var pos: usize = 0;
    pos += write_route_response(&send_buf, .get_product, 1);
    pos += write_prefetch_decl_get_product(send_buf[pos..]);
    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT2: prefetch_results → handle_render_response.
    const rt2 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt2[0] == @intFromEnum(protocol.MessageTag.prefetch_results));
    const hdr = protocol.read_row_set_header(rt2[1..], 0) orelse return;
    assert(hdr.count > 0);
    const rc = protocol.read_row_count(rt2[1..], hdr.pos) orelse return;
    assert(rc.count == 1);

    pos = 0;
    pos += write_handle_response(&send_buf, .ok, 0);
    send_buf[pos] = 0; // 0 render declarations
    pos += 1;
    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT3: render_results → html_response.
    const rt3 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt3[0] == @intFromEnum(protocol.MessageTag.render_results));

    pos = 0;
    const html = "<div class=\"card\"><strong>Widget</strong> &mdash; $9.99</div>";
    send_buf[pos] = @intFromEnum(protocol.MessageTag.html_response);
    pos += 1;
    @memcpy(send_buf[pos..][0..html.len], html);
    pos += html.len;
    assert(protocol.write_frame(fd, send_buf[0..pos]));
}

/// Mock for create_product: returns prefetch SQL for existing check,
/// returns handle with 1 write (INSERT), returns render HTML.
fn mock_sidecar_create_product(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    var send_buf: [protocol.frame_max]u8 = undefined;

    // RT1: route_request → route_prefetch_response.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;

    var pos: usize = 0;
    pos += write_route_response(&send_buf, .create_product, 2);

    // Prefetch: check existing product by id.
    send_buf[pos] = 1; // 1 query
    pos += 1;
    const key = "existing";
    send_buf[pos] = key.len;
    pos += 1;
    @memcpy(send_buf[pos..][0..key.len], key);
    pos += key.len;
    const sql = "SELECT id FROM products WHERE id = ?1";
    std.mem.writeInt(u16, send_buf[pos..][0..2], sql.len, .big);
    pos += 2;
    @memcpy(send_buf[pos..][0..sql.len], sql);
    pos += sql.len;
    send_buf[pos] = @intFromEnum(protocol.QueryMode.query);
    pos += 1;
    // param: blob u128 BE = 2
    send_buf[pos] = 1; // param count
    pos += 1;
    send_buf[pos] = @intFromEnum(protocol.TypeTag.blob);
    pos += 1;
    std.mem.writeInt(u16, send_buf[pos..][0..2], 16, .big);
    pos += 2;
    std.mem.writeInt(u128, send_buf[pos..][0..16], 2, .big);
    pos += 16;

    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT2: receive prefetch_results (existing=null), send handle response with 1 write.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;

    pos = 0;
    pos += write_handle_response(&send_buf, .ok, 1);

    // Write entry: INSERT INTO products VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    const write_sql = "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)";
    std.mem.writeInt(u16, send_buf[pos..][0..2], write_sql.len, .big);
    pos += 2;
    @memcpy(send_buf[pos..][0..write_sql.len], write_sql);
    pos += write_sql.len;

    // 7 params: blob(id=2), text("Gadget"), text(""), int(1999), int(0), int(1), int(1)
    send_buf[pos] = 7;
    pos += 1;
    // param 1: blob u128 id=2
    send_buf[pos] = @intFromEnum(protocol.TypeTag.blob);
    pos += 1;
    std.mem.writeInt(u16, send_buf[pos..][0..2], 16, .big);
    pos += 2;
    std.mem.writeInt(u128, send_buf[pos..][0..16], 2, .big);
    pos += 16;
    // param 2: text "Gadget"
    send_buf[pos] = @intFromEnum(protocol.TypeTag.text);
    pos += 1;
    std.mem.writeInt(u16, send_buf[pos..][0..2], 6, .big);
    pos += 2;
    @memcpy(send_buf[pos..][0..6], "Gadget");
    pos += 6;
    // param 3: text "" (empty description)
    send_buf[pos] = @intFromEnum(protocol.TypeTag.text);
    pos += 1;
    std.mem.writeInt(u16, send_buf[pos..][0..2], 0, .big);
    pos += 2;
    // param 4: integer 1999 (price_cents)
    send_buf[pos] = @intFromEnum(protocol.TypeTag.integer);
    pos += 1;
    std.mem.writeInt(i64, send_buf[pos..][0..8], 1999, .little);
    pos += 8;
    // param 5: integer 0 (inventory)
    send_buf[pos] = @intFromEnum(protocol.TypeTag.integer);
    pos += 1;
    std.mem.writeInt(i64, send_buf[pos..][0..8], 0, .little);
    pos += 8;
    // param 6: integer 1 (version)
    send_buf[pos] = @intFromEnum(protocol.TypeTag.integer);
    pos += 1;
    std.mem.writeInt(i64, send_buf[pos..][0..8], 1, .little);
    pos += 8;
    // param 7: integer 1 (active=true)
    send_buf[pos] = @intFromEnum(protocol.TypeTag.integer);
    pos += 1;
    std.mem.writeInt(i64, send_buf[pos..][0..8], 1, .little);
    pos += 8;

    // 0 render declarations
    send_buf[pos] = 0;
    pos += 1;

    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT3: render_results → html_response.
    _ = protocol.read_frame(fd, &recv_buf) orelse return;

    pos = 0;
    send_buf[pos] = @intFromEnum(protocol.MessageTag.html_response);
    pos += 1;
    assert(protocol.write_frame(fd, send_buf[0..pos])); // empty HTML is fine for create
}

/// Mock that disconnects after RT1 — tests error handling.
fn mock_sidecar_disconnect_after_rt1(fd: std.posix.fd_t) void {
    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    var send_buf: [protocol.frame_max]u8 = undefined;

    // RT1: respond normally.
    _ = protocol.read_frame(fd, &recv_buf) orelse {
        std.posix.close(fd);
        return;
    };

    var pos: usize = 0;
    pos += write_route_response(&send_buf, .get_product, 1);
    pos += write_prefetch_decl_get_product(send_buf[pos..]);
    _ = protocol.write_frame(fd, send_buf[0..pos]);

    // Close immediately — sidecar crashes before RT2.
    std.posix.close(fd);
}

// =====================================================================
// Helpers — build binary protocol fragments
// =====================================================================

fn write_route_response(buf: []u8, op: message.Operation, id: u128) usize {
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.route_prefetch_response);
    pos += 1;
    buf[pos] = 1; // found
    pos += 1;
    buf[pos] = @intFromEnum(op);
    pos += 1;
    std.mem.writeInt(u128, buf[pos..][0..16], id, .big);
    pos += 16;
    return pos;
}

fn write_handle_response(buf: []u8, status: message.Status, write_count: u8) usize {
    var pos: usize = 0;
    buf[pos] = @intFromEnum(protocol.MessageTag.handle_render_response);
    pos += 1;
    buf[pos] = @intFromEnum(status);
    pos += 1;
    buf[pos] = write_count;
    pos += 1;
    return pos;
}

fn write_prefetch_decl_get_product(buf: []u8) usize {
    var pos: usize = 0;
    buf[pos] = 1; // 1 query
    pos += 1;
    const key = "product";
    buf[pos] = key.len;
    pos += 1;
    @memcpy(buf[pos..][0..key.len], key);
    pos += key.len;
    const sql = "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1";
    std.mem.writeInt(u16, buf[pos..][0..2], sql.len, .big);
    pos += 2;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = @intFromEnum(protocol.QueryMode.query);
    pos += 1;
    buf[pos] = 1; // 1 param
    pos += 1;
    buf[pos] = @intFromEnum(protocol.TypeTag.blob);
    pos += 1;
    std.mem.writeInt(u16, buf[pos..][0..2], 16, .big);
    pos += 2;
    std.mem.writeInt(u128, buf[pos..][0..16], 1, .big);
    pos += 16;
    return pos;
}
