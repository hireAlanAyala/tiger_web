const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("tiger_framework").stdx;
const message = @import("message.zig");
const auth = @import("tiger_framework").auth;
const TracerType = @import("tiger_framework").tracer.TracerType;
const Tracer = TracerType(message.Operation, message.Status);
const marks = @import("tiger_framework").marks;
const log = marks.wrap_log(std.log.scoped(.state_machine));
const PRNG = @import("tiger_framework").prng;

/// Storage result — the availability contract between framework and database.
///
/// This is NOT a domain result. It answers "did the storage cooperate?" not
/// "was the business logic correct?" Domain outcomes (insufficient inventory,
/// duplicate email, invalid state transition) are expressed in handler return
/// values, not storage results.
///
/// Both SqliteStorage and MemoryStorage return these. MemoryStorage uses
/// PRNG-driven fault injection to exercise every branch in the framework
/// that handles non-ok results.
pub const StorageResult = enum { ok, not_found, err, busy, corruption };

/// State machine parameterized on a Storage backend.
/// In production, Storage is SqliteStorage. In simulation, Storage is MemoryStorage.
///
/// Request processing is split into two phases (TigerBeetle style):
/// - `prefetch(msg)` reads from storage into cache slots. Read-only — never mutates
///   storage. Returns false if storage is busy (retry next tick).
/// - `execute(msg)` decides from cache slots, then writes mutations to storage.
/// State machine parameterized on Storage and Handlers.
///
/// Storage is the database backend (SqliteStorage or MemoryStorage).
/// Handlers is the App's dispatch interface — it provides:
///   - Cache: tagged union of all handler Prefetch types
///   - handler_prefetch(storage, msg) → ?Cache
///   - handler_execute(cache, msg, identity, apply_write_fn) → MessageResponse
///
/// The SM owns the pipeline (auth, transactions, tracer, invariants).
/// Handlers own the business logic. The SM never imports App — Handlers
/// is passed as a comptime parameter. Clean one-way dependency.
/// Write command — describes a storage mutation returned by execute handlers.
/// Independent of Storage and Handlers — lives at module level so both
/// the SM and the App can reference it without circular dependencies.
pub const Write = union(enum) {
    put_product: message.Product,
    update_product: message.Product,
    put_collection: message.ProductCollection,
    update_collection: message.ProductCollection,
    put_membership: message.Membership,
    update_membership: message.MembershipUpdate,
    put_order: message.OrderResult,
    update_order: message.OrderResult,
    put_login_code: message.LoginCodeWrite,
    consume_login_code: message.LoginCodeKey,
    put_user: message.UserWrite,
};

/// Maximum writes a single execute can produce.
pub const writes_max = 1 + message.order_items_max;

comptime {
    assert(writes_max == 21);
}

/// Result of a handler's execute phase: handler decision + collected writes.
///
/// HandlerResponse is what the handler returns — just status and session
/// action. The handler never touches auth fields (user_id, is_authenticated).
/// The SM adds those from the resolved credential after the handler returns.
pub const ExecuteResult = struct {
    response: message.HandlerResponse,
    writes: [writes_max]Write,
    writes_len: u8,

    /// Read-only operation — no writes.
    pub fn read_only(response: message.HandlerResponse) ExecuteResult {
        return .{
            .response = response,
            .writes = undefined,
            .writes_len = 0,
        };
    }

    /// Single-write operation.
    pub fn single(response: message.HandlerResponse, write: Write) ExecuteResult {
        var result = ExecuteResult{
            .response = response,
            .writes = undefined,
            .writes_len = 1,
        };
        result.writes[0] = write;
        return result;
    }
};

/// Used by the fuzzer to filter random messages before calling prefetch/commit.
pub fn input_valid(msg: message.Message) bool {
    switch (msg.operation) {
        .root => return false,
        .create_product => {
            const p = msg.body_as(message.Product);
            if (p.id == 0) return false;
            if (p.name_len == 0 or p.name_len > message.product_name_max) return false;
            if (p.description_len > message.product_description_max) return false;
            if (p.flags.padding != 0) return false;
            if (!std.unicode.utf8ValidateSlice(p.name[0..p.name_len])) return false;
            if (!std.unicode.utf8ValidateSlice(p.description[0..p.description_len])) return false;
        },
        .update_product => {
            if (msg.id == 0) return false;
            const p = msg.body_as(message.Product);
            if (p.name_len == 0 or p.name_len > message.product_name_max) return false;
            if (p.description_len > message.product_description_max) return false;
            if (p.flags.padding != 0) return false;
            if (!std.unicode.utf8ValidateSlice(p.name[0..p.name_len])) return false;
            if (!std.unicode.utf8ValidateSlice(p.description[0..p.description_len])) return false;
        },
        .create_collection => {
            const col = msg.body_as(message.ProductCollection);
            if (col.id == 0) return false;
            if (col.name_len == 0 or col.name_len > message.collection_name_max) return false;
            if (col.flags.padding != 0) return false;
            if (!stdx.zeroed(&col.reserved)) return false;
            if (!std.unicode.utf8ValidateSlice(col.name[0..col.name_len])) return false;
        },
        .transfer_inventory => {
            const transfer = msg.body_as(message.InventoryTransfer);
            if (msg.id == 0) return false;
            if (transfer.target_id == 0) return false;
            if (msg.id == transfer.target_id) return false;
        },
        .create_order => {
            const order = msg.body_as(message.OrderRequest);
            if (order.id == 0) return false;
            if (order.items_len == 0) return false;
            if (order.items_len > message.order_items_max) return false;
            for (order.items_slice()) |item| {
                if (item.product_id == 0) return false;
                if (item.quantity == 0) return false;
            }
        },
        .complete_order => {
            const comp = msg.body_as(message.OrderCompletion);
            if (msg.id == 0) return false;
            _ = std.meta.intToEnum(message.OrderCompletion.OrderCompletionResult, @intFromEnum(comp.result)) catch return false;
            if (comp.payment_ref_len > message.payment_ref_max) return false;
        },
        .cancel_order => {
            if (msg.id == 0) return false;
        },
        .search_products => {
            const sq = msg.body_as(message.SearchQuery);
            if (sq.query_len == 0 or sq.query_len > message.search_query_max) return false;
            if (!std.unicode.utf8ValidateSlice(sq.query[0..sq.query_len])) return false;
            for (sq.query[0..sq.query_len]) |b| {
                if (b == 0) return false;
            }
        },
        .get_product,
        .get_product_inventory,
        .delete_product,
        .get_collection,
        .delete_collection,
        .get_order,
        .page_load_dashboard,
        .page_load_login,
        .logout,
        => {},
        .add_collection_member,
        .remove_collection_member,
        => {},
        .request_login_code => {
            const ev = msg.body_as(message.LoginCodeRequest);
            if (ev.email_len == 0 or ev.email_len > message.email_max) return false;
            if (!std.unicode.utf8ValidateSlice(ev.email[0..ev.email_len])) return false;
        },
        .verify_login_code => {
            const ev = msg.body_as(message.LoginVerification);
            if (ev.email_len == 0 or ev.email_len > message.email_max) return false;
            if (!std.unicode.utf8ValidateSlice(ev.email[0..ev.email_len])) return false;
            for (ev.code[0..message.code_length]) |c| {
                if (c < '0' or c > '9') return false;
            }
        },
        .list_products,
        .list_collections,
        .list_orders,
        => {
            const lp = msg.body_as(message.ListParams);
            if (lp.name_prefix_len > message.product_name_max) return false;
            const prefix = lp.name_prefix[0..lp.name_prefix_len];
            // NUL bytes in the prefix would be treated as string
            // terminators by SQLite, silently matching everything.
            for (prefix) |b| {
                if (b == 0) return false;
            }
            if (!std.unicode.utf8ValidateSlice(prefix)) return false;
        },
    }
    return true;
}

pub fn StateMachineType(comptime Storage: type, comptime Handlers: type) type {
    // Storage must define its own read/write split.
    @import("tiger_framework").read_only_storage.assertReadView(Storage);

    return struct {
        const StateMachine = @This();

        storage: *Storage,
        tracer: Tracer,
        prng: PRNG,
        secret_key: *const [auth.key_length]u8,

        /// Wall-clock time (seconds since epoch). Set by the server before
        /// each process_inbox call. Used for order timeout_at.
        now: i64,

        /// Prefetch cache — opaque to the SM. Populated by Handlers.handler_prefetch()
        /// in prefetch(), consumed by Handlers.handler_execute() in commit().
        /// The SM stores it between phases but never inspects it.
        prefetch_cache: ?Handlers.Cache,

        /// Auth identity resolved from the request cookie. Cross-cutting
        /// concern owned by the SM, not the handlers.
        prefetch_identity: ?message.PrefetchIdentity,

        pub fn init(storage: *Storage, log_trace: bool, prng_seed: u64, secret_key: *const [auth.key_length]u8) StateMachine {
            return .{
                .storage = storage,
                .tracer = Tracer.init(log_trace),
                .prng = PRNG.from_seed(prng_seed),
                .secret_key = secret_key,
                .now = 0,
                .prefetch_cache = null,
                .prefetch_identity = null,
            };
        }

        /// Returns whether the message is valid input for the state machine.

        /// Phase 1: prefetch — dispatch to handler via Handlers interface.
        /// Returns true if prefetch completed. Returns false if storage
        /// is busy (handler returned null) — connection retries next tick.
        pub fn prefetch(self: *StateMachine, msg: message.Message) bool {
            assert(self.prefetch_cache == null);

            // Auth: resolve cookie credential → identity.
            self.resolve_credential(msg);

            self.prefetch_cache = Handlers.handler_prefetch(self.storage, &msg);
            return self.prefetch_cache != null;
        }

        /// Set wall-clock time for this batch. Called by the server before
        /// process_inbox so all operations in the tick see the same timestamp.
        pub fn set_time(self: *StateMachine, now: i64) void {
            assert(now > 0);
            self.now = now;
        }

        /// Transaction boundary for tick-level batching. The server wraps
        /// the entire process_inbox loop in begin_batch/commit_batch so all
        /// writes in a tick share one SQLite transaction (one fsync).
        pub fn begin_batch(self: *StateMachine) void {
            self.storage.begin();
        }

        pub fn commit_batch(self: *StateMachine) void {
            self.storage.commit();
        }

        /// Phase 2: commit — dispatch to handler.handle() via Handlers interface.
        /// Cross-cutting concerns (auth, followup, tracer) handled here so
        /// handlers don't have to. Must only be called after prefetch() returned true.
        ///
        /// Pipeline response — the framework envelope. Handler decision + auth.
        /// No domain data — that flows through handler Prefetch → render.
        pub const PipelineResponse = struct {
            status: message.Status,
            session_action: message.SessionAction,
            user_id: u128,
            is_authenticated: bool,
            is_new_visitor: bool,
            followup: ?message.FollowupState,
        };

        /// Phase 2: commit — returns PipelineResponse (framework envelope).
        /// The handler's domain data is NOT here — it stays in Prefetch → render.
        pub fn commit(self: *StateMachine, msg: message.Message) PipelineResponse {
            const cache = self.prefetch_cache.?;
            defer self.prefetch_cache = null;
            defer self.prefetch_identity = null;

            const fw = Handlers.FwCtx{
                .identity = self.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity),
                .now = self.now,
                .is_sse = false, // Set by server when render is wired.
            };

            const exec_result = Handlers.handler_execute(
                cache,
                msg,
                fw,
            );

            // Apply writes — handlers return writes, the SM applies them.
            for (exec_result.writes[0..exec_result.writes_len]) |w| {
                assert(self.apply_write(w));
            }

            const handler_resp = exec_result.response;
            const identity = self.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity);
            const is_auth = identity.is_authenticated != 0 or
                handler_resp.session_action == .set_authenticated;

            var resp = PipelineResponse{
                .status = handler_resp.status,
                .session_action = handler_resp.session_action,
                .user_id = identity.user_id,
                .is_authenticated = is_auth,
                .is_new_visitor = identity.is_new != 0,
                .followup = null,
            };

            // SSE followup: mutations that modify data need a dashboard refresh.
            if (msg.operation.needs_followup()) {
                resp.followup = .{
                    .operation = msg.operation,
                    .status = resp.status,
                    .user_id = resp.user_id,
                    .kind = if (resp.is_authenticated) .authenticated else .anonymous,
                    .session_action = resp.session_action,
                    .is_new_visitor = resp.is_new_visitor,
                };
            }

            self.tracer.count_status(resp.status);
            return resp;
        }

        /// Dispatch to per-pattern handlers. Private — only called by commit().
        /// Handlers return ExecuteResult (response + writes). The dispatch
        /// loop applies writes — handlers never call storage directly.
        fn execute(self: *StateMachine, msg: message.Message, result: StorageResult) message.MessageResponse {
            const exec_result: ExecuteResult = switch (msg.operation) {
                .root => unreachable,
                inline .get_product,
                .get_product_inventory,
                .get_collection,
                .get_order,
                => |comptime_op| ExecuteResult.read_only(self.execute_get(comptime_op, result)),

                inline .list_products,
                .list_collections,
                .list_orders,
                .search_products,
                => |comptime_op| ExecuteResult.read_only(self.execute_list(comptime_op, result)),

                .create_product => self.execute_create_product(msg.body_as(message.Product).*, result),
                .create_collection => self.execute_create_collection(msg.body_as(message.ProductCollection).*, result),

                .delete_product => self.execute_soft_delete_product(msg.id, result),
                .delete_collection => self.execute_soft_delete_collection(msg.id, result),

                .update_product => self.execute_update_product(
                    msg.id,
                    msg.body_as(message.Product).*,
                    result,
                ),

                .add_collection_member => self.execute_add_member(
                    msg.id,
                    msg.body_as(u128).*,
                    result,
                ),

                .remove_collection_member => self.execute_remove_member(
                    msg.id,
                    msg.body_as(u128).*,
                    result,
                ),

                .transfer_inventory => self.execute_transfer_inventory(
                    msg.id,
                    msg.body_as(message.InventoryTransfer).*,
                    result,
                ),

                .create_order => self.execute_create_order(
                    msg.body_as(message.OrderRequest).*,
                    result,
                ),

                .complete_order => self.execute_complete_order(
                    msg.id,
                    msg.body_as(message.OrderCompletion).*,
                    result,
                ),

                .cancel_order => self.execute_cancel_order(msg.id, result),

                .page_load_dashboard => ExecuteResult.read_only(self.execute_dashboard(result)),
                .page_load_login => ExecuteResult.read_only(message.MessageResponse.empty_ok),
                .logout => ExecuteResult.read_only(.{ .status = .ok, .result = .{ .empty = {} }, .session_action = .clear }),

                .request_login_code => self.execute_request_login_code(
                    msg.body_as(message.LoginCodeRequest).*,
                    result,
                ),

                .verify_login_code => self.execute_verify_login_code(
                    msg.body_as(message.LoginVerification).*,
                    result,
                ),
            };

            for (exec_result.writes[0..exec_result.writes_len]) |w| {
                // Native path: our execute handlers guarantee writes are valid
                // after prefetch. Assert — a failure here is a programming bug.
                assert(self.apply_write(w));
            }
            return exec_result.response;
        }

        /// Apply a single write command to storage. Returns true on success.
        /// One dispatch table used by both native commit (asserts the result)
        /// and the sidecar path (validates the result).
        pub fn apply_write(self: *StateMachine, w: Write) bool {
            return switch (w) {
                .put_product => |p| self.storage.put(&p) == .ok,
                .update_product => |p| self.storage.update(p.id, &p) == .ok,
                .put_collection => |col| self.storage.put_collection(&col) == .ok,
                .update_collection => |col| self.storage.update_collection(col.id, &col) == .ok,
                .put_membership => |m| self.storage.add_to_collection(m.collection_id, m.product_id) == .ok,
                .update_membership => |m| if (m.removed != 0) blk: {
                    const r = self.storage.remove_from_collection(m.collection_id, m.product_id);
                    break :blk r == .ok or r == .not_found;
                } else self.storage.add_to_collection(m.collection_id, m.product_id) == .ok,
                .put_order => |order| self.storage.put_order(&order) == .ok,
                .update_order => |order| self.storage.update_order_completion(&order) == .ok,
                .put_login_code => |lc| self.storage.put_login_code(lc.email[0..lc.email_len], &lc.code, lc.expires_at) == .ok,
                .consume_login_code => |lc| blk: {
                    _ = self.storage.consume_login_code(lc.email[0..lc.email_len]);
                    break :blk true;
                },
                .put_user => |u| self.storage.put_user(u.user_id, u.email[0..u.email_len]) == .ok,
            };
        }

        // --- Per-pattern execute handlers ---
        //
        // Operations are grouped by shared control flow, NOT by verb name.
        // If a future operation has different error handling (e.g., returns
        // a default instead of 404), it gets its own handler — don't force
        // it into an existing group just because it's a "get" or "delete."

        /// Get-by-ID pattern: check not_found, return cached entity.
        /// Shared by get_product, get_product_inventory, get_collection, get_order.
        /// Products use soft delete — inactive products return 404.
        fn execute_get(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            if (result == .not_found) return message.MessageResponse.not_found;
            assert(result == .ok);

            // Soft delete: inactive entities are treated as not found.
            if (op == .get_product or op == .get_product_inventory) {
                if (!self.prefetch_product.?.flags.active) return message.MessageResponse.not_found;
            }
            if (op == .get_collection) {
                if (!self.prefetch_collection.?.flags.active) return message.MessageResponse.not_found;
            }

            return .{
                .status = .ok,
                .result = switch (op) {
                    .get_product => .{ .product = self.prefetch_product.? },
                    .get_product_inventory => .{ .inventory = self.prefetch_product.?.inventory },
                    .get_collection => .{ .collection = .{
                        .collection = self.prefetch_collection.?,
                        .products = self.prefetch_product_list,
                    } },
                    .get_order => .{ .order = self.prefetch_order.? },
                    else => unreachable,
                },
            };
        }

        /// List pattern: return cached list.
        /// Shared by list_products, list_collections, list_orders, search_products.
        fn execute_list(self: *StateMachine, comptime op: message.Operation, result: StorageResult) message.MessageResponse {
            assert(result == .ok);
            return .{
                .status = .ok,
                .result = switch (op) {
                    .list_products, .search_products => .{ .product_list = self.prefetch_product_list },
                    .list_collections => .{ .collection_list = self.prefetch_collection_list },
                    .list_orders => .{ .order_list = self.prefetch_order_list },
                    else => unreachable,
                },
            };
        }

        /// Create product: field-by-field reconstruction guarantees canonical storage.
        /// Matches TigerBeetle's create_account pattern — never store the input
        /// struct directly, always reconstruct from validated fields.
        fn execute_create_product(_: *StateMachine, event: message.Product, result: StorageResult) ExecuteResult {
            if (result == .ok) return ExecuteResult.read_only(message.MessageResponse.storage_error);
            assert(result == .not_found);

            var entity: message.Product = .{
                .id = event.id,
                .name = std.mem.zeroes([message.product_name_max]u8),
                .description = std.mem.zeroes([message.product_description_max]u8),
                .name_len = event.name_len,
                .description_len = event.description_len,
                .price_cents = event.price_cents,
                .inventory = event.inventory,
                .version = 1,
                .flags = event.flags,
            };
            @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);
            @memcpy(entity.description[0..event.description_len], event.description[0..event.description_len]);

            // Pair assertion: reconstruction produced canonical output.
            assert(stdx.zeroed(entity.name[entity.name_len..]));
            assert(stdx.zeroed(entity.description[entity.description_len..]));

            return ExecuteResult.single(
                .{ .status = .ok, .result = .{ .product = entity } },
                .{ .put_product = entity },
            );
        }

        /// Create collection: field-by-field reconstruction guarantees canonical storage.
        fn execute_create_collection(_: *StateMachine, event: message.ProductCollection, result: StorageResult) ExecuteResult {
            if (result == .ok) return ExecuteResult.read_only(message.MessageResponse.storage_error);
            assert(result == .not_found);

            var entity: message.ProductCollection = .{
                .id = event.id,
                .name = std.mem.zeroes([message.collection_name_max]u8),
                .name_len = event.name_len,
                .flags = .{ .active = true },
                .reserved = std.mem.zeroes([14]u8),
            };
            @memcpy(entity.name[0..event.name_len], event.name[0..event.name_len]);

            // Pair assertion: reconstruction produced canonical output.
            assert(stdx.zeroed(entity.name[entity.name_len..]));
            assert(stdx.zeroed(&entity.reserved));

            return ExecuteResult.single(
                .{ .status = .ok, .result = .{ .collection = .{
                    .collection = entity,
                    .products = .{ .items = undefined, .len = 0, .reserved = .{0} ** 12 },
                } } },
                .{ .put_collection = entity },
            );
        }

        /// Soft delete: set active = false, increment version.
        /// Already-inactive products return 404 (idempotent).
        fn execute_soft_delete_product(self: *StateMachine, id: u128, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            var product = self.prefetch_product.?;
            assert(product.id == id);

            if (!product.flags.active) return ExecuteResult.read_only(message.MessageResponse.not_found);

            product.flags.active = false;
            product.version += 1;

            return ExecuteResult.single(message.MessageResponse.empty_ok, .{ .update_product = product });
        }

        /// Soft delete collection: set active = false.
        /// Already-inactive collections return 404 (idempotent).
        fn execute_soft_delete_collection(self: *StateMachine, id: u128, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            var collection = self.prefetch_collection.?;
            assert(collection.id == id);

            if (!collection.flags.active) return ExecuteResult.read_only(message.MessageResponse.not_found);

            collection.flags.active = false;

            return ExecuteResult.single(message.MessageResponse.empty_ok, .{ .update_collection = collection });
        }

        /// Update with optimistic concurrency: client provides expected version,
        /// server rejects if it doesn't match. Version increments on success.
        /// Field-by-field reconstruction guarantees canonical storage.
        fn execute_update_product(self: *StateMachine, id: u128, event: message.Product, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            const current = self.prefetch_product.?;
            assert(current.id == id);

            // Version 0 means "no version check" (backwards compatibility).
            if (event.version != 0 and event.version != current.version) {
                return ExecuteResult.read_only(.{ .status = .version_conflict, .result = .{ .empty = {} } });
            }

            var updated: message.Product = .{
                .id = id,
                .name = std.mem.zeroes([message.product_name_max]u8),
                .description = std.mem.zeroes([message.product_description_max]u8),
                .name_len = event.name_len,
                .description_len = event.description_len,
                .price_cents = event.price_cents,
                .inventory = event.inventory,
                .version = current.version + 1,
                .flags = event.flags,
            };
            @memcpy(updated.name[0..event.name_len], event.name[0..event.name_len]);
            @memcpy(updated.description[0..event.description_len], event.description[0..event.description_len]);

            // Pair assertion: reconstruction produced canonical output.
            assert(stdx.zeroed(updated.name[updated.name_len..]));
            assert(stdx.zeroed(updated.description[updated.description_len..]));

            return ExecuteResult.single(
                .{ .status = .ok, .result = .{ .product = updated } },
                .{ .update_product = updated },
            );
        }

        fn execute_add_member(_: *StateMachine, id: u128, product_id: u128, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);
            return ExecuteResult.single(message.MessageResponse.empty_ok, .{ .put_membership = .{ .collection_id = id, .product_id = product_id } });
        }

        fn execute_remove_member(_: *StateMachine, id: u128, product_id: u128, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);
            return ExecuteResult.single(message.MessageResponse.empty_ok, .{ .update_membership = .{ .collection_id = id, .product_id = product_id, .removed = 1, .reserved = .{0} ** 15 } });
        }

        /// Transfer inventory: two products in cache, cross-entity validation, two writes.
        /// Writes are infallible after prefetch (TigerBeetle style): prefetch proved both
        /// products exist, so update() is a memcpy into an occupied slot.
        fn execute_transfer_inventory(self: *StateMachine, source_id: u128, transfer: message.InventoryTransfer, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            var source = self.prefetch_find(source_id).?;
            var target = self.prefetch_find(transfer.target_id).?;

            // Business logic: source must have enough inventory.
            if (source.inventory < transfer.quantity) {
                return ExecuteResult.read_only(.{ .status = .insufficient_inventory, .result = .{ .empty = {} } });
            }

            source.inventory -= transfer.quantity;
            target.inventory += transfer.quantity;

            // Return both updated products.
            var result_list = message.ProductList{ .items = undefined, .len = 2, .reserved = .{0} ** 12 };
            result_list.items[0] = source;
            result_list.items[1] = target;

            var exec_result = ExecuteResult{
                .response = .{ .status = .ok, .result = .{ .product_list = result_list } },
                .writes = undefined,
                .writes_len = 2,
            };
            exec_result.writes[0] = .{ .update_product = source };
            exec_result.writes[1] = .{ .update_product = target };
            return exec_result;
        }

        /// Create order: N products in cache, validate all have sufficient inventory,
        /// decrement all inventories atomically, return order summary.
        /// Uses list slots for multi-entity prefetch — one slot per line item.
        fn execute_create_order(self: *StateMachine, order: message.OrderRequest, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            // Phase 1: validate all items have sufficient inventory.
            for (order.items_slice()) |item| {
                const product = self.prefetch_find(item.product_id).?;
                if (product.inventory < item.quantity) {
                    return ExecuteResult.read_only(.{ .status = .insufficient_inventory, .result = .{ .empty = {} } });
                }
            }

            // Phase 2: all validated — decrement inventories and build result.
            var order_result = std.mem.zeroes(message.OrderResult);
            order_result.id = order.id;
            order_result.items_len = order.items_len;
            order_result.status = .pending;
            assert(self.now > 0);
            order_result.timeout_at = @intCast(self.now + message.order_timeout_seconds);

            var exec_result = ExecuteResult{
                .response = undefined,
                .writes = undefined,
                .writes_len = 0,
            };

            for (order.items_slice(), 0..) |item, i| {
                var product = self.prefetch_find(item.product_id).?;
                product.inventory -= item.quantity;

                exec_result.writes[exec_result.writes_len] = .{ .update_product = product };
                exec_result.writes_len += 1;

                const line_total = @as(u64, product.price_cents) * @as(u64, item.quantity);
                order_result.items[i] = std.mem.zeroes(message.OrderResultItem);
                order_result.items[i].product_id = product.id;
                // Safe: product came from storage, already canonical.
                order_result.items[i].name = product.name;
                order_result.items[i].name_len = product.name_len;
                order_result.items[i].quantity = item.quantity;
                order_result.items[i].price_cents = product.price_cents;
                order_result.items[i].line_total_cents = line_total;
                order_result.total_cents +|= line_total;
            }

            // Put order write after product updates.
            exec_result.writes[exec_result.writes_len] = .{ .put_order = order_result };
            exec_result.writes_len += 1;

            exec_result.response = .{ .status = .ok, .result = .{ .order = order_result } };
            return exec_result;
        }

        /// Complete a pending order — two-phase commit (phase 2).
        /// The worker calls this after the external API call succeeds or fails.
        /// On failure, restores reserved inventory.
        fn execute_complete_order(self: *StateMachine, id: u128, completion: message.OrderCompletion, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            var order = self.prefetch_order.?;
            assert(order.id == id);

            // Idempotent: if order already matches the requested terminal state,
            // return OK without modification. Handles worker retry after crash.
            if (order.status == .confirmed and completion.result == .confirmed)
                return ExecuteResult.read_only(.{ .status = .ok, .result = .{ .order = order } });
            if (order.status == .failed and completion.result == .failed)
                return ExecuteResult.read_only(.{ .status = .ok, .result = .{ .order = order } });

            // Only pending orders can be completed.
            if (order.status != .pending) {
                return ExecuteResult.read_only(.{ .status = .order_not_pending, .result = .{ .empty = {} } });
            }

            // Check timeout — if expired, reject and restore inventory.
            assert(self.now > 0);
            if (self.now >= order.timeout_at) {
                order.status = .failed;
                var exec_result = ExecuteResult{
                    .response = .{ .status = .order_expired, .result = .{ .empty = {} } },
                    .writes = undefined,
                    .writes_len = 0,
                };
                exec_result.writes[0] = .{ .update_order = order };
                exec_result.writes_len = 1;
                self.append_restore_inventory(&exec_result, &order);
                return exec_result;
            }

            switch (completion.result) {
                .confirmed => {
                    order.status = .confirmed;
                    order.payment_ref = completion.payment_ref;
                    order.payment_ref_len = completion.payment_ref_len;
                    return ExecuteResult.single(
                        .{ .status = .ok, .result = .{ .order = order } },
                        .{ .update_order = order },
                    );
                },
                .failed => {
                    order.status = .failed;
                    var exec_result = ExecuteResult{
                        .response = .{ .status = .ok, .result = .{ .order = order } },
                        .writes = undefined,
                        .writes_len = 0,
                    };
                    exec_result.writes[0] = .{ .update_order = order };
                    exec_result.writes_len = 1;
                    self.append_restore_inventory(&exec_result, &order);
                    return exec_result;
                },
            }
        }

        /// Cancel a pending order — client-initiated abort.
        /// Restores reserved inventory, same as a failed completion.
        fn execute_cancel_order(self: *StateMachine, id: u128, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.not_found);
            assert(result == .ok);

            var order = self.prefetch_order.?;
            assert(order.id == id);

            if (order.status != .pending) {
                return ExecuteResult.read_only(.{ .status = .order_not_pending, .result = .{ .empty = {} } });
            }

            order.status = .cancelled;

            var exec_result = ExecuteResult{
                .response = .{ .status = .ok, .result = .{ .order = order } },
                .writes = undefined,
                .writes_len = 0,
            };
            exec_result.writes[0] = .{ .update_order = order };
            exec_result.writes_len = 1;
            self.append_restore_inventory(&exec_result, &order);
            return exec_result;
        }

        /// Append inventory restore writes for all items in a failed/expired order.
        /// Products were prefetched by prefetch_order_with_products.
        /// Product may have been soft-deleted between order creation and
        /// completion — prefetch_find returns null for missing products.
        fn append_restore_inventory(self: *StateMachine, exec_result: *ExecuteResult, order: *const message.OrderResult) void {
            for (order.items[0..order.items_len]) |item| {
                var product = self.prefetch_find(item.product_id) orelse continue;
                product.inventory += item.quantity;
                exec_result.writes[exec_result.writes_len] = .{ .update_product = product };
                exec_result.writes_len += 1;
            }
        }


        // --- Login / auth handlers ---

        fn prefetch_login_code(self: *StateMachine, event: message.LoginCodeRequest) StorageResult {
            // Read existing code for this email (to overwrite).
            var entry: Storage.LoginCodeEntry = undefined;
            const r = self.storage.get_login_code(event.email[0..event.email_len], &entry);
            switch (r) {
                .ok => self.prefetch_login_code_entry = entry,
                .not_found => self.prefetch_login_code_entry = null,
                .busy => return .busy,
                .err => return .err,
                .corruption => @panic("storage corruption in prefetch_login_code"),
            }
            return .ok;
        }

        fn prefetch_verify_login(self: *StateMachine, event: message.LoginVerification) StorageResult {
            // Read the stored code.
            var entry: Storage.LoginCodeEntry = undefined;
            const r1 = self.storage.get_login_code(event.email[0..event.email_len], &entry);
            switch (r1) {
                .ok => self.prefetch_login_code_entry = entry,
                .not_found => return .not_found,
                .busy => return .busy,
                .err => return .err,
                .corruption => @panic("storage corruption in prefetch_verify_login"),
            }
            // Read existing user for this email (may or may not exist).
            var user_id: u128 = undefined;
            const r2 = self.storage.get_user_by_email(event.email[0..event.email_len], &user_id);
            switch (r2) {
                .ok => self.prefetch_user_by_email = user_id,
                .not_found => self.prefetch_user_by_email = null,
                .busy => return .busy,
                .err => return .err,
                .corruption => @panic("storage corruption in prefetch_verify_login"),
            }
            return .ok;
        }

        fn execute_request_login_code(self: *StateMachine, event: message.LoginCodeRequest, result: StorageResult) ExecuteResult {
            assert(result == .ok);
            const expires_at = self.now + 300; // 5 minutes
            const code = self.generate_login_code();

            return ExecuteResult.single(
                .{
                    .status = .ok,
                    .result = .{ .login = .{
                        .user_id = 0,
                        .email = event.email,
                        .code = code,
                        .email_len = event.email_len,
                        .reserved = .{0} ** 9,
                    } },
                },
                .{ .put_login_code = .{
                    .email = event.email,
                    .code = code,
                    .email_len = event.email_len,
                    .reserved = 0,
                    .expires_at = expires_at,
                } },
            );
        }

        fn execute_verify_login_code(self: *StateMachine, event: message.LoginVerification, result: StorageResult) ExecuteResult {
            if (result == .not_found) return ExecuteResult.read_only(message.MessageResponse.invalid_code);
            assert(result == .ok);

            const entry = self.prefetch_login_code_entry.?;

            // Check expiry first.
            if (self.now > entry.expires_at) return ExecuteResult.read_only(message.MessageResponse.code_expired);

            // Check code matches.
            if (!std.mem.eql(u8, &entry.code, &event.code)) return ExecuteResult.read_only(message.MessageResponse.invalid_code);

            // Code is valid — consume it and optionally create user.
            var exec_result = ExecuteResult{
                .response = undefined,
                .writes = undefined,
                .writes_len = 0,
            };

            // Write 1: consume the login code.
            exec_result.writes[0] = .{ .consume_login_code = .{
                .email = event.email,
                .email_len = event.email_len,
            } };
            exec_result.writes_len = 1;

            // Find or create user. If no existing user for this email,
            // use the resolved identity from the credential.
            const identity_user_id = self.prefetch_identity.?.user_id;
            const user_id = if (self.prefetch_user_by_email) |existing|
                existing
            else blk: {
                assert(identity_user_id != 0);
                // Write 2: create new user.
                exec_result.writes[1] = .{ .put_user = .{
                    .user_id = identity_user_id,
                    .email = event.email,
                    .email_len = event.email_len,
                    .reserved = .{0} ** 15,
                } };
                exec_result.writes_len = 2;
                break :blk identity_user_id;
            };

            exec_result.response = .{
                .status = .ok,
                .result = .{ .login = .{
                    .user_id = user_id,
                    .email = event.email,
                    .code = .{0} ** message.code_length,
                    .email_len = event.email_len,
                    .reserved = .{0} ** 9,
                } },
                .session_action = .set_authenticated,
            };
            return exec_result;
        }

        fn generate_login_code(self: *StateMachine) [message.code_length]u8 {
            var code: [message.code_length]u8 = undefined;
            for (&code) |*c| {
                c.* = '0' + @as(u8, @intCast(self.prng.int(u8) % 10));
            }
            return code;
        }

        fn reset_prefetch_cache(self: *StateMachine) void {
            self.prefetch_product = null;
            self.prefetch_product_list.len = 0;
            self.prefetch_products = [_]?message.Product{null} ** message.order_items_max;
            self.prefetch_collection = null;
            self.prefetch_collection_list.len = 0;
            self.prefetch_order = null;
            self.prefetch_order_list.len = 0;
            self.prefetch_login_code_entry = null;
            self.prefetch_user_by_email = null;
            self.prefetch_identity = null;
        }

        fn reset_prefetch(self: *StateMachine) void {
            self.reset_prefetch_cache();
            self.prefetch_result = null;
        }

        /// Resolve credential from the message. Called at the top of commit.
        /// Verifies cookie if present, mints a new identity if absent or invalid.
        /// Does not mutate the message — the resolved identity lives on self.
        pub fn resolve_credential(self: *StateMachine, msg: message.Message) void {
            if (msg.credential_slice()) |cv| {
                if (auth.verify_cookie(cv, self.secret_key)) |verified| {
                    self.prefetch_identity = .{
                        .user_id = verified.user_id,
                        .kind = @enumFromInt(@intFromEnum(verified.kind)),
                        .is_authenticated = @intFromBool(verified.kind == .authenticated),
                        .is_new = 0,
                        .reserved = .{0} ** 13,
                    };
                    return;
                }
            }
            // No credential or invalid — mint a new anonymous identity.
            const user_id = mint_user_id(&self.prng);
            self.prefetch_identity = .{
                .user_id = user_id,
                .kind = .anonymous,
                .is_authenticated = 0,
                .is_new = 1,
                .reserved = .{0} ** 13,
            };
        }

        /// Copy resolved identity onto the response. The render layer uses
        /// these structured fields to format Set-Cookie headers.
        pub fn apply_auth_response(self: *StateMachine, resp: *message.MessageResponse) void {
            const identity = self.prefetch_identity orelse return;
            resp.user_id = identity.user_id;
            resp.is_authenticated = identity.is_authenticated != 0;
            resp.kind = switch (identity.kind) {
                .anonymous => .anonymous,
                .authenticated => .authenticated,
            };
            resp.is_new_visitor = identity.is_new != 0;

            // Login success overrides: the login result's user_id becomes
            // the session identity, not the anonymous visitor who submitted the form.
            if (resp.session_action == .set_authenticated) {
                const login_result = resp.result.login;
                assert(login_result.user_id != 0);
                resp.user_id = login_result.user_id;
                resp.is_authenticated = true;
                resp.kind = .authenticated;
            }
        }

        fn mint_user_id(prng: *PRNG) u128 {
            while (true) {
                const id = prng.int(u128);
                message.maybe(id == 0);
                if (id != 0) return id;
            }
        }

        /// Cross-check structural invariants after every commit.
        fn invariants(self: *StateMachine) void {
            // Prefetch cache must be clean after commit.
            assert(self.prefetch_result == null);
            assert(self.prefetch_product == null);
            assert(self.prefetch_product_list.len == 0);
            assert(self.prefetch_collection == null);
            assert(self.prefetch_collection_list.len == 0);
            assert(self.prefetch_order == null);
            assert(self.prefetch_order_list.len == 0);
            assert(self.prefetch_login_code_entry == null);
            assert(self.prefetch_user_by_email == null);
            assert(self.prefetch_identity == null);
            for (self.prefetch_products) |slot| assert(slot == null);
        }

        // --- Product prefetch helpers (read-only) ---

        fn prefetch_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var product: message.Product = undefined;
            const result = self.storage.get(id, &product);
            if (result == .ok) self.prefetch_product = product;
            return result;
        }

        fn prefetch_list_products(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list(&self.prefetch_product_list.items, &self.prefetch_product_list.len, params);
        }

        fn prefetch_search_products(self: *StateMachine, query: message.SearchQuery) StorageResult {
            return self.storage.search(&self.prefetch_product_list.items, &self.prefetch_product_list.len, query);
        }

        /// Multi-key prefetch: read N products by ID into the keyed cache.
        /// Execute retrieves them via prefetch_find(id), not by position.
        fn prefetch_multi(self: *StateMachine, ids: []const u128) StorageResult {
            assert(ids.len > 0);
            assert(ids.len <= message.order_items_max);
            for (ids, 0..) |id, i| {
                assert(id > 0);
                var product: message.Product = undefined;
                const r = self.storage.get(id, &product);
                if (r != .ok) return r;
                self.prefetch_products[i] = product;
            }
            return .ok;
        }

        /// Look up a prefetched product by ID. Returns null if not found.
        /// TB equivalent: grooves.accounts.get(id) — keyed lookup, not positional.
        fn prefetch_find(self: *StateMachine, id: u128) ?message.Product {
            for (&self.prefetch_products) |*slot| {
                const product = slot.* orelse continue;
                if (product.id == id) return product;
            }
            return null;
        }

        // --- Collection prefetch helpers (read-only) ---

        fn prefetch_collection_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var col: message.ProductCollection = undefined;
            const result = self.storage.get_collection(id, &col);
            if (result == .ok) self.prefetch_collection = col;
            return result;
        }

        fn prefetch_list_all_collections(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list_collections(&self.prefetch_collection_list.items, &self.prefetch_collection_list.len, params.cursor);
        }

        // --- Order prefetch helpers (read-only) ---

        fn prefetch_order_read(self: *StateMachine, id: u128) StorageResult {
            assert(id > 0);
            var order: message.OrderResult = undefined;
            const result = self.storage.get_order(id, &order);
            if (result == .ok) self.prefetch_order = order;
            return result;
        }

        /// Prefetch an order and all its products for inventory restoration.
        /// Complete/cancel may need to restore inventory, which requires
        /// product data. Prefetching here means execute never reads storage.
        fn prefetch_order_with_products(self: *StateMachine, id: u128) StorageResult {
            const r = self.prefetch_order_read(id);
            if (r != .ok) return r;
            const order = self.prefetch_order.?;
            var ids: [message.order_items_max]u128 = undefined;
            for (order.items[0..order.items_len], 0..) |item, i| {
                ids[i] = item.product_id;
            }
            return self.prefetch_multi(ids[0..order.items_len]);
        }

        fn prefetch_list_all_orders(self: *StateMachine, params: message.ListParams) StorageResult {
            return self.storage.list_orders(&self.prefetch_order_list.items, &self.prefetch_order_list.len, params.cursor);
        }

        /// Prefetch both the collection and its member products.
        /// This is the multi-read that stresses the prefetch cache —
        /// two different entity types fetched in one prefetch phase.
        fn prefetch_collection_with_products(self: *StateMachine, collection_id: u128) StorageResult {
            assert(collection_id > 0);
            const r1 = self.prefetch_collection_read(collection_id);
            if (r1 != .ok) return r1;
            return self.storage.list_products_in_collection(
                collection_id,
                &self.prefetch_product_list.items,
                &self.prefetch_product_list.len,
            );
        }

        // --- Dashboard (page_load_dashboard) ---

        /// Prefetch all three lists for the dashboard page.
        fn prefetch_dashboard(self: *StateMachine) StorageResult {
            var params = std.mem.zeroes(message.ListParams);
            params.active_filter = .active_only;
            const r1 = self.prefetch_list_products(params);
            if (r1 != .ok) return r1;
            params.active_filter = .any; // collections/orders don't filter by active
            const r2 = self.prefetch_list_all_collections(params);
            if (r2 != .ok) return r2;
            return self.prefetch_list_all_orders(params);
        }

        /// Execute dashboard: return all three cached lists, capped to dashboard_list_max.
        fn execute_dashboard(self: *StateMachine, result: StorageResult) message.MessageResponse {
            assert(result == .ok);

            // Domain cap: dashboard shows a summary, not a full dump.
            // Storage may return up to list_max; we cap to dashboard_list_max.
            var products = self.prefetch_product_list;
            products.len = @min(products.len, message.dashboard_list_max);
            var collections = self.prefetch_collection_list;
            collections.len = @min(collections.len, message.dashboard_list_max);
            var orders = self.prefetch_order_list;
            orders.len = @min(orders.len, message.dashboard_list_max);

            return .{
                .status = .ok,
                .result = .{ .page_load_dashboard = .{
                    .products = products,
                    .collections = collections,
                    .orders = orders,
                } },
            };
        }
    };
}

pub const MemoryStorage = @import("memory_storage.zig").MemoryStorage;

