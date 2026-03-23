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
const PRNG = @import("tiger_framework").prng;
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
/// PrefetchCache — tagged union of all handler Prefetch types.
///
/// Stored on the SM as an opaque field between prefetch() and commit().
/// The SM doesn't know what's inside — it stores it in prefetch, hands
/// it back in commit. App.handler_prefetch fills it, App.handler_execute
/// unpacks it. One type parameter, one field, clean dependency direction.
/// Fields ordered to match Operation enum declaration order (required by Zig).
pub const PrefetchCache = union(Operation) {
    root: void,
    create_product: @import("handlers/create_product.zig").Prefetch,
    get_product: @import("handlers/get_product.zig").Prefetch,
    list_products: @import("handlers/list_products.zig").Prefetch,
    update_product: @import("handlers/update_product.zig").Prefetch,
    delete_product: @import("handlers/delete_product.zig").Prefetch,
    get_product_inventory: @import("handlers/get_product_inventory.zig").Prefetch,
    transfer_inventory: @import("handlers/transfer_inventory.zig").Prefetch,
    create_order: @import("handlers/create_order.zig").Prefetch,
    get_order: @import("handlers/get_order.zig").Prefetch,
    list_orders: @import("handlers/list_orders.zig").Prefetch,
    complete_order: @import("handlers/complete_order.zig").Prefetch,
    cancel_order: @import("handlers/cancel_order.zig").Prefetch,
    search_products: @import("handlers/search_products.zig").Prefetch,
    create_collection: @import("handlers/create_collection.zig").Prefetch,
    get_collection: @import("handlers/get_collection.zig").Prefetch,
    list_collections: @import("handlers/list_collections.zig").Prefetch,
    delete_collection: @import("handlers/delete_collection.zig").Prefetch,
    add_collection_member: @import("handlers/add_collection_member.zig").Prefetch,
    remove_collection_member: @import("handlers/remove_collection_member.zig").Prefetch,
    page_load_dashboard: @import("handlers/page_load_dashboard.zig").Prefetch,
    page_load_login: @import("handlers/page_load_login.zig").Prefetch,
    request_login_code: @import("handlers/request_login_code.zig").Prefetch,
    verify_login_code: @import("handlers/verify_login_code.zig").Prefetch,
    logout: @import("handlers/logout.zig").Prefetch,
};

/// Handlers interface — passed to StateMachineType so the SM can call
/// handler dispatch without importing App. The SM is parameterized on
/// this type. It calls prefetch/execute through it. App defines the
/// implementation. Clean one-way dependency: App → SM, never SM → App.
/// Fault injection configuration — module-level because single-threaded,
/// one message at a time. Set by sim/fuzz tests before running operations.
/// Production leaves these at defaults (no faults).
pub var fault_prng: ?*PRNG = null;
pub var fault_busy_ratio: PRNG.Ratio = PRNG.Ratio.zero();

pub fn HandlersType(comptime StorageParam: type) type {
    return struct {
        pub const Cache = PrefetchCache;

        /// Called by the SM's prefetch(). Wraps storage in its ReadView
        /// (read-only) and dispatches to the handler's prefetch function.
        /// Fault injection happens here — before the handler runs.
        pub fn handler_prefetch(storage: *StorageParam, msg: *const Message) ?PrefetchCache {
            // Fault injection: return null (busy) based on PRNG.
            // The handler never sees the fault. The SM sees null → retry.
            if (fault_prng) |prng| {
                if (prng.chance(fault_busy_ratio)) return null;
            }
            const ro = StorageParam.ReadView.init(storage);
            return dispatch_prefetch(ro, msg);
        }

        pub const FwCtx = @import("tiger_framework").handler.FrameworkCtx(message.PrefetchIdentity);

        pub fn handler_execute(
            cache: PrefetchCache,
            msg: Message,
            fw: FwCtx,
        ) state_machine.ExecuteResult {
            return dispatch_execute(cache, msg, fw);
        }
    };
}

pub fn StateMachineType(comptime StorageParam: type) type {
    return state_machine.StateMachineType(StorageParam, HandlersType(StorageParam));
}

// --- Composition root ---
//
// The App binds all type parameters once. Every other file imports App
// and uses these concrete types. Nobody else imports storage.zig or
// picks a storage backend. The App made that choice.
//
// This is the composition root pattern — one place binds types,
// everyone else consumes. Same as TigerBeetle's vsr.zig.
pub const Storage = @import("storage.zig").SqliteStorage;
pub const SM = StateMachineType(Storage);

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
// Handler dispatch — called by the SM through the Handlers interface.
//
// The switch IS the dispatch table (TigerBeetle pattern). No handler
// maps, no function pointers, no comptime-generated tables. Each arm
// resolves the concrete handler module and its Prefetch type. The
// compiler verifies exhaustiveness — adding a new operation without
// a handler arm is a compile error.
//
// Split into two phases matching the SM's prefetch/commit lifecycle:
// - dispatch_prefetch: calls handler.prefetch() via ReadOnlyStorage,
//   returns ?PrefetchCache (null = busy).
// - dispatch_execute: unpacks PrefetchCache, constructs HandlerContext,
//   calls handler.handle(), applies writes via callback.
//
// The SM owns the cross-cutting concerns (auth, followup, tracer).
// These functions own the handler dispatch logic.
// =====================================================================

// ReadOnlyStorage enforcement is now via Storage.ReadView — see db-configuration.md.

/// Phase 1: dispatch to handler.prefetch() via ReadOnlyStorage.
/// Returns the handler's Prefetch result wrapped in the PrefetchCache union.
/// Returns null if the handler returned null (storage busy).
fn dispatch_prefetch(ro: anytype, msg: *const Message) ?PrefetchCache {
    return switch (msg.operation) {
        .root => unreachable,
        .get_product => prefetch_one(@import("handlers/get_product.zig"), .get_product, ro, msg),
        .create_product => prefetch_one(@import("handlers/create_product.zig"), .create_product, ro, msg),
        .list_products => prefetch_one(@import("handlers/list_products.zig"), .list_products, ro, msg),
        .update_product => prefetch_one(@import("handlers/update_product.zig"), .update_product, ro, msg),
        .delete_product => prefetch_one(@import("handlers/delete_product.zig"), .delete_product, ro, msg),
        .get_product_inventory => prefetch_one(@import("handlers/get_product_inventory.zig"), .get_product_inventory, ro, msg),
        .search_products => prefetch_one(@import("handlers/search_products.zig"), .search_products, ro, msg),
        .transfer_inventory => prefetch_one(@import("handlers/transfer_inventory.zig"), .transfer_inventory, ro, msg),
        .create_collection => prefetch_one(@import("handlers/create_collection.zig"), .create_collection, ro, msg),
        .get_collection => prefetch_one(@import("handlers/get_collection.zig"), .get_collection, ro, msg),
        .list_collections => prefetch_one(@import("handlers/list_collections.zig"), .list_collections, ro, msg),
        .delete_collection => prefetch_one(@import("handlers/delete_collection.zig"), .delete_collection, ro, msg),
        .add_collection_member => prefetch_one(@import("handlers/add_collection_member.zig"), .add_collection_member, ro, msg),
        .remove_collection_member => prefetch_one(@import("handlers/remove_collection_member.zig"), .remove_collection_member, ro, msg),
        .create_order => prefetch_one(@import("handlers/create_order.zig"), .create_order, ro, msg),
        .get_order => prefetch_one(@import("handlers/get_order.zig"), .get_order, ro, msg),
        .list_orders => prefetch_one(@import("handlers/list_orders.zig"), .list_orders, ro, msg),
        .complete_order => prefetch_one(@import("handlers/complete_order.zig"), .complete_order, ro, msg),
        .cancel_order => prefetch_one(@import("handlers/cancel_order.zig"), .cancel_order, ro, msg),
        .page_load_dashboard => prefetch_one(@import("handlers/page_load_dashboard.zig"), .page_load_dashboard, ro, msg),
        .page_load_login => prefetch_one(@import("handlers/page_load_login.zig"), .page_load_login, ro, msg),
        .request_login_code => prefetch_one(@import("handlers/request_login_code.zig"), .request_login_code, ro, msg),
        .verify_login_code => prefetch_one(@import("handlers/verify_login_code.zig"), .verify_login_code, ro, msg),
        .logout => prefetch_one(@import("handlers/logout.zig"), .logout, ro, msg),
    };
}

fn prefetch_one(comptime H: type, comptime op: Operation, ro: anytype, msg: *const Message) ?PrefetchCache {
    const result = H.prefetch(ro, msg) orelse return null;
    return @unionInit(PrefetchCache, @tagName(op), result);
}

/// Phase 2: dispatch to handler.handle(), apply writes.
/// The SM calls this from commit() with the stored PrefetchCache.
/// apply_write_fn is a bound method from the SM — handlers never
/// touch storage directly in the execute phase.
fn dispatch_execute(
    cache: PrefetchCache,
    msg: Message,
    fw: anytype,
) state_machine.ExecuteResult {
    return switch (msg.operation) {
        .root => unreachable,
        .get_product => execute_one(@import("handlers/get_product.zig"), .get_product, cache, msg, fw),
        .create_product => execute_one(@import("handlers/create_product.zig"), .create_product, cache, msg, fw),
        .list_products => execute_one(@import("handlers/list_products.zig"), .list_products, cache, msg, fw),
        .update_product => execute_one(@import("handlers/update_product.zig"), .update_product, cache, msg, fw),
        .delete_product => execute_one(@import("handlers/delete_product.zig"), .delete_product, cache, msg, fw),
        .get_product_inventory => execute_one(@import("handlers/get_product_inventory.zig"), .get_product_inventory, cache, msg, fw),
        .search_products => execute_one(@import("handlers/search_products.zig"), .search_products, cache, msg, fw),
        .transfer_inventory => execute_one(@import("handlers/transfer_inventory.zig"), .transfer_inventory, cache, msg, fw),
        .create_collection => execute_one(@import("handlers/create_collection.zig"), .create_collection, cache, msg, fw),
        .get_collection => execute_one(@import("handlers/get_collection.zig"), .get_collection, cache, msg, fw),
        .list_collections => execute_one(@import("handlers/list_collections.zig"), .list_collections, cache, msg, fw),
        .delete_collection => execute_one(@import("handlers/delete_collection.zig"), .delete_collection, cache, msg, fw),
        .add_collection_member => execute_one(@import("handlers/add_collection_member.zig"), .add_collection_member, cache, msg, fw),
        .remove_collection_member => execute_one(@import("handlers/remove_collection_member.zig"), .remove_collection_member, cache, msg, fw),
        .create_order => execute_one(@import("handlers/create_order.zig"), .create_order, cache, msg, fw),
        .get_order => execute_one(@import("handlers/get_order.zig"), .get_order, cache, msg, fw),
        .list_orders => execute_one(@import("handlers/list_orders.zig"), .list_orders, cache, msg, fw),
        .complete_order => execute_one(@import("handlers/complete_order.zig"), .complete_order, cache, msg, fw),
        .cancel_order => execute_one(@import("handlers/cancel_order.zig"), .cancel_order, cache, msg, fw),
        .page_load_dashboard => execute_one(@import("handlers/page_load_dashboard.zig"), .page_load_dashboard, cache, msg, fw),
        .page_load_login => execute_one(@import("handlers/page_load_login.zig"), .page_load_login, cache, msg, fw),
        .request_login_code => execute_one(@import("handlers/request_login_code.zig"), .request_login_code, cache, msg, fw),
        .verify_login_code => execute_one(@import("handlers/verify_login_code.zig"), .verify_login_code, cache, msg, fw),
        .logout => execute_one(@import("handlers/logout.zig"), .logout, cache, msg, fw),
    };
}

fn execute_one(
    comptime H: type,
    comptime op: Operation,
    cache: PrefetchCache,
    msg: Message,
    fw: anytype,
) state_machine.ExecuteResult {
    const prefetched = @field(cache, @tagName(op));
    const ctx = H.Context{
        .prefetched = prefetched,
        .body = if (H.Context.BodyType == void) {} else msg.body_as(H.Context.BodyType),
        .fw = fw,
        .render_buf = &.{}, // render not wired yet
    };

    return H.handle(ctx);
}

/// Extract the prefetch cache for the sidecar protocol.
/// TODO: Redesign for new handler-based SM. The SM now stores an opaque
/// PrefetchCache (tagged union of handler Prefetch types), not flat fields.
/// The sidecar protocol needs to be updated to work with the new shape.
/// For now, returns zeroes — the sidecar path falls back to native rendering.
pub fn extract_cache(comptime StorageParam: type, sm: *const StateMachineType(StorageParam)) protocol.PrefetchCache {
    _ = sm;
    return std.mem.zeroes(protocol.PrefetchCache);
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

/// Convert PipelineResponse to old MessageResponse for the legacy render.
/// Domain data is always .empty — the old render produces status-only
/// responses until handler render functions are wired.
/// Bridge PipelineResponse → MessageResponse for the legacy render pipeline.
/// Domain data is always .empty. TODO: delete when handler render is wired.
pub fn to_legacy_response(comptime StorageParam: type, pr: StateMachineType(StorageParam).PipelineResponse) MessageResponse {
    return .{
        .status = pr.status,
        .result = .{ .empty = {} },
        .session_action = switch (pr.session_action) {
            .none => .none,
            .set_authenticated => .set_authenticated,
            .clear => .clear,
        },
        .user_id = pr.user_id,
        .is_authenticated = pr.is_authenticated,
        .kind = if (pr.is_authenticated) .authenticated else .anonymous,
        .is_new_visitor = pr.is_new_visitor,
        .followup = pr.followup,
    };
}

pub fn commit_and_encode(
    comptime StorageParam: type,
    sm: *StateMachineType(StorageParam),
    msg: Message,
    send_buf: []u8,
    is_datastar_request: bool,
    secret_key: *const [auth.key_length]u8,
) CommitResult {
    const pipeline_resp = sm.commit(msg);
    // TODO: Replace with handler render functions. Currently uses legacy
    // render which gets .result = .empty (no domain data).
    const legacy_resp = to_legacy_response(StorageParam, pipeline_resp);

    if (sidecar) |*client| {
        const cache = extract_cache(StorageParam, sm);

        if (!client.execute_render(msg.operation, msg.id, &msg.body, &cache, is_datastar_request, &sidecar_resp_buf)) {
            log.mark.err("sidecar execute_render failed, rendering natively", .{});
            const r = render.encode_response(send_buf, msg.operation, legacy_resp, is_datastar_request, secret_key);
            return .{
                .status = pipeline_resp.status,
                .followup = pipeline_resp.followup,
                .response = r,
            };
        }

        const html_len = sidecar_resp_buf.html_len;
        assert(render.header_reserve + html_len <= send_buf.len);
        @memcpy(send_buf[render.header_reserve..][0..html_len], sidecar_resp_buf.html[0..html_len]);
        const cookie_hdr = render.format_cookie_header(legacy_resp, secret_key);
        const set_cookie: ?[]const u8 = if (cookie_hdr.len > 0) cookie_hdr.slice() else null;
        const r = render.backfill_headers(send_buf, html_len, set_cookie);

        return .{
            .status = pipeline_resp.status,
            .followup = pipeline_resp.followup,
            .response = r,
        };
    }

    const r = render.encode_response(send_buf, msg.operation, legacy_resp, is_datastar_request, secret_key);
    return .{
        .status = pipeline_resp.status,
        .followup = pipeline_resp.followup,
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

const TestSM = SM; // Tests use the same SM type as production

// extract_cache tests removed — the sidecar cache protocol needs redesign
// for the new handler-based SM. See TODO in extract_cache above.

test "apply_write returns false for duplicate put" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();
    const secret = "tiger-web-test-key-0123456789ab!".*;
    var sm = TestSM.init(&storage, false, 42, &secret);

    var p = std.mem.zeroes(message.Product);
    p.id = 0x1234;
    p.version = 1;
    p.flags = .{ .active = true };

    // First put succeeds.
    try std.testing.expect(sm.apply_write(.{ .put_product = p }));
    // Duplicate put — apply_write returns false (not crash).
    try std.testing.expect(!sm.apply_write(.{ .put_product = p }));
}
