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
/// Debug: panics on divergence — catches bugs during development.
/// Release: logs and continues — divergence is a handler bug, not corruption.
fn spot_check_translate(path: []const u8, sidecar_result: ?Message, native_result: ?Message) void {
    const sidecar_msg = sidecar_result orelse {
        if (native_result != null) {
            spot_check_fail("spot-check divergence: sidecar=null native={s} path={s}", .{
                @tagName(native_result.?.operation), path,
            });
        }
        return;
    };
    const native_msg = native_result orelse {
        spot_check_fail("spot-check divergence: sidecar={s} native=null path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
        return;
    };

    if (sidecar_msg.operation != native_msg.operation) {
        spot_check_fail("spot-check divergence: operation sidecar={s} native={s} path={s}", .{
            @tagName(sidecar_msg.operation), @tagName(native_msg.operation), path,
        });
        return;
    }

    if (sidecar_msg.id != native_msg.id) {
        spot_check_fail("spot-check divergence: id mismatch for {s} path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
        return;
    }

    if (!std.mem.eql(u8, &sidecar_msg.body, &native_msg.body)) {
        spot_check_fail("spot-check divergence: body mismatch for {s} path={s}", .{
            @tagName(sidecar_msg.operation), path,
        });
    }
}

/// Debug: panic. Release: log and continue.
fn spot_check_fail(comptime fmt: []const u8, args: anytype) void {
    log.mark.err(fmt, args);
    if (@import("builtin").mode == .Debug) {
        @panic("spot-check divergence");
    }
}

/// Extract the prefetch cache from the state machine into the protocol struct.
/// Called after prefetch() succeeds, before execute. Copies all 11 slots
/// with presence flags for nullable fields.
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
