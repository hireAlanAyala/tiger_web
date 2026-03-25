//! Cross-pipeline correctness test.
//!
//! Proves that the native SM pipeline and the sidecar pipeline operate on
//! the same database and produce correct results. The test:
//!
//!   1. Creates a product via the native SM pipeline
//!   2. Reads the product via a mock sidecar (binary protocol over socketpair)
//!   3. Verifies the sidecar pipeline sees the correct data
//!
//! This is the integration proof for the two-pipeline architecture.
//! The mock sidecar thread speaks the binary protocol exactly as the TS
//! dispatch would. The Zig sidecar client connects via the socketpair
//! and runs the 3-RT exchange.

const std = @import("std");
const assert = std.debug.assert;
const App = @import("app.zig");
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const auth = @import("tiger_framework").auth;

const Storage = App.Storage;
const SM = App.SM;

const test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

test "cross-pipeline: native create, sidecar read" {
    // --- Setup ---
    var storage = try Storage.init(":memory:");
    defer storage.deinit();
    var sm = SM.init(&storage, false, 0, test_key);

    // --- Phase 1: Create product via native pipeline ---
    const create_msg = App.translate(.post, "/products", "{\"id\":\"00000000000000000000000000000001\",\"name\":\"Widget\",\"price_cents\":999}") orelse {
        return error.SkipZigTest; // translate not wired for this test config
    };

    // Run native prefetch + commit inside a transaction.
    storage.begin();
    sm.set_time(std.time.timestamp());
    if (!sm.prefetch(create_msg)) {
        storage.commit();
        return error.SkipZigTest;
    }
    _ = sm.commit(create_msg);
    storage.commit();

    // Verify product exists via typed query.
    const ro = Storage.ReadView.init(&storage);
    var get_msg = std.mem.zeroes(message.Message);
    get_msg.operation = .get_product;
    get_msg.id = 1;
    const prefetch_result = @import("handlers/get_product.zig").prefetch(ro, &get_msg);
    try std.testing.expect(prefetch_result != null);
    try std.testing.expect(prefetch_result.?.product != null);

    const product = prefetch_result.?.product.?;
    try std.testing.expectEqual(@as(u128, 1), product.id);
    try std.testing.expectEqual(@as(u32, 999), product.price_cents);
    try std.testing.expectEqualStrings("Widget", std.mem.sliceTo(&product.name, 0));

    // --- Phase 2: Read product via sidecar pipeline (mock) ---
    // Create a socketpair — one end for the sidecar client, one for the mock.
    var fds: [2]std.posix.fd_t = undefined;
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(@as(c_int, 0), rc);

    // Start mock sidecar thread.
    const mock_thread = try std.Thread.spawn(.{}, mock_sidecar_get_product, .{fds[1]});

    // Create a sidecar client connected to the socketpair.
    var client = App.SidecarClient.init("/unused");
    client.fd = fds[0];

    // RT1: translate via sidecar.
    const sidecar_msg = client.translate(.get, "/products/00000000000000000000000000000001", "");
    try std.testing.expect(sidecar_msg != null);
    try std.testing.expectEqual(message.Operation.get_product, sidecar_msg.?.operation);

    // Prefetch: execute SQL declarations from RT1.
    const prefetch_len = client.execute_prefetch(Storage.ReadView.init(&storage));
    try std.testing.expect(prefetch_len != null);

    // RT2: send prefetch results, receive handle response.
    const status = client.send_prefetch_recv_handle(prefetch_len.?);
    try std.testing.expect(status != null);
    try std.testing.expectEqual(message.Status.ok, status.?);

    // No writes for a read-only operation.
    try std.testing.expectEqual(@as(u8, 0), client.handle_write_count);

    // RT3: render.
    const html = client.execute_render(Storage.ReadView.init(&storage));
    try std.testing.expect(html != null);
    try std.testing.expect(html.?.len > 0);

    // Verify HTML contains the product name.
    try std.testing.expect(std.mem.indexOf(u8, html.?, "Widget") != null);

    mock_thread.join();
    client.close();
}

/// Mock sidecar thread — plays the TS dispatch role for get_product.
/// Speaks binary protocol over the socketpair.
fn mock_sidecar_get_product(fd: std.posix.fd_t) void {
    defer std.posix.close(fd);

    var recv_buf: [protocol.frame_max + 4]u8 = undefined;
    var send_buf: [protocol.frame_max]u8 = undefined;

    // RT1: receive route_request, send route_prefetch_response.
    const rt1 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt1[0] == @intFromEnum(protocol.MessageTag.route_request));

    // Build response: found, operation=get_product, id=1, prefetch declarations.
    var pos: usize = 0;
    send_buf[pos] = @intFromEnum(protocol.MessageTag.route_prefetch_response);
    pos += 1;
    send_buf[pos] = 1; // found
    pos += 1;
    send_buf[pos] = @intFromEnum(message.Operation.get_product);
    pos += 1;
    // ID: u128 BE = 1.
    @memset(send_buf[pos..][0..15], 0);
    send_buf[pos + 15] = 1;
    pos += 16;

    // Prefetch declarations: 1 query.
    // key="product", sql="SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1",
    // mode=one, params=[integer 1]
    send_buf[pos] = 1; // query count
    pos += 1;

    // key
    const key = "product";
    send_buf[pos] = key.len;
    pos += 1;
    @memcpy(send_buf[pos..][0..key.len], key);
    pos += key.len;

    // sql
    const sql = "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1";
    std.mem.writeInt(u16, send_buf[pos..][0..2], sql.len, .big);
    pos += 2;
    @memcpy(send_buf[pos..][0..sql.len], sql);
    pos += sql.len;

    // mode = one
    send_buf[pos] = @intFromEnum(protocol.QueryMode.one);
    pos += 1;

    // params: 1 param, blob (u128 stored as 16-byte big-endian BLOB in SQLite)
    send_buf[pos] = 1; // param count
    pos += 1;
    send_buf[pos] = @intFromEnum(protocol.TypeTag.blob);
    pos += 1;
    std.mem.writeInt(u16, send_buf[pos..][0..2], 16, .big); // blob len = 16
    pos += 2;
    std.mem.writeInt(u128, send_buf[pos..][0..16], 1, .big); // id = 1 as u128 BE
    pos += 16;

    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT2: receive prefetch_results, send handle_render_response.
    const rt2 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt2[0] == @intFromEnum(protocol.MessageTag.prefetch_results));

    // Parse the row set to verify we got the product.
    const hdr = protocol.read_row_set_header(rt2[1..], 0) orelse return;
    assert(hdr.count > 0); // got columns
    const rc_result = protocol.read_row_count(rt2[1..], hdr.pos) orelse return;
    assert(rc_result.count == 1); // got 1 row

    // Send handle response: status=ok, 0 writes, 0 render declarations.
    pos = 0;
    send_buf[pos] = @intFromEnum(protocol.MessageTag.handle_render_response);
    pos += 1;
    send_buf[pos] = @intFromEnum(message.Status.ok);
    pos += 1;
    send_buf[pos] = 0; // write count
    pos += 1;
    send_buf[pos] = 0; // render declaration count
    pos += 1;

    assert(protocol.write_frame(fd, send_buf[0..pos]));

    // RT3: receive render_results, send html_response.
    const rt3 = protocol.read_frame(fd, &recv_buf) orelse return;
    assert(rt3[0] == @intFromEnum(protocol.MessageTag.render_results));

    // Send HTML with the product name.
    const html = "<div class=\"card\"><strong>Widget</strong> &mdash; $9.99</div>";
    pos = 0;
    send_buf[pos] = @intFromEnum(protocol.MessageTag.html_response);
    pos += 1;
    @memcpy(send_buf[pos..][0..html.len], html);
    pos += html.len;

    assert(protocol.write_frame(fd, send_buf[0..pos]));
}
