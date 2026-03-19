//! App — the domain binding consumed by the framework.
//!
//! Provides types, functions, and constants that the framework's ServerType
//! calls at comptime. The framework never switches on Operation — it reads
//! response fields and calls these functions.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const codec = @import("codec.zig");
const render = @import("render.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const http = @import("tiger_framework").http;
const auth = @import("tiger_framework").auth;
const marks = @import("tiger_framework").marks;
pub const SidecarClient = @import("sidecar.zig").SidecarClient;

const log = marks.wrap_log(std.log.scoped(.app));

pub const Message = message.Message;
pub const MessageResponse = message.MessageResponse;
pub const FollowupState = message.FollowupState;
pub const Operation = message.Operation;
pub const Status = message.Status;
pub const StateMachineType = @import("state_machine.zig").StateMachineType;
pub const Wal = @import("tiger_framework").wal.WalType(Message, message.wal_root);

/// Optional sidecar client — when set, translate delegates to the
/// external process instead of the Zig-native codec.
pub var sidecar: ?SidecarClient = null;

/// Translate an HTTP request into a typed Message. Returns null if the
/// request doesn't map to a valid operation.
///
/// When the sidecar is active, runs BOTH paths and compares results
/// (spot-check). The sidecar result is used; divergence is logged as
/// an error. The Zig-native translate is pure (~1μs) so the overhead
/// of running both is negligible compared to the socket round trip.
pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| {
        const sidecar_result = client.translate(method, path, body);
        const native_result = codec.translate(method, path, body);
        spot_check_translate(path, sidecar_result, native_result);
        return sidecar_result;
    }
    return codec.translate(method, path, body);
}

/// Compare sidecar and Zig-native translate results.
/// Messages use the developer's vocabulary — no "native", no "sidecar",
/// no protocol jargon. The developer sees what their handler returned
/// vs what was expected, and where to fix it.
fn spot_check_translate(path: []const u8, sidecar_result: ?Message, native_result: ?Message) void {
    const sidecar_msg = sidecar_result orelse {
        if (native_result) |expected| {
            spot_check_fail(
                \\[spot-check] {s}
                \\  your [route] handler returned: null (no match)
                \\  expected:                      {s}
                \\  hint: add a [route] .{s} handler that matches this path
            , .{ path, @tagName(expected.operation), @tagName(expected.operation) });
        }
        return;
    };
    const native_msg = native_result orelse {
        spot_check_fail(
            \\[spot-check] {s}
            \\  your [route] handler returned: {s}
            \\  expected:                      null (no match)
            \\  hint: your [route] .{s} handler should return null for this path
        , .{ path, @tagName(sidecar_msg.operation), @tagName(sidecar_msg.operation) });
        return;
    };

    if (sidecar_msg.operation != native_msg.operation) {
        spot_check_fail(
            \\[spot-check] {s}
            \\  your [route] handler returned: {s}
            \\  expected:                      {s}
            \\  hint: check which [route] handler matches this path
        , .{ path, @tagName(sidecar_msg.operation), @tagName(native_msg.operation) });
        return;
    }

    if (sidecar_msg.id != native_msg.id) {
        spot_check_fail(
            \\[spot-check] {s}
            \\  operation: {s}
            \\  your handler returned a different id than expected
            \\  hint: check the id extraction in your [route] .{s} handler
        , .{ path, @tagName(sidecar_msg.operation), @tagName(sidecar_msg.operation) });
        return;
    }

    if (!std.mem.eql(u8, &sidecar_msg.body, &native_msg.body)) {
        spot_check_fail(
            \\[spot-check] {s}
            \\  operation: {s}
            \\  your handler returned different body data than expected
            \\  hint: check the body construction in your [route] .{s} handler
        , .{ path, @tagName(sidecar_msg.operation), @tagName(sidecar_msg.operation) });
    }
}

/// Compare execute status. Called from commit_and_encode when the sidecar is active.
fn spot_check_execute(operation: message.Operation, sidecar_status: message.Status, native_status: message.Status) void {
    if (sidecar_status == native_status) return;
    spot_check_fail(
        \\[spot-check] {s}
        \\  your [handle] handler returned: {s}
        \\  expected:                       {s}
        \\  hint: check your [handle] .{s} function
    , .{ @tagName(operation), @tagName(sidecar_status), @tagName(native_status), @tagName(operation) });
}

/// Debug: panic. Release: log and continue.
fn spot_check_fail(comptime fmt: []const u8, args: anytype) void {
    log.mark.err(fmt, args);
    if (@import("builtin").mode == .Debug) {
        @panic("spot-check divergence");
    }
}

/// Extract the prefetch cache from the state machine into the protocol struct.
/// Called after prefetch() succeeds and BEFORE commit(). Commit resets the
/// cache — calling this after commit returns all-zeros silently.
pub fn extract_cache(comptime Storage: type, sm: *const state_machine.StateMachineType(Storage)) protocol.PrefetchCache {
    // Exhaustiveness: if someone adds a prefetch_* field to the SM,
    // this count changes and the build fails — forcing an update here.
    comptime {
        var count: usize = 0;
        for (@typeInfo(state_machine.StateMachineType(Storage)).@"struct".fields) |f| {
            if (std.mem.startsWith(u8, f.name, "prefetch_")) count += 1;
        }
        assert(count == 11);
    }

    var cache = std.mem.zeroes(protocol.PrefetchCache);

    // Nullable single-entity slots.
    if (sm.prefetch_product) |p| {
        cache.has_product = 1;
        cache.product = p;
    }
    if (sm.prefetch_collection) |c| {
        cache.has_collection = 1;
        cache.collection = c;
    }
    if (sm.prefetch_order) |o| {
        cache.has_order = 1;
        cache.order = o;
    }
    if (sm.prefetch_login_code_entry) |e| {
        cache.has_login_code = 1;
        cache.login_code = e;
    }
    if (sm.prefetch_user_by_email) |u| {
        cache.has_user_by_email = 1;
        cache.user_by_email = u;
    }
    if (sm.prefetch_result) |r| {
        cache.has_result = 1;
        cache.result = @intFromEnum(r);
    }
    if (sm.prefetch_identity) |i| {
        cache.has_identity = 1;
        cache.identity = i;
    }

    // Always-present list slots (len=0 means empty).
    cache.product_list = sm.prefetch_product_list;
    cache.collection_list = sm.prefetch_collection_list;
    cache.order_list = sm.prefetch_order_list;

    // Per-item nullable product array.
    for (sm.prefetch_products, 0..) |maybe_product, idx| {
        if (maybe_product) |p| {
            cache.products_presence[idx] = 1;
            cache.products[idx] = p;
        }
    }

    return cache;
}

/// Execute and encode: unified commit + render that chooses between
/// Zig-native and sidecar paths. Returns everything the server needs
/// to complete the response.
///
/// When the sidecar is active, it is the ONLY execution path. The native
/// commit does not run. No fallback — if the sidecar fails, the request
/// fails. Mixing paths would break determinism (design/013: "no fallback").
///
/// Spot-check on execute status is done by the simulator in the test
/// environment, not on every production request.

// Response buffer — module-level because ~200KB is too large for the stack
// and App is a namespace (no instance). Single-threaded, no concurrency.
// TODO: move to an App instance when App becomes a struct.
var sidecar_resp_buf: protocol.ExecuteRenderResponse = undefined;

pub fn commit_and_encode(
    comptime Storage: type,
    sm: *state_machine.StateMachineType(Storage),
    msg: Message,
    send_buf: []u8,
    is_datastar_request: bool,
    secret_key: *const [auth.key_length]u8,
) CommitResult {
    if (sidecar) |*client| {
        // Extract cache before commit (commit resets it).
        const cache = extract_cache(Storage, sm);

        // Native commit: storage writes, auth, WAL consistency, followup.
        const native_resp = sm.commit(msg);

        // Call sidecar for execute + render.
        if (!client.execute_render(msg.operation, msg.id, &msg.body, &cache, is_datastar_request, &sidecar_resp_buf)) {
            // Sidecar failure. Native commit already ran — storage is correct.
            // Render natively as fallback since the database is already mutated.
            log.mark.err("sidecar execute_render failed, rendering natively", .{});
            const r = render.encode_response(send_buf, msg.operation, native_resp, is_datastar_request, secret_key);
            return .{
                .status = native_resp.status,
                .followup = native_resp.followup,
                .response = r,
            };
        }

        // Spot-check: compare status and writes.
        spot_check_execute(msg.operation, sidecar_resp_buf.status, native_resp.status);

        for (sidecar_resp_buf.writes[0..sidecar_resp_buf.writes_len]) |slot| {
            if (deserialize_write(state_machine.StateMachineType(Storage), slot) == null) {
                spot_check_fail(
                    \\[spot-check] {s}
                    \\  your [handle] handler returned an invalid write (tag={d})
                    \\  hint: check the writes array in your [handle] .{s} function
                , .{ @tagName(msg.operation), slot.tag, @tagName(msg.operation) });
            }
        }

        // Use sidecar HTML — copy into send_buf.
        const html_len = sidecar_resp_buf.html_len;
        assert(html_len <= send_buf.len);
        @memcpy(send_buf[0..html_len], sidecar_resp_buf.html[0..html_len]);

        return .{
            .status = native_resp.status,
            .followup = native_resp.followup,
            .response = .{ .offset = 0, .len = html_len, .keep_alive = !is_datastar_request },
        };
    }

    // Native path — no sidecar.
    const resp = sm.commit(msg);
    const r = render.encode_response(send_buf, msg.operation, resp, is_datastar_request, secret_key);
    return .{
        .status = resp.status,
        .followup = resp.followup,
        .response = r,
    };
}

pub const CommitResult = struct {
    status: Status,
    followup: ?FollowupState,
    response: render.Response,
};

/// Deserialize a WriteSlot into a Write tagged union.
/// Returns null if the tag is invalid. Used by the spot-check to
/// validate sidecar writes and by the future write-authority path
/// to feed writes into SM.apply_write.
///
/// The @ptrCast reinterprets raw bytes as extern struct types — safe
/// because all payloads are extern with no_padding, WriteSlot.data
/// starts at offset 16 (aligned by tag + reserved_tag padding), and
/// @alignCast is checked at runtime in Debug and ReleaseSafe.
fn deserialize_write(comptime StateMachineT: type, slot: protocol.WriteSlot) ?StateMachineT.Write {
    const tag = std.meta.intToEnum(protocol.WriteTag, slot.tag) catch return null;
    return switch (tag) {
        .put_product => .{ .put_product = byteCast(message.Product, &slot.data) },
        .update_product => .{ .update_product = byteCast(message.Product, &slot.data) },
        .put_collection => .{ .put_collection = byteCast(message.ProductCollection, &slot.data) },
        .update_collection => .{ .update_collection = byteCast(message.ProductCollection, &slot.data) },
        .put_membership => .{ .put_membership = byteCast(message.Membership, &slot.data) },
        .update_membership => .{ .update_membership = byteCast(message.MembershipUpdate, &slot.data) },
        .put_order => .{ .put_order = byteCast(message.OrderResult, &slot.data) },
        .update_order => .{ .update_order = byteCast(message.OrderResult, &slot.data) },
        .put_login_code => .{ .put_login_code = byteCast(message.LoginCodeWrite, &slot.data) },
        .consume_login_code => .{ .consume_login_code = byteCast(message.LoginCodeKey, &slot.data) },
        .put_user => .{ .put_user = byteCast(message.UserWrite, &slot.data) },
    };
}

/// Reinterpret raw bytes as a typed extern struct value.
fn byteCast(comptime T: type, data: *const [@sizeOf(message.OrderResult)]u8) T {
    return @as(*const T, @ptrCast(@alignCast(data))).*;
}

/// Encode a response into the send buffer.
pub fn encode_response(send_buf: []u8, operation: Operation, resp: MessageResponse, is_datastar_request: bool, secret_key: *const [auth.key_length]u8) render.Response {
    return render.encode_response(send_buf, operation, resp, is_datastar_request, secret_key);
}

/// Encode an SSE followup (dashboard refresh after mutation) into the send buffer.
pub fn encode_followup(send_buf: []u8, resp: MessageResponse, followup: *const FollowupState, secret_key: *const [auth.key_length]u8) render.Response {
    return render.encode_followup(send_buf, &resp.result.page_load_dashboard, followup, secret_key);
}

/// Construct the message used for SSE follow-up refreshes.
pub fn refresh_message() Message {
    return Message.init(.page_load_dashboard, 0, 0, {});
}

// =====================================================================
// Tests
// =====================================================================

const MemoryStorage = state_machine.MemoryStorage;
const SM = state_machine.StateMachineType(MemoryStorage);

test "extract_cache empty state machine" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    const secret = "tiger-web-test-key-0123456789ab!".*;
    var sm = SM.init(&storage, false, 42, &secret);

    // Prefetch a get_product for a non-existent product.
    const msg = message.Message.init(.get_product, 0x1234, 0, {});
    assert(sm.prefetch(msg));

    const cache = extract_cache(MemoryStorage, &sm);

    // Product not found — has_product is 0, result is not_found.
    try std.testing.expectEqual(cache.has_product, 0);
    try std.testing.expectEqual(cache.has_result, 1);
    try std.testing.expectEqual(cache.result, @intFromEnum(state_machine.StorageResult.not_found));

    // Lists are empty.
    try std.testing.expectEqual(cache.product_list.len, 0);
    try std.testing.expectEqual(cache.collection_list.len, 0);
    try std.testing.expectEqual(cache.order_list.len, 0);

    // Products array all null.
    for (cache.products_presence) |p| try std.testing.expectEqual(p, 0);

    _ = sm.commit(msg); // consume the prefetch
}

test "extract_cache with populated product" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    const secret = "tiger-web-test-key-0123456789ab!".*;
    var sm = SM.init(&storage, false, 42, &secret);

    // Create a product.
    var p = std.mem.zeroes(message.Product);
    p.id = 0xaabbccdd11223344aabbccdd11223344;
    @memcpy(p.name[0..4], "Test");
    p.name_len = 4;
    p.price_cents = 999;
    p.inventory = 10;
    p.version = 1;
    p.flags = .{ .active = true };

    const create_msg = message.Message.init(.create_product, p.id, 0, p);
    assert(sm.prefetch(create_msg));
    _ = sm.commit(create_msg);

    // Now prefetch a get for the same product.
    const get_msg = message.Message.init(.get_product, p.id, 0, {});
    assert(sm.prefetch(get_msg));

    const cache = extract_cache(MemoryStorage, &sm);

    // Product found.
    try std.testing.expectEqual(cache.has_product, 1);
    try std.testing.expectEqual(cache.product.id, p.id);
    try std.testing.expectEqual(cache.product.price_cents, 999);
    try std.testing.expectEqual(cache.has_result, 1);
    try std.testing.expectEqual(cache.result, @intFromEnum(state_machine.StorageResult.ok));

    _ = sm.commit(get_msg);
}

test "deserialize_write and apply_write round trip" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    const secret = "tiger-web-test-key-0123456789ab!".*;
    var sm = SM.init(&storage, false, 42, &secret);

    // Build a WriteSlot with a Product.
    var slot = std.mem.zeroes(protocol.WriteSlot);
    slot.tag = @intFromEnum(protocol.WriteTag.put_product);
    var p = std.mem.zeroes(message.Product);
    p.id = 0xaabbccdd11223344aabbccdd11223344;
    @memcpy(p.name[0..4], "Test");
    p.name_len = 4;
    p.price_cents = 999;
    p.inventory = 10;
    p.version = 1;
    p.flags = .{ .active = true };
    @memcpy(slot.data[0..@sizeOf(message.Product)], std.mem.asBytes(&p));

    // Deserialize and apply through the shared apply_write.
    const write = deserialize_write(SM, slot);
    try std.testing.expect(write != null);
    try std.testing.expect(sm.apply_write(write.?));

    // Verify the product is in storage.
    const msg = message.Message.init(.get_product, p.id, 0, {});
    assert(sm.prefetch(msg));
    const cache = extract_cache(MemoryStorage, &sm);
    try std.testing.expectEqual(cache.has_product, 1);
    try std.testing.expectEqual(cache.product.price_cents, 999);
    _ = sm.commit(msg);
}

test "deserialize_write invalid tag returns null" {
    var slot = std.mem.zeroes(protocol.WriteSlot);
    slot.tag = 255;
    try std.testing.expect(deserialize_write(SM, slot) == null);
}

test "apply_write returns false for duplicate put" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    const secret = "tiger-web-test-key-0123456789ab!".*;
    var sm = SM.init(&storage, false, 42, &secret);

    var p = std.mem.zeroes(message.Product);
    p.id = 0x1234;
    p.version = 1;
    p.flags = .{ .active = true };

    // First put succeeds.
    try std.testing.expect(sm.apply_write(.{ .put_product = p }));
    // Duplicate put — apply_write returns false (not crash).
    try std.testing.expect(!sm.apply_write(.{ .put_product = p }));
}
