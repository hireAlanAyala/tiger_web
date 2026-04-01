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
pub const SidecarClientType = @import("sidecar.zig").SidecarClientType;

const log = marks.wrap_log(std.log.scoped(.app));

// All 24 handler modules — used for PrefetchCache type construction
// and prefetch/handle/render dispatch. Routing uses the generated route
// table (generated/routes.generated.zig), not this tuple.
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
/// Generated handler dispatch — PrefetchCache, dispatch functions,
/// is_sidecar_operation. Scanner-generated from handler annotations.
/// Fields emitted in Operation enum declaration order (Zig union requirement).
const gen_handlers = @import("generated/handlers.generated.zig");
pub const PrefetchCache = gen_handlers.PrefetchCache;

/// Handlers interface — passed to StateMachineType so the SM can call
/// handler dispatch without importing App. The SM is parameterized on
/// this type. It calls prefetch/execute through it. App defines the
/// implementation. Clean one-way dependency: App → SM, never SM → App.
///
/// The runtime `if (sidecar)` checks in handler_prefetch/execute/render
/// are intentional. The sidecar decision is a framework orchestration
/// concern (CALL/RESULT protocol, async epoll, state management), not
/// a dispatch concern. The generated dispatch (handlers.generated.zig)
/// is pure: handler module → function call. Moving the sidecar logic
/// into generated code would couple the scanner to the protocol layer.
///
/// Fault injection configuration — module-level because single-threaded,
/// one message at a time. Set by sim/fuzz tests before running operations.
/// Production leaves these at defaults (no faults).
pub var fault_prng: ?*PRNG = null;
pub var fault_busy_ratio: PRNG.Ratio = PRNG.Ratio.zero();

// =====================================================================
// Handler type selection — two paths, intentionally.
//
// Native handlers (NativeHandlersType below) compile Zig handler code
// directly into the server binary. Zero overhead — function calls.
// 53K req/s.
//
// Sidecar handlers (SidecarHandlersType, Phase 2) implement the same
// interface but delegate to an external runtime via the message bus.
// Any language that speaks the sidecar protocol: TypeScript, Python,
// Rust, C, Go. With shared memory transport: ~34K req/s for native-
// compiled handlers (Rust/C/Go), ~25K for V8 (TypeScript).
//
// The two-path split is worth keeping. The complexity is contained
// entirely in the handler implementation files — the SM, server, and
// pipeline see ONE handler interface. The comptime selection is one
// line. Native handlers never pay sidecar overhead. Sidecar handlers
// get any-runtime flexibility.
//
// Future: dlopen for native-compiled handler plugins (Rust, C, Go)
// would reach near-native speed (~53K) without the sidecar protocol.
// That's additive — a third handler implementation behind the same
// interface.
// =====================================================================

pub fn HandlersType(comptime StorageParam: type) type {
    return struct {
        pub const Cache = PrefetchCache;

        /// Whether an async handler operation is in-flight.
        /// Native handlers are always synchronous — returns false.
        /// SidecarHandlersType overrides this to check call_state.
        pub fn is_handler_pending() bool {
            return false;
        }

        /// Native prefetch dispatch. In sidecar mode, the server uses
        /// SidecarHandlersType instead — same interface, different impl.
        pub fn handler_prefetch(storage: *StorageParam, msg: *const Message) ?PrefetchCache {
            // Fault injection for simulation.
            if (fault_prng) |prng| {
                if (prng.chance(fault_busy_ratio)) {
                    log.mark.debug("storage: busy fault injected", .{});
                    return null;
                }
            }
            const ro = StorageParam.ReadView.init(storage);
            return gen_handlers.dispatch_prefetch(ro, msg);
        }

        pub const FwCtx = @import("framework/handler.zig").FrameworkCtx(message.PrefetchIdentity);

        /// QUERY dispatch function for CALL/RESULT protocol.
        /// Wraps StorageParam.query_raw behind the QueryFn interface.
        /// Context is *StorageParam (not *ReadView) because ReadView is
        /// a value type received via anytype — can't take its address for
        /// *anyopaque. StorageParam is a persistent pointer on the SM.
        /// ReadView is created fresh inside — it's a thin wrapper, free.
        pub fn query_dispatch_fn(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const s: *StorageParam = @ptrCast(@alignCast(ctx));
            const ro = StorageParam.ReadView.init(s);
            return ro.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        /// Pure native execute dispatch. No sidecar knowledge.
        /// In sidecar mode, the server short-circuits before calling this.
        pub fn handler_execute(
            cache: PrefetchCache,
            msg: Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
            return gen_handlers.dispatch_execute(cache, msg, fw, db);
        }

        /// Pure native route dispatch. No sidecar knowledge.
        /// In sidecar mode, the server short-circuits before calling this.
        pub fn handler_route(method: http.Method, raw_path: []const u8, body: []const u8) ?Message {
            const parse = @import("framework/parse.zig");
            const gen = @import("generated/routes.generated.zig");

            const query_sep = std.mem.indexOfScalar(u8, raw_path, '?');
            const path = if (query_sep) |q| raw_path[0..q] else raw_path;
            const query_string = if (query_sep) |q| raw_path[q + 1 ..] else "";

            var result: ?Message = null;
            inline for (gen.routes) |route| {
                if (method == route.method) {
                    if (parse.match_route(path, route.pattern)) |path_params| {
                        var params = path_params;
                        inline for (route.query_params) |qname| {
                            if (parse.query_param(query_string, qname)) |qval| {
                                params.keys[params.len] = qname;
                                params.values[params.len] = qval;
                                params.len += 1;
                            }
                        }

                        if (route.handler.route(params, body)) |msg| {
                            assert(result == null);
                            result = msg;
                        }
                    }
                }
            }
            return result;
        }

        /// Pure native render dispatch. No sidecar knowledge.
        /// In sidecar mode, the server short-circuits before calling this.
        pub fn handler_render(
            cache: PrefetchCache,
            operation: Operation,
            status: message.Status,
            fw: FwCtx,
            render_buf: []u8,
            storage: anytype,
        ) []const u8 {
            return gen_handlers.dispatch_render(cache, operation, status, fw, render_buf, storage);
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

// Sidecar mode: Phase 2 will add comptime handler selection here.
// pub const Handlers = if (sidecar) SidecarHandlersType(Storage) else NativeHandlersType(Storage);
// For now, only native handlers are available.

/// Translate an HTTP request into a typed Message. Returns null if the
/// request doesn't map to a valid operation.
///
/// Route dispatch using the generated route table (single source of truth).
/// The scanner generates routes.generated.zig from // match and // query
/// annotations. Pattern matching + query param extraction happen here.
/// Handlers receive pre-extracted params and body — no raw path matching.
/// Runtime assert catches duplicate matches (two handlers both accepting).
pub fn translate(method: http.Method, raw_path: []const u8, body: []const u8) ?Message {
    return HandlersType(Storage).handler_route(method, raw_path, body);
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

// Render scratch buffer — module-level, single-threaded. Used by the
// full-page path to avoid aliasing between render output and send_buf.
pub var render_scratch_buf: [http.send_buf_max]u8 = undefined;


const http_response = @import("framework/http_response.zig");
const sse = @import("framework/sse.zig");

// commit_and_encode removed — inlined into server.commit_dispatch.
// The pipeline stages (handle, render, encode) are now driven by the
// server's stage-based state machine, not a single function call.

pub const CommitResult = struct {
    status: Status,
    response: http_response.Response,
};

/// Encode the HTTP response — shared by native and sidecar pipelines.
/// Formats cookie header, wraps HTML in SSE framing or full-page headers.
pub fn encode_response(
    status: Status,
    html: []const u8,
    send_buf: []u8,
    is_datastar_request: bool,
    session_action: message.SessionAction,
    user_id: u128,
    is_authenticated: bool,
    is_new_visitor: bool,
    secret_key: *const [auth.key_length]u8,
) CommitResult {
    const cookie_hdr = http_response.format_cookie_header(
        session_action,
        user_id,
        is_authenticated,
        is_new_visitor,
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

// Sidecar pipeline removed — sidecar now goes through the same
// HandlersType dispatch as native. See handler_prefetch, handler_execute,
// handler_render sidecar branches. One pipeline driven by
// server.commit_dispatch (stage-based state machine).

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
