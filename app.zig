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

        /// Check if the sidecar client has an in-flight CALL.
        /// Used by sm.prefetch to distinguish busy (retry) from
        /// pending (sidecar processing, process_sidecar will drive).
        pub fn is_sidecar_pending() bool {
            if (sidecar) |*client| {
                return client.call_state == .receiving;
            }
            return false;
        }

        /// Called by the SM's prefetch(). Dispatches to native handler or
        /// sidecar client. Fault injection for native path.
        pub fn handler_prefetch(storage: *StorageParam, msg: *const Message) ?PrefetchCache {
            if (sidecar) |*client| {
                // Idempotent: safe to call from both start and resume.
                // commit_dispatch may re-enter .prefetch after .pending.
                switch (client.call_state) {
                    .complete => {
                        // Resume: sidecar exchange done. Build cache from result.
                        defer client.reset_call_state();
                        if (client.result_flag == .failure) return null;
                    },
                    .idle => {
                        // First call: start the exchange.
                        var args: [1 + 16]u8 = undefined;
                        args[0] = @intFromEnum(msg.operation);
                        std.mem.writeInt(u128, args[1..17], msg.id, .big);

                        if (!client.call_submit("prefetch", &args)) return null;
                        if (!client.run_to_completion(query_dispatch_fn, @ptrCast(storage), protocol.queries_max)) return null;
                        defer client.reset_call_state();

                        if (client.result_flag == .failure) return null;
                    },
                    .receiving => {
                        // Still waiting for RESULT — process_sidecar hasn't
                        // completed the exchange yet. Return null → .pending.
                        return null;
                    },
                    .failed => {
                        client.reset_call_state();
                        return null;
                    },
                }

                // Sidecar holds prefetch results internally.
                // Return zeroed cache. Enforced by convention, not assertion.
                // TODO: scanner-generated Handlers uses void Cache.
                return switch (msg.operation) {
                    .root => unreachable,
                    inline else => |op| @unionInit(PrefetchCache, @tagName(op), std.mem.zeroes(
                        @FieldType(PrefetchCache, @tagName(op)),
                    )),
                };
            }

            // Native: fault injection + dispatch.
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

        /// QUERY dispatch function for CALL/RESULT protocol.
        /// Wraps StorageParam.query_raw behind the QueryFn interface.
        /// Context is *StorageParam (not *ReadView) because ReadView is
        /// a value type received via anytype — can't take its address for
        /// *anyopaque. StorageParam is a persistent pointer on the SM.
        /// ReadView is created fresh inside — it's a thin wrapper, free.
        fn query_dispatch_fn(ctx: *anyopaque, sql: []const u8, params_buf: []const u8, param_count: u8, mode: protocol.QueryMode, out_buf: []u8) ?[]const u8 {
            const s: *StorageParam = @ptrCast(@alignCast(ctx));
            const ro = StorageParam.ReadView.init(s);
            return ro.query_raw(sql, params_buf, param_count, mode, out_buf);
        }

        pub fn handler_execute(
            cache: PrefetchCache,
            msg: Message,
            fw: FwCtx,
            db: anytype,
        ) state_machine.HandleResult {
            if (sidecar) |*client| {
                // Sidecar: cache is a zeroed placeholder — data lives on
                // the sidecar client. This code path never reads from cache.
                // Enforced by convention, not assertion (union tag + padding
                // make byte-level zeroed checks infeasible).
                // TODO: scanner-generated Handlers uses void Cache for
                // sidecar operations — comptime enforcement.

                // Build handle args: [operation: u8][id: u128 BE]
                // Body and prefetch data are already held by the sidecar
                // from the route and prefetch CALLs.
                var args: [1 + 16]u8 = undefined;
                args[0] = @intFromEnum(msg.operation);
                std.mem.writeInt(u128, args[1..17], msg.id, .big);

                client.reset_call_state();
                if (!client.call_submit("handle", &args)) return .{ .status = .storage_error };
                if (!client.run_to_completion(null, null, 0)) return .{ .status = .storage_error };
                defer client.reset_call_state();

                if (client.result_flag == .failure) return .{ .status = .storage_error };
                const data = client.result_data;

                // Parse result: [status_len: u16 BE][status_str][write_count: u8][writes...]
                if (data.len < 3) return .{ .status = .storage_error };
                const status_len = std.mem.readInt(u16, data[0..2], .big);
                if (2 + status_len + 1 > data.len) return .{ .status = .storage_error };
                const status_str = data[2..][0..status_len];
                const write_count = data[2 + status_len];
                const write_data = data[2 + status_len + 1 ..];

                // Execute writes through WriteView for WAL recording.
                // Reuse SidecarClient.execute_writes — same binary format
                // as the 3-RT protocol. No duplicate parsing.
                client.handle_writes = write_data;
                client.handle_write_count = write_count;
                if (!client.execute_writes(db)) {
                    client.handle_writes = "";
                    client.handle_write_count = 0;
                    return .{ .status = .storage_error };
                }
                // Clear after use — handle_writes aliases recv_buf which
                // is overwritten by the next CALL exchange (render).
                client.handle_writes = "";
                client.handle_write_count = 0;

                // Map status string to Status enum.
                const status = message.Status.from_string(status_str) orelse .storage_error;
                return .{ .status = status };
            }

            return dispatch_execute(cache, msg, fw, db);
        }

        /// Route an HTTP request to a typed Message. Returns null if
        /// the request doesn't map to a valid operation or the handler
        /// rejects it. Sidecar operations delegate to the sidecar client.
        pub fn handler_route(method: http.Method, raw_path: []const u8, body: []const u8) ?Message {
            if (sidecar) |*client| {
                // Build route args: [method: u8][path_len: u16 BE][path][body_len: u16 BE][body]
                var args: [1 + 2 + 0xFFFF + 2 + 0xFFFF]u8 = undefined;
                var pos: usize = 0;
                args[pos] = @intFromEnum(method);
                pos += 1;
                if (raw_path.len > 0xFFFF) return null;
                std.mem.writeInt(u16, args[pos..][0..2], @intCast(raw_path.len), .big);
                pos += 2;
                @memcpy(args[pos..][0..raw_path.len], raw_path);
                pos += raw_path.len;
                if (body.len > 0xFFFF) return null;
                std.mem.writeInt(u16, args[pos..][0..2], @intCast(body.len), .big);
                pos += 2;
                @memcpy(args[pos..][0..body.len], body);
                pos += body.len;

                client.reset_call_state();
                if (!client.call_submit("route", args[0..pos])) return null;
                if (!client.run_to_completion(null, null, 0)) return null;
                defer client.reset_call_state();

                if (client.result_flag == .failure) return null;
                const data = client.result_data;

                // Parse result: [found: u8][operation: u8][id: u128 BE]
                if (data.len < 1) return null;
                if (data[0] == 0) return null; // not found
                if (data.len < 18) return null; // found(1) + operation(1) + id(16)
                const operation = std.meta.intToEnum(message.Operation, data[1]) catch return null;
                const id = std.mem.readInt(u128, data[2..18], .big);

                var msg = std.mem.zeroes(message.Message);
                msg.operation = operation;
                msg.id = id;
                return msg;
            }

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

        pub fn handler_render(
            cache: PrefetchCache,
            operation: Operation,
            status: message.Status,
            fw: FwCtx,
            render_buf: []u8,
            storage: anytype,
        ) []const u8 {
            if (sidecar) |*client| {
                // Build render args: [operation: u8][status: u8]
                const args = [_]u8{ @intFromEnum(operation), @intFromEnum(status) };

                client.reset_call_state();
                if (!client.call_submit("render", &args)) return "";
                if (!client.run_to_completion(query_dispatch_fn, @ptrCast(storage.storage), protocol.queries_max)) return "";
                defer client.reset_call_state();

                if (client.result_flag == .failure) return "";
                return client.copy_state(client.result_data);
            }

            return dispatch_render(cache, operation, status, fw, render_buf, storage);
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
// handler_render sidecar branches. One pipeline: sm.prefetch() +
// commit_and_encode().

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
