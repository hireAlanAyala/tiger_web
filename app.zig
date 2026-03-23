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

// All 24 handler modules — route functions aggregated in translate().
const handlers = .{
    @import("handlers/get_product.zig"),
    @import("handlers/create_product.zig"),
    @import("handlers/list_products.zig"),
    @import("handlers/update_product.zig"),
    @import("handlers/delete_product.zig"),
    @import("handlers/get_product_inventory.zig"),
    @import("handlers/search_products.zig"),
    @import("handlers/transfer_inventory.zig"),
    @import("handlers/create_collection.zig"),
    @import("handlers/get_collection.zig"),
    @import("handlers/list_collections.zig"),
    @import("handlers/delete_collection.zig"),
    @import("handlers/add_collection_member.zig"),
    @import("handlers/remove_collection_member.zig"),
    @import("handlers/create_order.zig"),
    @import("handlers/get_order.zig"),
    @import("handlers/list_orders.zig"),
    @import("handlers/complete_order.zig"),
    @import("handlers/cancel_order.zig"),
    @import("handlers/page_load_dashboard.zig"),
    @import("handlers/page_load_login.zig"),
    @import("handlers/request_login_code.zig"),
    @import("handlers/verify_login_code.zig"),
    @import("handlers/logout.zig"),
};

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
/// Tries all handler route functions. Asserts at most one matches
/// (duplicate route detection — always, not just in debug).
pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| return client.translate(method, path, body);

    var result: ?Message = null;
    inline for (handlers) |H| {
        if (H.route(method, path, body)) |msg| {
            assert(result == null); // duplicate route match
            result = msg;
        }
    }
    return result;
}

// =====================================================================
// Handler dispatch — replaces state_machine.prefetch() + commit()
//
// The switch IS the dispatch table (TigerBeetle pattern). No handler
// maps, no function pointers, no comptime-generated tables. Each arm
// resolves the concrete handler module and its Prefetch type. The
// compiler verifies exhaustiveness — adding a new operation without
// a handler arm is a compile error.
//
// Why a switch and not a handler map:
// - The decision and the code are in the same place
// - The compiler enforces exhaustiveness
// - No indirection — you read the arm to see what runs
// - Matches TigerBeetle's state_machine.zig dispatch exactly
// =====================================================================

const ReadOnlyStorage = @import("tiger_framework").read_only_storage.ReadOnlyStorage;
const handler_fw = @import("tiger_framework").handler;

/// Unified prefetch + execute dispatch through handler modules.
/// Replaces the old two-phase state_machine.prefetch() + commit().
///
/// Returns null if prefetch returned busy (storage unavailable).
/// The caller should skip this message and retry next tick.
///
/// Cross-cutting concerns (auth, followup, status counting) are handled
/// here so handlers don't have to. Same responsibility as the old
/// state_machine.commit().
pub fn dispatch(
    comptime Storage: type,
    sm: *state_machine.StateMachineType(Storage),
    msg: Message,
) ?MessageResponse {
    // Auth: resolve cookie credential → identity.
    sm.resolve_credential(msg);

    // Dispatch prefetch + execute through the handler switch.
    var resp = dispatch_handler(Storage, sm, msg) orelse return null;

    // Cross-cutting: apply auth identity to response.
    sm.apply_auth_response(&resp);

    // SSE followup: mutations that modify data need a dashboard refresh.
    if (msg.operation.needs_followup() and resp.followup == null) {
        resp.followup = .{
            .operation = msg.operation,
            .status = resp.status,
            .user_id = resp.user_id,
            .kind = resp.kind,
            .session_action = resp.session_action,
            .is_new_visitor = resp.is_new_visitor,
        };
    }

    // Cross-cutting: count every response status.
    sm.tracer.count_status(resp.status);

    return resp;
}

/// The switch — dispatches to the correct handler based on msg.operation.
/// Each arm calls handler.prefetch() with ReadOnlyStorage, constructs the
/// HandlerContext, calls handler.handle(), and applies writes.
///
/// Returns null if prefetch returns null (storage busy).
fn dispatch_handler(
    comptime Storage: type,
    sm: *state_machine.StateMachineType(Storage),
    msg: Message,
) ?MessageResponse {
    const StateMachine = state_machine.StateMachineType(Storage);
    return switch (msg.operation) {
        .root => unreachable,
        .get_product => dispatch_one(@import("handlers/get_product.zig"), StateMachine, sm, msg),
        .create_product => dispatch_one(@import("handlers/create_product.zig"), StateMachine, sm, msg),
        .list_products => dispatch_one(@import("handlers/list_products.zig"), StateMachine, sm, msg),
        .update_product => dispatch_one(@import("handlers/update_product.zig"), StateMachine, sm, msg),
        .delete_product => dispatch_one(@import("handlers/delete_product.zig"), StateMachine, sm, msg),
        .get_product_inventory => dispatch_one(@import("handlers/get_product_inventory.zig"), StateMachine, sm, msg),
        .search_products => dispatch_one(@import("handlers/search_products.zig"), StateMachine, sm, msg),
        .transfer_inventory => dispatch_one(@import("handlers/transfer_inventory.zig"), StateMachine, sm, msg),
        .create_collection => dispatch_one(@import("handlers/create_collection.zig"), StateMachine, sm, msg),
        .get_collection => dispatch_one(@import("handlers/get_collection.zig"), StateMachine, sm, msg),
        .list_collections => dispatch_one(@import("handlers/list_collections.zig"), StateMachine, sm, msg),
        .delete_collection => dispatch_one(@import("handlers/delete_collection.zig"), StateMachine, sm, msg),
        .add_collection_member => dispatch_one(@import("handlers/add_collection_member.zig"), StateMachine, sm, msg),
        .remove_collection_member => dispatch_one(@import("handlers/remove_collection_member.zig"), StateMachine, sm, msg),
        .create_order => dispatch_one(@import("handlers/create_order.zig"), StateMachine, sm, msg),
        .get_order => dispatch_one(@import("handlers/get_order.zig"), StateMachine, sm, msg),
        .list_orders => dispatch_one(@import("handlers/list_orders.zig"), StateMachine, sm, msg),
        .complete_order => dispatch_one(@import("handlers/complete_order.zig"), StateMachine, sm, msg),
        .cancel_order => dispatch_one(@import("handlers/cancel_order.zig"), StateMachine, sm, msg),
        .page_load_dashboard => dispatch_one(@import("handlers/page_load_dashboard.zig"), StateMachine, sm, msg),
        .page_load_login => dispatch_one(@import("handlers/page_load_login.zig"), StateMachine, sm, msg),
        .request_login_code => dispatch_one(@import("handlers/request_login_code.zig"), StateMachine, sm, msg),
        .verify_login_code => dispatch_one(@import("handlers/verify_login_code.zig"), StateMachine, sm, msg),
        .logout => dispatch_one(@import("handlers/logout.zig"), StateMachine, sm, msg),
    };
}

/// Execute one handler's full lifecycle: prefetch → handle → apply writes.
/// The handler's Prefetch type is resolved per-arm by the comptime H parameter.
///
/// The HandlerContext is constructed here from the handler's Prefetch type
/// and the operation's EventType — handlers don't need to export Context.
fn dispatch_one(
    comptime H: type,
    comptime StateMachine: type,
    sm: *StateMachine,
    msg: Message,
) ?MessageResponse {
    // Prefetch: read from storage through ReadOnlyStorage.
    const StorageType = @TypeOf(sm.storage.*);
    const ro = ReadOnlyStorage(StorageType).init(sm.storage);
    const prefetched = H.prefetch(ro, &msg) orelse return null; // busy

    // Handle: if the handler has a handle function, call it.
    // Read-only handlers (no handle) return an empty ok response.
    if (@hasDecl(H, "handle")) {
        const ctx = H.Context{
            .prefetched = prefetched,
            .body = if (H.Context.BodyType == void) {} else msg.body_as(H.Context.BodyType),
            .identity = sm.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity),
            .render_buf = &.{}, // render not wired yet
        };

        const exec_result = H.handle(ctx);

        for (exec_result.writes[0..exec_result.writes_len]) |w| {
            assert(sm.apply_write(w));
        }

        return exec_result.response;
    } else {
        return MessageResponse.empty_ok;
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
/// When the sidecar is active, native commit handles storage (writes, auth,
/// WAL, followup). The sidecar provides HTML. If the sidecar fails, the
/// framework renders natively since the native commit already ran.

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

        // Copy sidecar HTML into send_buf at header_reserve offset,
        // then backfill HTTP headers (Content-Type, Content-Length, etc).
        const html_len = sidecar_resp_buf.html_len;
        assert(render.header_reserve + html_len <= send_buf.len);
        @memcpy(send_buf[render.header_reserve..][0..html_len], sidecar_resp_buf.html[0..html_len]);
        const cookie_hdr = render.format_cookie_header(native_resp, secret_key);
        const set_cookie: ?[]const u8 = if (cookie_hdr.len > 0) cookie_hdr.slice() else null;
        const r = render.backfill_headers(send_buf, html_len, set_cookie);

        return .{
            .status = native_resp.status,
            .followup = native_resp.followup,
            .response = r,
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
    defer storage.deinit(std.testing.allocator);
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
    defer storage.deinit(std.testing.allocator);
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

test "apply_write returns false for duplicate put" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
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
