//! App — the domain binding consumed by the framework.
//!
//! Provides types, functions, and constants that the framework's ServerType
//! calls at comptime. The framework never switches on Operation — it reads
//! response fields and calls these functions.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const state_machine = @import("state_machine.zig");
const http = @import("framework/http.zig");
const auth = @import("framework/auth.zig");
const marks = @import("framework/marks.zig");
const PRNG = @import("stdx").PRNG;
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
                if (prng.chance(fault_busy_ratio)) {
                    log.mark.debug("storage: busy fault injected", .{});
                    return null;
                }
            }
            const ro = StorageParam.ReadView.init(storage);
            return dispatch_prefetch(ro, msg);
        }

        pub const FwCtx = @import("framework/handler.zig").FrameworkCtx(message.PrefetchIdentity);

        pub fn handler_execute(
            cache: PrefetchCache,
            msg: Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
            return dispatch_execute(cache, msg, fw, db);
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

pub const Wal = @import("framework/wal.zig").WalType(Operation);

/// Optional sidecar client — when set, translate delegates to the
/// external process instead of the Zig-native handlers.
pub var sidecar: ?SidecarClient = null;

/// Translate an HTTP request into a typed Message. Returns null if the
/// request doesn't map to a valid operation.
///
/// Tries all handler route functions. Fast-skips via route_method/route_pattern
/// (comptime-asserted on every handler), then calls route() for the full match.
/// Runtime assert catches duplicate matches — pair assertion with the scanner's
/// duplicate route pattern check.
pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| return client.translate(method, path, body);

    const parse = @import("framework/parse.zig");

    var result: ?Message = null;
    inline for (handlers) |H| {
        comptime {
            assert(@hasDecl(H, "route_method"));
            assert(@hasDecl(H, "route_pattern"));
        }

        const skip = method != H.route_method or parse.match_route(path, H.route_pattern) == null;

        if (!skip) {
            if (H.route(method, path, body)) |msg| {
                assert(result == null); // duplicate route match
                result = msg;
            }
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
// The SM owns the cross-cutting concerns (auth, tracer).
// These functions own the handler dispatch logic.
// =====================================================================

// ReadOnlyStorage enforcement is now via Storage.ReadView — see decisions/storage-ownership.md.

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

/// Phase 2: dispatch to handler.handle() with write-only db access.
/// The SM calls this from commit() inside a begin/commit transaction.
fn dispatch_execute(
    cache: PrefetchCache,
    msg: Message,
    fw: anytype,
    db: anytype,
) state_machine.HandleResult {
    return switch (msg.operation) {
        .root => unreachable,
        .get_product => execute_one(@import("handlers/get_product.zig"), .get_product, cache, msg, fw, db),
        .create_product => execute_one(@import("handlers/create_product.zig"), .create_product, cache, msg, fw, db),
        .list_products => execute_one(@import("handlers/list_products.zig"), .list_products, cache, msg, fw, db),
        .update_product => execute_one(@import("handlers/update_product.zig"), .update_product, cache, msg, fw, db),
        .delete_product => execute_one(@import("handlers/delete_product.zig"), .delete_product, cache, msg, fw, db),
        .get_product_inventory => execute_one(@import("handlers/get_product_inventory.zig"), .get_product_inventory, cache, msg, fw, db),
        .search_products => execute_one(@import("handlers/search_products.zig"), .search_products, cache, msg, fw, db),
        .transfer_inventory => execute_one(@import("handlers/transfer_inventory.zig"), .transfer_inventory, cache, msg, fw, db),
        .create_collection => execute_one(@import("handlers/create_collection.zig"), .create_collection, cache, msg, fw, db),
        .get_collection => execute_one(@import("handlers/get_collection.zig"), .get_collection, cache, msg, fw, db),
        .list_collections => execute_one(@import("handlers/list_collections.zig"), .list_collections, cache, msg, fw, db),
        .delete_collection => execute_one(@import("handlers/delete_collection.zig"), .delete_collection, cache, msg, fw, db),
        .add_collection_member => execute_one(@import("handlers/add_collection_member.zig"), .add_collection_member, cache, msg, fw, db),
        .remove_collection_member => execute_one(@import("handlers/remove_collection_member.zig"), .remove_collection_member, cache, msg, fw, db),
        .create_order => execute_one(@import("handlers/create_order.zig"), .create_order, cache, msg, fw, db),
        .get_order => execute_one(@import("handlers/get_order.zig"), .get_order, cache, msg, fw, db),
        .list_orders => execute_one(@import("handlers/list_orders.zig"), .list_orders, cache, msg, fw, db),
        .complete_order => execute_one(@import("handlers/complete_order.zig"), .complete_order, cache, msg, fw, db),
        .cancel_order => execute_one(@import("handlers/cancel_order.zig"), .cancel_order, cache, msg, fw, db),
        .page_load_dashboard => execute_one(@import("handlers/page_load_dashboard.zig"), .page_load_dashboard, cache, msg, fw, db),
        .page_load_login => execute_one(@import("handlers/page_load_login.zig"), .page_load_login, cache, msg, fw, db),
        .request_login_code => execute_one(@import("handlers/request_login_code.zig"), .request_login_code, cache, msg, fw, db),
        .verify_login_code => execute_one(@import("handlers/verify_login_code.zig"), .verify_login_code, cache, msg, fw, db),
        .logout => execute_one(@import("handlers/logout.zig"), .logout, cache, msg, fw, db),
    };
}

fn execute_one(
    comptime H: type,
    comptime op: Operation,
    cache: PrefetchCache,
    msg: Message,
    fw: anytype,
    db: anytype,
) state_machine.HandleResult {
    const prefetched = @field(cache, @tagName(op));
    const ctx = H.Context{
        .prefetched = prefetched,
        .body = if (H.Context.BodyType == void) {} else msg.body_as(H.Context.BodyType),
        .fw = fw,
        .render_buf = &.{}, // render not wired yet
    };

    return H.handle(ctx, db);
}

/// Phase 3: dispatch to handler.render().
/// Called after commit with the cache and pipeline response.
/// Returns the HTML slice (into render_buf) that the framework will wrap.
fn dispatch_render(
    cache: PrefetchCache,
    operation: Operation,
    status: message.Status,
    fw: anytype,
    render_buf: []u8,
    storage: anytype,
) []const u8 {
    return switch (operation) {
        .root => unreachable,
        .get_product => render_one(@import("handlers/get_product.zig"), .get_product, cache, status, fw, render_buf, storage),
        .create_product => render_one(@import("handlers/create_product.zig"), .create_product, cache, status, fw, render_buf, storage),
        .list_products => render_one(@import("handlers/list_products.zig"), .list_products, cache, status, fw, render_buf, storage),
        .update_product => render_one(@import("handlers/update_product.zig"), .update_product, cache, status, fw, render_buf, storage),
        .delete_product => render_one(@import("handlers/delete_product.zig"), .delete_product, cache, status, fw, render_buf, storage),
        .get_product_inventory => render_one(@import("handlers/get_product_inventory.zig"), .get_product_inventory, cache, status, fw, render_buf, storage),
        .search_products => render_one(@import("handlers/search_products.zig"), .search_products, cache, status, fw, render_buf, storage),
        .transfer_inventory => render_one(@import("handlers/transfer_inventory.zig"), .transfer_inventory, cache, status, fw, render_buf, storage),
        .create_collection => render_one(@import("handlers/create_collection.zig"), .create_collection, cache, status, fw, render_buf, storage),
        .get_collection => render_one(@import("handlers/get_collection.zig"), .get_collection, cache, status, fw, render_buf, storage),
        .list_collections => render_one(@import("handlers/list_collections.zig"), .list_collections, cache, status, fw, render_buf, storage),
        .delete_collection => render_one(@import("handlers/delete_collection.zig"), .delete_collection, cache, status, fw, render_buf, storage),
        .add_collection_member => render_one(@import("handlers/add_collection_member.zig"), .add_collection_member, cache, status, fw, render_buf, storage),
        .remove_collection_member => render_one(@import("handlers/remove_collection_member.zig"), .remove_collection_member, cache, status, fw, render_buf, storage),
        .create_order => render_one(@import("handlers/create_order.zig"), .create_order, cache, status, fw, render_buf, storage),
        .get_order => render_one(@import("handlers/get_order.zig"), .get_order, cache, status, fw, render_buf, storage),
        .list_orders => render_one(@import("handlers/list_orders.zig"), .list_orders, cache, status, fw, render_buf, storage),
        .complete_order => render_one(@import("handlers/complete_order.zig"), .complete_order, cache, status, fw, render_buf, storage),
        .cancel_order => render_one(@import("handlers/cancel_order.zig"), .cancel_order, cache, status, fw, render_buf, storage),
        .page_load_dashboard => render_one(@import("handlers/page_load_dashboard.zig"), .page_load_dashboard, cache, status, fw, render_buf, storage),
        .page_load_login => render_one(@import("handlers/page_load_login.zig"), .page_load_login, cache, status, fw, render_buf, storage),
        .request_login_code => render_one(@import("handlers/request_login_code.zig"), .request_login_code, cache, status, fw, render_buf, storage),
        .verify_login_code => render_one(@import("handlers/verify_login_code.zig"), .verify_login_code, cache, status, fw, render_buf, storage),
        .logout => render_one(@import("handlers/logout.zig"), .logout, cache, status, fw, render_buf, storage),
    };
}

/// Map shared message.Status to a per-handler Status enum by name.
/// If the handler's Status is message.Status (shared), this is a no-op.
/// If it's a per-handler enum, the mapping is resolved at comptime.
/// Asserts if the shared status has no matching variant in the handler's enum —
/// that means handle() returned a status it didn't declare.
fn map_status(comptime HandlerStatus: type, status: message.Status) HandlerStatus {
    if (HandlerStatus == message.Status) return status;
    // Per-handler enum: map by name at comptime.
    const status_name = @tagName(status);
    inline for (@typeInfo(HandlerStatus).@"enum".fields) |f| {
        if (std.mem.eql(u8, f.name, status_name)) {
            return @enumFromInt(f.value);
        }
    }
    // Handle returned a status the handler didn't declare.
    unreachable;
}

fn render_one(
    comptime H: type,
    comptime op: Operation,
    cache: PrefetchCache,
    status: message.Status,
    fw: anytype,
    render_buf: []u8,
    storage: anytype,
) []const u8 {
    const prefetched = @field(cache, @tagName(op));
    const HandlerStatus = H.Context.StatusType;
    const ctx = H.Context{
        .prefetched = prefetched,
        .body = if (H.Context.BodyType == void) {} else undefined,
        .fw = fw,
        .render_buf = render_buf,
        .status = map_status(HandlerStatus, status),
    };

    // Render gets read-only db access for post-mutation queries.
    // Most handlers use render(ctx) — only handlers with side-effect data
    // (e.g. complete_order needing post-commit inventory) use render(ctx, db).
    // See decisions/render-db-access.md for the full reasoning.
    const render_fn_info = @typeInfo(@TypeOf(H.render)).@"fn";
    if (render_fn_info.params.len >= 2) {
        return H.render(ctx, storage);
    } else {
        return H.render(ctx);
    }
}

// Render scratch buffer — module-level, single-threaded. Used by the
// full-page path to avoid aliasing between render output and send_buf.
var render_scratch_buf: [http.send_buf_max]u8 = undefined;


const http_response = @import("framework/http_response.zig");
const sse = @import("framework/sse.zig");

pub fn commit_and_encode(
    comptime StorageParam: type,
    sm: *StateMachineType(StorageParam),
    msg: Message,
    send_buf: []u8,
    is_datastar_request: bool,
    secret_key: *const [auth.key_length]u8,
) CommitResult {
    const commit_output = sm.commit(msg);
    const pipeline_resp = commit_output.response;
    const cache = commit_output.cache;

    // Format cookie header from pipeline response.
    const cookie_hdr = http_response.format_cookie_header(
        pipeline_resp.session_action,
        pipeline_resp.user_id,
        pipeline_resp.is_authenticated,
        pipeline_resp.is_new_visitor,
        secret_key,
    );
    const set_cookie: ?[]const u8 = if (cookie_hdr.len > 0) cookie_hdr.slice() else null;

    // Build framework context for render.
    const FwCtx = HandlersType(StorageParam).FwCtx;
    const fw = FwCtx{
        .identity = commit_output.identity,
        .now = sm.now,
        .is_sse = is_datastar_request,
    };

    // Render: handler produces HTML, framework wraps it.
    if (is_datastar_request) {
        // SSE: headers + events written sequentially from offset 0.
        // Render into scratch buffer to avoid aliasing — the SSE encoder
        // prepends event framing before the content in send_buf, so rendering
        // directly into send_buf would overlap with the encode destination.
        var pos: usize = 0;
        pos += sse.encode_headers(send_buf[pos..], set_cookie);

        const ro = StorageParam.ReadView.init(sm.storage);
        const html = dispatch_render(cache, msg.operation, pipeline_resp.status, fw, &render_scratch_buf, ro);

        if (html.len > 0) {
            pos += sse.encode_render_result(send_buf[pos..], html);
        }

        return .{
            .status = pipeline_resp.status,
            .response = .{ .offset = 0, .len = @intCast(pos), .keep_alive = false },
        };
    } else {
        // Full page: render into scratch, copy to body position, backfill headers.
        // Scratch buffer avoids aliasing — render may return a string literal
        // (rodata) or a slice of the scratch buffer. Either way, one memcpy
        // into send_buf is correct and non-overlapping.
        const ro = StorageParam.ReadView.init(sm.storage);
        const html = dispatch_render(cache, msg.operation, pipeline_resp.status, fw, &render_scratch_buf, ro);

        if (html.len > 0) {
            @memcpy(send_buf[http_response.header_reserve..][0..html.len], html);
        }

        return .{
            .status = pipeline_resp.status,
            .response = http_response.backfill_headers(send_buf, html.len, set_cookie),
        };
    }
}

pub const CommitResult = struct {
    status: Status,
    response: http_response.Response,
};

// =====================================================================
// Sidecar pipeline — separate orchestration, shared building blocks
//
// The sidecar has its own pipeline because its execution model (3 wire
// round trips) doesn't match the SM's phased dispatch (prefetch →
// execute → render as separate local calls with typed PrefetchCache).
//
// Alternatives considered:
//   A. Sidecar as Handlers backend (single pipeline) — rejected.
//      Impedance mismatch: RT2 spans prefetch→execute. Requires dummy
//      cache, stored state between SM calls, buffer aliasing.
//   B. Sidecar bypass in commit_and_encode — rejected.
//      Makes commit_and_encode two implementations.
//   C. Generalize Cache to opaque bytes — rejected.
//      PrefetchCache is union(Operation). The real problem is RT2
//      spanning two SM phases, not the cache type.
//
// TigerBeetle has this pattern: real IO and simulated IO share building
// blocks but have different orchestration. Same here.
//
// Both pipelines call the same building blocks: storage.begin/commit,
// auth.resolve_credential, http_response encoding. The building blocks
// are shared. The composition is per-path. Correctness proven by
// cross-pipeline test (sidecar_test.zig).
// =====================================================================

/// Process an HTTP request through the sidecar pipeline.
/// Called by the server when sidecar is active, instead of
/// sm.prefetch() + commit_and_encode().
///
/// The server's begin_batch/commit_batch wraps the entire tick,
/// so writes from execute_writes run inside the existing transaction.
pub fn sidecar_commit_and_encode(
    comptime StorageParam: type,
    sm: *StateMachineType(StorageParam),
    msg: Message,
    send_buf: []u8,
    is_datastar_request: bool,
    secret_key: *const [auth.key_length]u8,
) ?CommitResult {
    const client = &sidecar.?;

    // Auth: resolve credential → identity. Same building block as SM.prefetch().
    sm.resolve_credential(msg);

    // Phase 1: execute prefetch SQL declared by sidecar in RT1.
    const ro = StorageParam.ReadView.init(sm.storage);
    const prefetch_len = client.execute_prefetch(ro) orelse return null;

    // Phase 2: RT2 — send prefetch results, receive handle result.
    const status = client.send_prefetch_recv_handle(prefetch_len) orelse return null;

    // Phase 3: execute writes inside the server's transaction.
    // The server's begin_batch/commit_batch wraps the entire tick.
    if (!client.execute_writes(sm.storage)) return null;

    // Phase 4: RT3 — execute render SQL, receive HTML.
    // Writes are visible via read-your-writes within the server's open
    // transaction. The actual commit (commit_batch) runs after process_inbox
    // returns. Render sees the correct data — not "post-commit" in the
    // SQLite sense, but the writes have been applied.
    const ro_post = StorageParam.ReadView.init(sm.storage);
    const html = client.execute_render(ro_post) orelse return null;

    // Phase 5: encode HTTP response — same as native path.
    const identity = sm.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity);
    defer sm.prefetch_identity = null;

    const is_auth = identity.is_authenticated != 0;
    const cookie_hdr = http_response.format_cookie_header(
        message.SessionAction.none, // session_action deferred — session-as-writes replaces this
        identity.user_id,
        is_auth,
        identity.is_new != 0,
        secret_key,
    );
    const set_cookie: ?[]const u8 = if (cookie_hdr.len > 0) cookie_hdr.slice() else null;

    if (is_datastar_request) {
        var pos: usize = 0;
        pos += sse.encode_headers(send_buf[pos..], set_cookie);
        if (html.len > 0) {
            pos += sse.encode_render_result(send_buf[pos..], html);
        }
        return .{
            .status = status,
            .response = .{ .offset = 0, .len = @intCast(pos), .keep_alive = false },
        };
    } else {
        if (html.len > 0) {
            @memcpy(send_buf[http_response.header_reserve..][0..html.len], html);
        }
        return .{
            .status = status,
            .response = http_response.backfill_headers(send_buf, html.len, set_cookie),
        };
    }
}

// =====================================================================
// Tests
// =====================================================================

const TestSM = SM; // Tests use the same SM type as production

// extract_cache tests removed — the sidecar cache protocol needs redesign
// extract_cache tests removed — sidecar has its own pipeline, no shared cache.

test "duplicate insert returns false" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    // First insert succeeds.
    try std.testing.expect(storage.execute(
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
        .{ @as(u128, 0x1234), "test", "", @as(u32, 100), @as(u32, 10), @as(u32, 1), true },
    ));
    // Duplicate insert fails (UNIQUE constraint).
    try std.testing.expect(!storage.execute(
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
        .{ @as(u128, 0x1234), "test", "", @as(u32, 100), @as(u32, 10), @as(u32, 1), true },
    ));
}
