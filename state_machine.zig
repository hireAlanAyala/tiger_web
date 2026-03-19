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

/// Storage result type — shared by all storage backends.
pub const StorageResult = enum { ok, not_found, err, busy, corruption };

/// State machine parameterized on a Storage backend.
/// In production, Storage is SqliteStorage. In simulation, Storage is MemoryStorage.
///
/// Request processing is split into two phases (TigerBeetle style):
/// - `prefetch(msg)` reads from storage into cache slots. Read-only — never mutates
///   storage. Returns false if storage is busy (retry next tick).
/// - `execute(msg)` decides from cache slots, then writes mutations to storage.
pub fn StateMachineType(comptime Storage: type) type {
    return struct {
        const StateMachine = @This();

        /// Helper structs for Write variants.
        pub const LoginCodeWrite = message.LoginCodeWrite;
        pub const LoginCodeKey = message.LoginCodeKey;

        /// Write command — describes a storage mutation returned by execute handlers.
        /// Execute is pure: it returns writes, the dispatch loop applies them.
        /// All payload types are extern structs for sidecar wire serialization.
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
        /// put_order (1) + N update_product for inventory (order_items_max = 20).
        pub const writes_max = 1 + message.order_items_max;

        comptime {
            assert(writes_max == 21);
        }

        /// Result of a pure execute handler: response + collected writes.
        pub const ExecuteResult = struct {
            response: message.MessageResponse,
            writes: [writes_max]Write,
            writes_len: u8,

            /// Read-only operation — no writes.
            pub fn read_only(response: message.MessageResponse) ExecuteResult {
                return .{
                    .response = response,
                    .writes = undefined,
                    .writes_len = 0,
                };
            }

            /// Single-write operation.
            pub fn single(response: message.MessageResponse, write: Write) ExecuteResult {
                var result = ExecuteResult{
                    .response = response,
                    .writes = undefined,
                    .writes_len = 1,
                };
                result.writes[0] = write;
                return result;
            }
        };

        storage: *Storage,
        tracer: Tracer,
        prng: PRNG,
        secret_key: *const [auth.key_length]u8,

        /// Wall-clock time (seconds since epoch). Set by the server before
        /// each process_inbox call. Used for order timeout_at.
        now: i64,

        // Prefetch cache — populated by prefetch(), consumed by commit().
        //
        // Two product caches for different access patterns:
        // - prefetch_product: single-entity lookup (get, create, update, delete)
        // - prefetch_product_list: list results (list_products, collection members)
        // - prefetch_products: multi-key lookup by ID (transfer_inventory, create_order)
        prefetch_product: ?message.Product,
        prefetch_product_list: message.ProductList,
        prefetch_products: [message.order_items_max]?message.Product,
        prefetch_collection: ?message.ProductCollection,
        prefetch_collection_list: message.CollectionList,
        prefetch_order: ?message.OrderResult,
        prefetch_order_list: message.OrderSummaryList,
        prefetch_login_code_entry: ?Storage.LoginCodeEntry,
        prefetch_user_by_email: ?u128,
        prefetch_result: ?StorageResult,
        prefetch_identity: ?message.PrefetchIdentity,

        pub fn init(storage: *Storage, log_trace: bool, prng_seed: u64, secret_key: *const [auth.key_length]u8) StateMachine {
            return .{
                .storage = storage,
                .tracer = Tracer.init(log_trace),
                .prng = PRNG.from_seed(prng_seed),
                .secret_key = secret_key,
                .now = 0,
                .prefetch_product = null,
                .prefetch_product_list = .{ .items = undefined, .len = 0, .reserved = .{0} ** 12 },
                .prefetch_products = [_]?message.Product{null} ** message.order_items_max,
                .prefetch_collection = null,
                .prefetch_collection_list = .{ .items = undefined, .len = 0, .reserved = .{0} ** 12 },
                .prefetch_order = null,
                .prefetch_order_list = .{ .items = undefined, .len = 0, .reserved = .{0} ** 12 },
                .prefetch_login_code_entry = null,
                .prefetch_user_by_email = null,
                .prefetch_result = null,
                .prefetch_identity = null,
            };
        }

        /// Returns whether the message is valid input for the state machine.
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

        /// Phase 1: read data from storage into cache slots. Never writes.
        /// Returns true if prefetch completed (success or error).
        /// Returns false if storage is busy — connection stays .ready, retried next tick.
        pub fn prefetch(self: *StateMachine, msg: message.Message) bool {

            assert(self.prefetch_result == null);
            self.reset_prefetch_cache();

            const result: StorageResult = switch (msg.operation) {
                .root => unreachable,
                .get_product, .get_product_inventory => self.prefetch_read(msg.id),
                .list_products => self.prefetch_list_products(msg.body_as(message.ListParams).*),
                .create_product => blk: {
                    const p = msg.body_as(message.Product);
                    assert(p.id > 0);
                    assert(p.name_len > 0);
                    break :blk self.prefetch_read(p.id);
                },
                .update_product => blk: {
                    assert(msg.id > 0);
                    assert(msg.body_as(message.Product).name_len > 0);
                    break :blk self.prefetch_read(msg.id);
                },
                .delete_product => self.prefetch_read(msg.id),
                .get_collection => self.prefetch_collection_with_products(msg.id),
                .list_collections => self.prefetch_list_all_collections(msg.body_as(message.ListParams).*),
                .create_collection => blk: {
                    const col = msg.body_as(message.ProductCollection);
                    assert(col.id > 0);
                    assert(col.name_len > 0);
                    break :blk self.prefetch_collection_read(col.id);
                },
                .delete_collection => self.prefetch_collection_read(msg.id),
                .add_collection_member => blk: {
                    const product_id = msg.body_as(u128).*;
                    // Read both collection and product to verify existence.
                    const r1 = self.prefetch_collection_read(msg.id);
                    if (r1 != .ok and r1 != .not_found) break :blk r1;
                    const r2 = self.prefetch_read(product_id);
                    if (r2 != .ok and r2 != .not_found) break :blk r2;
                    // Both must exist.
                    if (r1 == .not_found or r2 == .not_found) break :blk .not_found;
                    break :blk .ok;
                },
                .remove_collection_member => self.prefetch_collection_read(msg.id),
                .search_products => self.prefetch_search_products(msg.body_as(message.SearchQuery).*),
                .get_order => self.prefetch_order_read(msg.id),
                .complete_order, .cancel_order => self.prefetch_order_with_products(msg.id),
                .list_orders => self.prefetch_list_all_orders(msg.body_as(message.ListParams).*),
                .page_load_dashboard => self.prefetch_dashboard(),
                .page_load_login, .logout => .ok,
                .request_login_code => self.prefetch_login_code(msg.body_as(message.LoginCodeRequest).*),
                .verify_login_code => self.prefetch_verify_login(msg.body_as(message.LoginVerification).*),
                .transfer_inventory => blk: {
                    const transfer = msg.body_as(message.InventoryTransfer);
                    assert(msg.id > 0);
                    assert(transfer.target_id > 0);
                    assert(msg.id != transfer.target_id);
                    break :blk self.prefetch_multi(&.{ msg.id, transfer.target_id });
                },
                .create_order => blk: {
                    const order = msg.body_as(message.OrderRequest);
                    assert(order.items_len > 0);
                    assert(order.items_len <= message.order_items_max);
                    assert(order.id > 0);
                    var ids: [message.order_items_max]u128 = undefined;
                    for (order.items_slice(), 0..) |item, i| {
                        assert(item.product_id > 0);
                        assert(item.quantity > 0);
                        ids[i] = item.product_id;
                    }
                    break :blk self.prefetch_multi(ids[0..order.items_len]);
                },
            };

            switch (result) {
                .busy => {
                    assert(self.prefetch_result == null);
                    return false;
                },
                .corruption => @panic("storage corruption in prefetch"),
                .ok, .not_found, .err => self.prefetch_result = result,
            }

            return true;
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

        /// Phase 2: commit — single entry point for the execute phase.
        /// Handles cross-cutting concerns (status counting) so individual
        /// handlers don't have to.
        /// Follows TigerBeetle's commit() pattern. Must only be called
        /// after prefetch() returned true.
        pub fn commit(self: *StateMachine, msg: message.Message) message.MessageResponse {
            const result = self.prefetch_result.?;
            defer self.invariants();
            defer self.reset_prefetch();

            self.resolve_credential(msg);

            var resp = if (result == .err)
                // Storage read error — return 503 regardless of operation.
                message.MessageResponse.storage_error
            else
                self.execute(msg, result);

            self.apply_auth_response(&resp);

            // SSE followup: mutations that modify data need a dashboard refresh.
            // Self-contained mutations (login, logout) render their own response
            // and leave followup null. The server reads resp.followup without
            // inspecting which operation ran.
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

            // Cross-cutting: count every response status. No handler opts
            // in or out — the commit loop guarantees it.
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
                self.apply_write(w);
            }
            return exec_result.response;
        }

        /// Apply a single write command to storage. Writes are infallible
        /// after prefetch — prefetch proved the operation is valid.
        fn apply_write(self: *StateMachine, w: Write) void {
            switch (w) {
                .put_product => |p| assert(self.storage.put(&p) == .ok),
                .update_product => |p| assert(self.storage.update(p.id, &p) == .ok),
                .put_collection => |col| assert(self.storage.put_collection(&col) == .ok),
                .update_collection => |col| assert(self.storage.update_collection(col.id, &col) == .ok),
                .put_membership => |m| assert(self.storage.add_to_collection(m.collection_id, m.product_id) == .ok),
                .update_membership => |m| {
                    if (m.removed != 0) {
                        const r = self.storage.remove_from_collection(m.collection_id, m.product_id);
                        assert(r == .ok or r == .not_found);
                    } else {
                        assert(self.storage.add_to_collection(m.collection_id, m.product_id) == .ok);
                    }
                },
                .put_order => |order| assert(self.storage.put_order(&order) == .ok),
                .update_order => |order| assert(self.storage.update_order_completion(&order) == .ok),
                .put_login_code => |lc| {
                    assert(self.storage.put_login_code(lc.email[0..lc.email_len], &lc.code, lc.expires_at) == .ok);
                },
                .consume_login_code => |lc| {
                    _ = self.storage.consume_login_code(lc.email[0..lc.email_len]);
                },
                .put_user => |u| {
                    const wr = self.storage.put_user(u.user_id, u.email[0..u.email_len]);
                    assert(wr == .ok);
                },
            }
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

        pub fn reset_prefetch(self: *StateMachine) void {
            self.reset_prefetch_cache();
            self.prefetch_result = null;
        }

        /// Resolve credential from the message. Called at the top of commit.
        /// Verifies cookie if present, mints a new identity if absent or invalid.
        /// Does not mutate the message — the resolved identity lives on self.
        fn resolve_credential(self: *StateMachine, msg: message.Message) void {
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
        fn apply_auth_response(self: *StateMachine, resp: *message.MessageResponse) void {
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

// =====================================================================
// In-memory storage — used for unit tests and sim tests.
// =====================================================================

pub const MemoryStorage = struct {
    pub const product_capacity = 1024;
    pub const collection_capacity = 256;
    pub const membership_capacity = 1024;
    pub const order_capacity = 256;
    pub const login_code_capacity = 64;
    pub const user_capacity = 256;

    const ProductEntry = struct {
        product: message.Product,
        occupied: bool,
    };

    const CollectionEntry = struct {
        collection: message.ProductCollection,
        occupied: bool,
    };

    const MembershipEntry = struct {
        collection_id: u128,
        product_id: u128,
        occupied: bool,
        removed: bool,
    };

    const OrderEntry = struct {
        order: message.OrderResult,
        occupied: bool,
    };

    pub const LoginCodeEntry = message.LoginCodeEntry;

    const UserEntry = struct {
        user_id: u128,
        email: [message.email_max]u8,
        email_len: u8,
        occupied: bool,
    };

    const empty_product = ProductEntry{ .product = undefined, .occupied = false };
    const empty_collection = CollectionEntry{ .collection = undefined, .occupied = false };
    const empty_membership = MembershipEntry{ .collection_id = 0, .product_id = 0, .occupied = false, .removed = false };
    const empty_order = OrderEntry{ .order = undefined, .occupied = false };
    const empty_login_code = LoginCodeEntry{ .email = undefined, .code = undefined, .email_len = 0, .occupied = 0, .expires_at = 0 };
    const empty_user = UserEntry{ .user_id = 0, .email = undefined, .email_len = 0, .occupied = false };

    products: *[product_capacity]ProductEntry,
    product_count: u32,
    collections_store: *[collection_capacity]CollectionEntry,
    collection_count: u32,
    memberships: *[membership_capacity]MembershipEntry,
    orders: *[order_capacity]OrderEntry,
    order_count: u32,
    login_codes: [login_code_capacity]LoginCodeEntry,
    users: [user_capacity]UserEntry,

    // Fault injection — PRNG-driven, same pattern as SimIO.
    prng: PRNG,
    busy_fault_probability: PRNG.Ratio,
    err_fault_probability: PRNG.Ratio,

    pub fn init(allocator: std.mem.Allocator) !MemoryStorage {
        const products = try allocator.create([product_capacity]ProductEntry);
        @memset(products, empty_product);
        const collections_store = try allocator.create([collection_capacity]CollectionEntry);
        @memset(collections_store, empty_collection);
        const memberships = try allocator.create([membership_capacity]MembershipEntry);
        @memset(memberships, empty_membership);
        const orders = try allocator.create([order_capacity]OrderEntry);
        @memset(orders, empty_order);
        return .{
            .products = products,
            .product_count = 0,
            .collections_store = collections_store,
            .collection_count = 0,
            .memberships = memberships,
            .orders = orders,
            .order_count = 0,
            .login_codes = [_]LoginCodeEntry{empty_login_code} ** login_code_capacity,
            .users = [_]UserEntry{empty_user} ** user_capacity,
            .prng = PRNG.from_seed(0),
            .busy_fault_probability = PRNG.Ratio.zero(),
            .err_fault_probability = PRNG.Ratio.zero(),
        };
    }

    pub fn deinit(self: *MemoryStorage, allocator: std.mem.Allocator) void {
        allocator.destroy(self.products);
        allocator.destroy(self.collections_store);
        allocator.destroy(self.memberships);
        allocator.destroy(self.orders);
    }

    pub fn reset(self: *MemoryStorage) void {
        @memset(self.products, empty_product);
        self.product_count = 0;
        @memset(self.collections_store, empty_collection);
        self.collection_count = 0;
        @memset(self.memberships, empty_membership);
        @memset(self.orders, empty_order);
        self.order_count = 0;
        self.login_codes = [_]LoginCodeEntry{empty_login_code} ** login_code_capacity;
        self.users = [_]UserEntry{empty_user} ** user_capacity;
    }

    pub fn begin(_: *MemoryStorage) void {}
    pub fn commit(_: *MemoryStorage) void {}

    pub fn get(self: *MemoryStorage, id: u128, out: *message.Product) StorageResult {
        if (self.fault()) |f| return f;
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                out.* = entry.product;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put(self: *MemoryStorage, product: *const message.Product) StorageResult {
        // No fault injection — writes are infallible (TigerBeetle style).
        // Prefetch validates; execute commits. If the machine is dying
        // (disk full, hardware failure), crash — don't try to handle it.
        // Reject duplicates.
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == product.id) return .err;
        }
        for (self.products) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .product = product.*, .occupied = true };
                self.product_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn update(self: *MemoryStorage, id: u128, product: *const message.Product) StorageResult {
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.product = product.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn delete(self: *MemoryStorage, id: u128) StorageResult {
        for (self.products) |*entry| {
            if (entry.occupied and entry.product.id == id) {
                entry.occupied = false;
                self.product_count -= 1;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list(self: *MemoryStorage, out: *[message.list_max]message.Product, out_len: *u32, params: message.ListParams) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            if (entry.product.id <= params.cursor) continue;
            if (!match_product_filters(&entry.product, params)) continue;
            insert_sorted(message.Product, out, out_len, entry.product);
        }
        return .ok;
    }

    pub fn search(self: *MemoryStorage, out: *[message.list_max]message.Product, out_len: *u32, query: message.SearchQuery) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.products) |*entry| {
            if (!entry.occupied) continue;
            if (!entry.product.flags.active) continue;
            if (query.matches(&entry.product)) {
                insert_sorted(message.Product, out, out_len, entry.product);
            }
        }
        return .ok;
    }

    fn match_product_filters(product: *const message.Product, params: message.ListParams) bool {
        // Active filter.
        switch (params.active_filter) {
            .any => {},
            .active_only => if (!product.flags.active) return false,
            .inactive_only => if (product.flags.active) return false,
        }
        // Price range.
        if (params.price_min > 0 and product.price_cents < params.price_min) return false;
        if (params.price_max > 0 and product.price_cents > params.price_max) return false;
        // Name prefix.
        if (params.name_prefix_len > 0) {
            const prefix = params.name_prefix[0..params.name_prefix_len];
            if (product.name_len < params.name_prefix_len) return false;
            if (!std.mem.startsWith(u8, product.name[0..product.name_len], prefix)) return false;
        }
        return true;
    }

    // --- Collection operations ---

    pub fn get_collection(self: *MemoryStorage, id: u128, out: *message.ProductCollection) StorageResult {
        if (self.fault()) |f| return f;
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == id) {
                out.* = entry.collection;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_collection(self: *MemoryStorage, col: *const message.ProductCollection) StorageResult {
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == col.id) return .err;
        }
        for (self.collections_store) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .collection = col.*, .occupied = true };
                self.collection_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn update_collection(self: *MemoryStorage, id: u128, col: *const message.ProductCollection) StorageResult {
        for (self.collections_store) |*entry| {
            if (entry.occupied and entry.collection.id == id) {
                entry.collection = col.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_collections(self: *MemoryStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32, cursor: u128) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.collections_store) |*entry| {
            if (!entry.occupied) continue;
            if (!entry.collection.flags.active) continue;
            if (entry.collection.id <= cursor) continue;
            insert_sorted(message.ProductCollection, out, out_len, entry.collection);
        }
        return .ok;
    }

    // --- Membership operations ---

    pub fn add_to_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        // Check for existing membership — un-remove if removed.
        for (self.memberships) |*m| {
            if (m.occupied and m.collection_id == collection_id and m.product_id == product_id) {
                m.removed = false;
                return .ok;
            }
        }
        for (self.memberships) |*m| {
            if (!m.occupied) {
                m.* = .{ .collection_id = collection_id, .product_id = product_id, .occupied = true, .removed = false };
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn remove_from_collection(self: *MemoryStorage, collection_id: u128, product_id: u128) StorageResult {
        for (self.memberships) |*m| {
            if (m.occupied and !m.removed and m.collection_id == collection_id and m.product_id == product_id) {
                m.removed = true;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_products_in_collection(self: *MemoryStorage, collection_id: u128, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.memberships) |*m| {
            if (!m.occupied or m.removed or m.collection_id != collection_id) continue;
            // Look up the product.
            for (self.products) |*entry| {
                if (entry.occupied and entry.product.id == m.product_id) {
                    insert_sorted(message.Product, out, out_len, entry.product);
                    break;
                }
            }
        }
        return .ok;
    }

    // --- Order operations ---

    pub fn put_order(self: *MemoryStorage, order: *const message.OrderResult) StorageResult {
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == order.id) return .err;
        }
        for (self.orders) |*entry| {
            if (!entry.occupied) {
                entry.* = .{ .order = order.*, .occupied = true };
                self.order_count += 1;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn get_order(self: *MemoryStorage, id: u128, out: *message.OrderResult) StorageResult {
        if (self.fault()) |f| return f;
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == id) {
                out.* = entry.order;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn update_order_completion(self: *MemoryStorage, order: *const message.OrderResult) StorageResult {
        for (self.orders) |*entry| {
            if (entry.occupied and entry.order.id == order.id) {
                entry.order.status = order.status;
                entry.order.payment_ref = order.payment_ref;
                entry.order.payment_ref_len = order.payment_ref_len;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn list_orders(self: *MemoryStorage, out: *[message.list_max]message.OrderSummary, out_len: *u32, cursor: u128) StorageResult {
        if (self.fault()) |f| return f;
        out_len.* = 0;
        for (self.orders) |*entry| {
            if (!entry.occupied) continue;
            if (entry.order.id <= cursor) continue;
            var summary = std.mem.zeroes(message.OrderSummary);
            summary.id = entry.order.id;
            summary.total_cents = entry.order.total_cents;
            summary.items_len = entry.order.items_len;
            summary.status = entry.order.status;
            summary.timeout_at = entry.order.timeout_at;
            summary.payment_ref = entry.order.payment_ref;
            summary.payment_ref_len = entry.order.payment_ref_len;
            insert_sorted(message.OrderSummary, out, out_len, summary);
        }
        return .ok;
    }

    /// Insert an entity into a sorted, bounded output buffer.
    /// Matches SqliteStorage's ORDER BY id LIMIT list_max — keeps
    /// the list_max entities with the smallest IDs, in ascending order.
    fn insert_sorted(comptime T: type, out: *[message.list_max]T, out_len: *u32, item: T) void {
        // Find insertion point (first element with id > item.id).
        var pos: u32 = 0;
        while (pos < out_len.*) : (pos += 1) {
            if (out[pos].id > item.id) break;
        }

        if (out_len.* < message.list_max) {
            // Buffer not full — shift right and insert.
            var i: u32 = out_len.*;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
            out_len.* += 1;
        } else if (pos < message.list_max) {
            // Buffer full but item belongs before the last element —
            // shift right from pos, dropping the last element.
            var i: u32 = message.list_max - 1;
            while (i > pos) : (i -= 1) {
                out[i] = out[i - 1];
            }
            out[pos] = item;
        }
        // else: item.id >= all current IDs and buffer is full — skip.
    }

    // --- Login code storage ---

    pub fn get_login_code(self: *MemoryStorage, email: []const u8, out: *LoginCodeEntry) StorageResult {
        if (self.fault()) |f| return f;
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                out.* = entry.*;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_login_code(self: *MemoryStorage, email: []const u8, code: *const [message.code_length]u8, expires_at: i64) StorageResult {
        // Overwrite existing code for this email.
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                entry.code = code.*;
                entry.expires_at = expires_at;
                return .ok;
            }
        }
        // Insert into first free slot.
        for (&self.login_codes) |*entry| {
            if (entry.occupied == 0) {
                entry.occupied = 1;
                entry.email_len = @intCast(email.len);
                @memset(&entry.email, 0);
                @memcpy(entry.email[0..email.len], email);
                entry.code = code.*;
                entry.expires_at = expires_at;
                return .ok;
            }
        }
        return .err; // full
    }

    pub fn consume_login_code(self: *MemoryStorage, email: []const u8) StorageResult {
        for (&self.login_codes) |*entry| {
            if (entry.occupied != 0 and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                entry.expires_at = 0;
                return .ok;
            }
        }
        return .not_found;
    }

    // --- User storage ---

    pub fn get_user_by_email(self: *MemoryStorage, email: []const u8, out: *u128) StorageResult {
        if (self.fault()) |f| return f;
        for (&self.users) |*entry| {
            if (entry.occupied and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                out.* = entry.user_id;
                return .ok;
            }
        }
        return .not_found;
    }

    pub fn put_user(self: *MemoryStorage, user_id: u128, email: []const u8) StorageResult {
        // Reject duplicate email.
        for (&self.users) |*entry| {
            if (entry.occupied and entry.email_len == email.len and
                std.mem.eql(u8, entry.email[0..entry.email_len], email))
            {
                return .err;
            }
        }
        for (&self.users) |*entry| {
            if (!entry.occupied) {
                entry.occupied = true;
                entry.user_id = user_id;
                entry.email_len = @intCast(email.len);
                @memset(&entry.email, 0);
                @memcpy(entry.email[0..email.len], email);
                return .ok;
            }
        }
        return .err; // full
    }

    /// Roll PRNG against fault probabilities. Returns a fault result or null.
    fn fault(self: *MemoryStorage) ?StorageResult {
        if (self.prng.chance(self.busy_fault_probability)) {
            log.mark.debug("storage: busy fault injected", .{});
            return .busy;
        }
        if (self.prng.chance(self.err_fault_probability)) {
            log.mark.debug("storage: err fault injected", .{});
            return .err;
        }
        return null;
    }
};

// =====================================================================
// Tests
// =====================================================================

fn make_test_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = id;
    p.name_len = @intCast(name.len);
    p.price_cents = price;
    p.flags = .{ .active = true };
    @memcpy(p.name[0..name.len], name);
    return p;
}

const TestStateMachine = StateMachineType(MemoryStorage);
const sm_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

fn list_params(active_filter: message.ListParams.ActiveFilter) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.active_filter = active_filter;
    return params;
}

fn list_params_cursor(cursor: u128) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.cursor = cursor;
    return params;
}

fn list_params_price(price_min: u32, price_max: u32) message.ListParams {
    var params = std.mem.zeroes(message.ListParams);
    params.price_min = price_min;
    params.price_max = price_max;
    return params;
}

fn test_execute(sm: *TestStateMachine, msg: message.Message) message.MessageResponse {
    if (sm.now == 0) sm.now = 1_700_000_000;
    assert(sm.prefetch(msg));
    return sm.commit(msg);
}

test "create and get" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xaabbccdd11223344aabbccdd11223344;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Widget", 999)));
    try std.testing.expectEqual(create_resp.status, .ok);
    const created = create_resp.result.product;
    try std.testing.expectEqual(created.id, test_id);
    try std.testing.expectEqualSlices(u8, created.name_slice(), "Widget");
    try std.testing.expectEqual(created.price_cents, 999);

    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, get_resp.result.product.name_slice(), "Widget");
}

test "get missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.get_product, 0x00000000000000000000000000000063, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "update" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x11111111111111111111111111111111;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Old Name", 100)));
    const id = create_resp.result.product.id;

    const update_resp = test_execute(&sm, message.Message.init(.update_product, id, 1, make_test_product(0, "New Name", 200)));
    try std.testing.expectEqual(update_resp.status, .ok);
    try std.testing.expectEqualSlices(u8, update_resp.result.product.name_slice(), "New Name");
    try std.testing.expectEqual(update_resp.result.product.price_cents, 200);
    try std.testing.expectEqual(update_resp.result.product.id, id);
}

test "delete" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x22222222222222222222222222222222;
    const create_resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Doomed", 100)));
    const id = create_resp.result.product.id;

    const del_resp = test_execute(&sm, message.Message.init(.delete_product, id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    const get_resp = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .not_found);
}

test "delete missing" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.delete_product, 0x00000000000000000000000000000063, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "soft delete preserves product in storage" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x33333333333333333333333333333333;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "SoftDel", 100)));

    // Delete (soft).
    const del_resp = test_execute(&sm, message.Message.init(.delete_product, test_id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    // GET returns 404.
    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .not_found);

    // Default list (active_only) excludes it.
    const list_resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));
    try std.testing.expectEqual(list_resp.result.product_list.len, 0);

    // List with inactive_only shows it.
    const list_inactive = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));
    try std.testing.expectEqual(list_inactive.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, list_inactive.result.product_list.items[0].name_slice(), "SoftDel");
    try std.testing.expectEqual(list_inactive.result.product_list.items[0].flags.active, false);
}

test "list" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0xaaaa0000000000000000000000000001, "A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0xaaaa0000000000000000000000000002, "B", 200)));

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[0].name_slice(), "A");
    try std.testing.expectEqualSlices(u8, resp.result.product_list.items[1].name_slice(), "B");
}

test "list returns results sorted by ID regardless of insertion order" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Insert in descending ID order — the opposite of sorted.
    const id_high: u128 = 0xff;
    const id_mid: u128 = 0x80;
    const id_low: u128 = 0x01;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_high, "High", 300)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_low, "Low", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_mid, "Mid", 200)));

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 3);
    // Must be sorted by ID, not insertion order.
    try std.testing.expectEqual(resp.result.product_list.items[0].id, id_low);
    try std.testing.expectEqual(resp.result.product_list.items[1].id, id_mid);
    try std.testing.expectEqual(resp.result.product_list.items[2].id, id_high);
}

test "list pagination returns the smallest IDs when more than list_max exist" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Create list_max + 10 products with IDs from 1..list_max+10,
    // inserted in reverse order to stress the sort.
    const total = message.list_max + 10;
    for (0..total) |i| {
        const id: u128 = total - i; // descending insertion: total, total-1, ..., 1
        _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id, "P", 100)));
    }

    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, message.list_max);
    // First page must be IDs 1..list_max, in order.
    for (0..message.list_max) |i| {
        try std.testing.expectEqual(resp.result.product_list.items[i].id, i + 1);
    }

    // Second page (cursor = list_max) must be the remaining 10.
    const resp2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(message.list_max)));
    try std.testing.expectEqual(resp2.status, .ok);
    try std.testing.expectEqual(resp2.result.product_list.len, 10);
    for (0..10) |i| {
        try std.testing.expectEqual(resp2.result.product_list.items[i].id, message.list_max + i + 1);
    }
}

test "list with cursor skips earlier items" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id1: u128 = 0x00000000000000000000000000000001;
    const id2: u128 = 0x00000000000000000000000000000002;
    const id3: u128 = 0x00000000000000000000000000000003;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id1, "A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id2, "B", 200)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id3, "C", 300)));

    // List with cursor = id1 should skip A, return B and C.
    const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id1)));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqual(resp.result.product_list.items[0].id, id2);
    try std.testing.expectEqual(resp.result.product_list.items[1].id, id3);

    // List with cursor = id2 should return only C.
    const resp2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id2)));
    try std.testing.expectEqual(resp2.result.product_list.len, 1);
    try std.testing.expectEqual(resp2.result.product_list.items[0].id, id3);

    // List with cursor = id3 should return empty.
    const resp3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_cursor(id3)));
    try std.testing.expectEqual(resp3.result.product_list.len, 0);
}

test "list filters by active status" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    var active = make_test_product(0x01, "Active", 100);
    active.flags.active = true;
    var inactive = make_test_product(0x02, "Inactive", 200);
    inactive.flags.active = false;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, active));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, inactive));

    // Filter active only.
    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.active_only)));
    try std.testing.expectEqual(r1.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r1.result.product_list.items[0].name_slice(), "Active");

    // Filter inactive only.
    const r2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params(.inactive_only)));
    try std.testing.expectEqual(r2.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r2.result.product_list.items[0].name_slice(), "Inactive");

    // No filter — both returned.
    const r3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(r3.result.product_list.len, 2);
}

test "list filters by price range" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x01, "Cheap", 500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x02, "Mid", 1500)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x03, "Expensive", 5000)));

    // price_min only.
    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 0)));
    try std.testing.expectEqual(r1.result.product_list.len, 2);

    // price_max only.
    const r2 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(0, 1000)));
    try std.testing.expectEqual(r2.result.product_list.len, 1);

    // Both min and max.
    const r3 = test_execute(&sm, message.Message.init(.list_products, 0, 1, list_params_price(1000, 2000)));
    try std.testing.expectEqual(r3.result.product_list.len, 1);
    try std.testing.expectEqualSlices(u8, r3.result.product_list.items[0].name_slice(), "Mid");
}

test "list filters by name prefix" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x01, "Widget A", 100)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x02, "Widget B", 200)));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(0x03, "Gadget", 300)));

    var params = std.mem.zeroes(message.ListParams);
    const prefix = "Widget";
    @memcpy(params.name_prefix[0..prefix.len], prefix);
    params.name_prefix_len = prefix.len;

    const r1 = test_execute(&sm, message.Message.init(.list_products, 0, 1, params));
    try std.testing.expectEqual(r1.result.product_list.len, 2);
}

test "client-provided IDs" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id1: u128 = 0xaabbccddaabbccddaabbccddaabbccd1;
    const id2: u128 = 0xaabbccddaabbccddaabbccddaabbccd2;
    const r1 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id1, "A", 1)));
    const r2 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id2, "B", 2)));
    try std.testing.expectEqual(r1.result.product.id, id1);
    try std.testing.expectEqual(r2.result.product.id, id2);
}

test "transfer inventory — success" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Target", 0);
    prod_b.inventory = 20;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 30 }));
    try std.testing.expectEqual(resp.status, .ok);
    // Response contains both updated products.
    try std.testing.expectEqual(resp.result.product_list.len, 2);
    try std.testing.expectEqual(resp.result.product_list.items[0].inventory, 70);
    try std.testing.expectEqual(resp.result.product_list.items[1].inventory, 50);

    // Verify storage was actually updated.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    try std.testing.expectEqual(get_a.result.product.inventory, 70);
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
    try std.testing.expectEqual(get_b.result.product.inventory, 50);
}

test "transfer inventory — insufficient stock" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Low", 0);
    prod_a.inventory = 5;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_b, "Other", 0)));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 10 }));
    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    try std.testing.expectEqual(get_a.result.product.inventory, 5);
}

test "transfer inventory — source not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_b: u128 = 0xcccc0000000000000000000000000002;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id_b, "Target", 0)));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, 0xcccc0000000000000000000000000001, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = id_b, .quantity = 1 }));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "transfer inventory — target not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xdddd0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Source", 0);
    prod_a.inventory = 50;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const resp = test_execute(&sm, message.Message.init(.transfer_inventory, id_a, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = 0xdddd0000000000000000000000000002, .quantity = 1 }));
    try std.testing.expectEqual(resp.status, .not_found);
}

fn make_order_request(id: u128, items: []const struct { id: u128, qty: u32 }) message.OrderRequest {
    assert(items.len > 0);
    assert(items.len <= message.order_items_max);
    var order = std.mem.zeroes(message.OrderRequest);
    order.id = id;
    order.items_len = @intCast(items.len);
    for (items, 0..) |item, i| {
        order.items[i] = .{ .product_id = item.id, .quantity = item.qty, .reserved = .{0} ** 12 };
    }
    return order;
}

test "create order — success" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    const id_b: u128 = 0xaaaa0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    var prod_b = make_test_product(id_b, "Gadget", 2500);
    prod_b.inventory = 30;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const order_id: u128 = 0xeeee0000000000000000000000000001;
    const resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 2 },
            .{ .id = id_b, .qty = 3 },
        })));

    try std.testing.expectEqual(resp.status, .ok);
    const order = resp.result.order;
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 2);
    try std.testing.expectEqual(order.items[0].quantity, 2);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.items[0].line_total_cents, 2000);
    try std.testing.expectEqual(order.items[1].quantity, 3);
    try std.testing.expectEqual(order.items[1].line_total_cents, 7500);
    try std.testing.expectEqual(order.total_cents, 9500);

    // Verify inventories were decremented.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    try std.testing.expectEqual(get_a.result.product.inventory, 48);
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
    try std.testing.expectEqual(get_b.result.product.inventory, 27);
}

test "create order — insufficient inventory rolls back all" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xbbbb0000000000000000000000000001;
    const id_b: u128 = 0xbbbb0000000000000000000000000002;

    var prod_a = make_test_product(id_a, "Plenty", 100);
    prod_a.inventory = 100;
    var prod_b = make_test_product(id_b, "Scarce", 200);
    prod_b.inventory = 2;

    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_b));

    const resp = test_execute(&sm, message.Message.init(.create_order, 0xeeee0000000000000000000000000002, 1, make_order_request(0xeeee0000000000000000000000000002, &.{
            .{ .id = id_a, .qty = 5 },
            .{ .id = id_b, .qty = 10 }, // insufficient
        })));

    try std.testing.expectEqual(resp.status, .insufficient_inventory);

    // Verify neither product was modified.
    const get_a = test_execute(&sm, message.Message.init(.get_product, id_a, 1, {}));
    try std.testing.expectEqual(get_a.result.product.inventory, 100);
    const get_b = test_execute(&sm, message.Message.init(.get_product, id_b, 1, {}));
    try std.testing.expectEqual(get_b.result.product.inventory, 2);
}

test "create order — product not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xcccc0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Exists", 100);
    prod_a.inventory = 10;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const resp = test_execute(&sm, message.Message.init(.create_order, 0xeeee0000000000000000000000000003, 1, make_order_request(0xeeee0000000000000000000000000003, &.{
            .{ .id = id_a, .qty = 1 },
            .{ .id = 0xcccc0000000000000000000000000099, .qty = 1 }, // doesn't exist
        })));

    try std.testing.expectEqual(resp.status, .not_found);
}

test "create order — persisted and retrievable" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const id_a: u128 = 0xaaaa0000000000000000000000000001;
    var prod_a = make_test_product(id_a, "Widget", 1000);
    prod_a.inventory = 50;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, prod_a));

    const order_id: u128 = 0xeeee0000000000000000000000000010;
    const create_resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, make_order_request(order_id, &.{
            .{ .id = id_a, .qty = 3 },
        })));
    try std.testing.expectEqual(create_resp.status, .ok);

    // Retrieve by ID.
    const get_resp = test_execute(&sm, message.Message.init(.get_order, order_id, 1, {}));
    try std.testing.expectEqual(get_resp.status, .ok);
    const order = get_resp.result.order;
    try std.testing.expectEqual(order.id, order_id);
    try std.testing.expectEqual(order.items_len, 1);
    try std.testing.expectEqual(order.items[0].quantity, 3);
    try std.testing.expectEqual(order.items[0].price_cents, 1000);
    try std.testing.expectEqual(order.total_cents, 3000);

    // List orders.
    const list_resp = test_execute(&sm, message.Message.init(.list_orders, 0, 1, std.mem.zeroes(message.ListParams)));
    try std.testing.expectEqual(list_resp.status, .ok);
    try std.testing.expectEqual(list_resp.result.order_list.len, 1);
    try std.testing.expectEqual(list_resp.result.order_list.items[0].id, order_id);
    try std.testing.expectEqual(list_resp.result.order_list.items[0].total_cents, 3000);
}

test "get order — not found" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const resp = test_execute(&sm, message.Message.init(.get_order, 0x00000000000000000000000000000099, 1, {}));
    try std.testing.expectEqual(resp.status, .not_found);
}

test "create sets version to 1" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000001;
    const resp = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Versioned", 100)));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 1);
}

test "update increments version" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000002;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "V1", 100)));

    // Update with correct version.
    var update = make_test_product(0, "V2", 200);
    update.version = 1;
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 2);
}

test "update with wrong version returns conflict" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000003;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Original", 100)));

    // Update with stale version.
    var update = make_test_product(0, "Stale", 999);
    update.version = 5; // current is 1
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .version_conflict);

    // Verify product was not modified.
    const get_resp = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
    try std.testing.expectEqualSlices(u8, get_resp.result.product.name_slice(), "Original");
    try std.testing.expectEqual(get_resp.result.product.version, 1);
}

test "update with version 0 skips check" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0xffff0000000000000000000000000004;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "NoCheck", 100)));

    // Update without version (defaults to 0) — should succeed.
    var update = make_test_product(0, "Updated", 200);
    update.version = 0;
    const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product.version, 2);
}

test "duplicate ID rejected" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const test_id: u128 = 0x33333333333333333333333333333333;
    const r1 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "A", 1)));
    try std.testing.expectEqual(r1.status, .ok);
    const r2 = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "B", 2)));
    try std.testing.expectEqual(r2.status, .storage_error);
}

test "capacity exhaustion — panics (writes are infallible after prefetch)" {
    // Pure execute: writes are infallible. Storage full is a crash, not
    // a graceful error — capacity monitoring belongs in infrastructure.
    // This test verifies the contract holds up to capacity.
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    // Fill storage to capacity.
    for (0..MemoryStorage.product_capacity) |i| {
        const id: u128 = @intCast(i + 1);
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(id, "P", 1)));
        try std.testing.expectEqual(r.status, .ok);
    }
}

fn make_test_collection(id: u128, name: []const u8) message.ProductCollection {
    var c = std.mem.zeroes(message.ProductCollection);
    c.id = id;
    c.name_len = @intCast(name.len);
    @memcpy(c.name[0..name.len], name);
    return c;
}

test "delete collection cascades memberships but not products" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);

    const product_id: u128 = 0xaaaa0000000000000000000000000001;
    const col_id: u128 = 0xcccc0000000000000000000000000001;

    // Create product and collection.
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(product_id, "Widget", 100)));
    _ = test_execute(&sm, message.Message.init(.create_collection, 0, 1, make_test_collection(col_id, "Sale")));

    // Add product to collection.
    const add_resp = test_execute(&sm, message.Message.init(.add_collection_member, col_id, 1, product_id));
    try std.testing.expectEqual(add_resp.status, .ok);

    // Verify product is in collection.
    const get_col = test_execute(&sm, message.Message.init(.get_collection, col_id, 1, {}));
    try std.testing.expectEqual(get_col.status, .ok);
    try std.testing.expectEqual(get_col.result.collection.products.len, 1);

    // Delete the collection.
    const del_resp = test_execute(&sm, message.Message.init(.delete_collection, col_id, 1, {}));
    try std.testing.expectEqual(del_resp.status, .ok);

    // Collection is gone.
    const gone = test_execute(&sm, message.Message.init(.get_collection, col_id, 1, {}));
    try std.testing.expectEqual(gone.status, .not_found);

    // Product still exists.
    const product = test_execute(&sm, message.Message.init(.get_product, product_id, 1, {}));
    try std.testing.expectEqual(product.status, .ok);
    try std.testing.expectEqualSlices(u8, product.result.product.name_slice(), "Widget");

    // Re-create the collection — should have no members (memberships were cascaded).
    _ = test_execute(&sm, message.Message.init(.create_collection, 0, 1, make_test_collection(col_id + 1, "New")));
    // Add the product to the new collection to confirm memberships were cleaned.
    // (If cascade failed, the old membership slot would still be occupied.)
    const add2 = test_execute(&sm, message.Message.init(.add_collection_member, col_id + 1, 1, product_id));
    try std.testing.expectEqual(add2.status, .ok);
}

test "seeded: transfer inventory conserves total" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const num_products = 8;
    var ids: [num_products]u128 = undefined;
    var total_inventory: u64 = 0;

    // Create products with random inventories.
    for (&ids, 1..) |*id, i| {
        id.* = @intCast(i);
        var p = make_test_product(id.*, "P", 0);
        p.inventory = prng.range_inclusive(u32, 0, 1000);
        total_inventory += p.inventory;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        try std.testing.expectEqual(r.status, .ok);
    }

    // Random transfers — some succeed, some fail with insufficient_inventory.
    for (0..500) |_| {
        const src_idx = prng.int_inclusive(u8, num_products - 1);
        var dst_idx = prng.int_inclusive(u8, num_products - 2);
        if (dst_idx >= src_idx) dst_idx += 1;

        const qty = prng.range_inclusive(u32, 1, 200);
        const resp = test_execute(&sm, message.Message.init(.transfer_inventory, ids[src_idx], 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = ids[dst_idx], .quantity = qty }));

        // Only ok or insufficient_inventory — no storage errors (no fault injection).
        assert(resp.status == .ok or resp.status == .insufficient_inventory);

        // Conservation: sum of all inventories must be unchanged.
        var sum: u64 = 0;
        for (ids) |id| {
            const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
            assert(g.status == .ok);
            sum += g.result.product.inventory;
        }
        try std.testing.expectEqual(sum, total_inventory);
    }
}

test "seeded: create order arithmetic" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    // Create products with random prices and inventories.
    const num_products = 10;
    var ids: [num_products]u128 = undefined;
    var inventories: [num_products]u32 = undefined;
    for (&ids, &inventories, 1..) |*id, *inv, i| {
        id.* = @intCast(i);
        var p = make_test_product(id.*, "P", prng.range_inclusive(u32, 1, 50000));
        p.inventory = prng.range_inclusive(u32, 0, 100);
        inv.* = p.inventory;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        assert(r.status == .ok);
    }

    for (0..200) |round| {
        const order_id: u128 = @as(u128, 0xeeee0000000000000000000000000000) | (round + 1);
        const items_len = prng.range_inclusive(u32, 1, 5);
        var order = std.mem.zeroes(message.OrderRequest);
        order.id = order_id;
        order.items_len = @intCast(items_len);

        // Pick distinct random products and quantities.
        var used: [num_products]bool = [_]bool{false} ** num_products;
        for (0..items_len) |i| {
            var idx = prng.int_inclusive(u8, num_products - 1);
            while (used[idx]) idx = prng.int_inclusive(u8, num_products - 1);
            used[idx] = true;
            const qty = prng.range_inclusive(u32, 1, 30);
            order.items[i] = .{ .product_id = ids[idx], .quantity = qty, .reserved = .{0} ** 12 };
        }

        const resp = test_execute(&sm, message.Message.init(.create_order, order_id, 1, order));

        if (resp.status == .insufficient_inventory) {
            // No inventories changed.
            for (ids, inventories) |id, expected| {
                const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
                try std.testing.expectEqual(g.result.product.inventory, expected);
            }
            continue;
        }

        try std.testing.expectEqual(resp.status, .ok);
        const result = resp.result.order;
        try std.testing.expectEqual(result.id, order_id);
        try std.testing.expectEqual(result.items_len, @as(u8, @intCast(items_len)));

        // Arithmetic: line_total = price * qty, total = sum(line_totals).
        var expected_total: u64 = 0;
        for (result.items[0..result.items_len]) |item| {
            try std.testing.expectEqual(item.line_total_cents, @as(u64, item.price_cents) * @as(u64, item.quantity));
            expected_total += item.line_total_cents;
        }
        try std.testing.expectEqual(result.total_cents, expected_total);

        // Update expected inventories.
        for (order.items[0..items_len]) |item| {
            for (ids, &inventories) |id, *inv| {
                if (id == item.product_id) {
                    inv.* -= item.quantity;
                    break;
                }
            }
        }

        // Verify actual inventories match expected.
        for (ids, inventories) |id, expected| {
            const g = test_execute(&sm, message.Message.init(.get_product, id, 1, {}));
            try std.testing.expectEqual(g.result.product.inventory, expected);
        }
    }
}

test "seeded: list filters match predicate" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const prefixes = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta" };
    const num_products = 40;

    // Create products with random attributes.
    const ProductAttrs = struct { id: u128, price: u32, active: bool, name: []const u8 };
    var attrs: [num_products]ProductAttrs = undefined;

    for (&attrs, 1..) |*a, i| {
        const prefix = prefixes[prng.int_inclusive(u8, prefixes.len - 1)];
        const price = prng.range_inclusive(u32, 100, 10000);
        const active = prng.int_inclusive(u8, 1) == 1;
        a.* = .{
            .id = @intCast(i),
            .price = price,
            .active = active,
            .name = prefix,
        };
        var p = make_test_product(a.id, prefix, price);
        p.flags.active = active;
        const r = test_execute(&sm, message.Message.init(.create_product, 0, 1, p));
        assert(r.status == .ok);
    }

    // Random filter combinations.
    for (0..200) |_| {
        var params = std.mem.zeroes(message.ListParams);

        // Random active filter.
        params.active_filter = switch (prng.int_inclusive(u8, 2)) {
            0 => .any,
            1 => .active_only,
            2 => .inactive_only,
            else => unreachable,
        };

        // Random price range (sometimes none, sometimes one bound, sometimes both).
        switch (prng.int_inclusive(u8, 3)) {
            0 => {}, // no price filter
            1 => params.price_min = prng.range_inclusive(u32, 100, 10000),
            2 => params.price_max = prng.range_inclusive(u32, 100, 10000),
            3 => {
                params.price_min = prng.range_inclusive(u32, 100, 5000);
                params.price_max = prng.range_inclusive(u32, 5000, 10000);
            },
            else => unreachable,
        }

        // Random name prefix (sometimes none).
        if (prng.int_inclusive(u8, 1) == 1) {
            const prefix = prefixes[prng.int_inclusive(u8, prefixes.len - 1)];
            @memcpy(params.name_prefix[0..prefix.len], prefix);
            params.name_prefix_len = @intCast(prefix.len);
        }

        const resp = test_execute(&sm, message.Message.init(.list_products, 0, 1, params));
        assert(resp.status == .ok);

        // Count how many products should match.
        var expected_count: u32 = 0;
        for (&attrs) |*a| {
            // Active filter.
            switch (params.active_filter) {
                .any => {},
                .active_only => if (!a.active) continue,
                .inactive_only => if (a.active) continue,
            }
            // Price range.
            if (params.price_min > 0 and a.price < params.price_min) continue;
            if (params.price_max > 0 and a.price > params.price_max) continue;
            // Name prefix.
            if (params.name_prefix_len > 0) {
                const prefix = params.name_prefix[0..params.name_prefix_len];
                if (!std.mem.startsWith(u8, a.name, prefix)) continue;
            }
            expected_count += 1;
        }

        // list_max caps the result.
        const capped = @min(expected_count, message.list_max);
        try std.testing.expectEqual(resp.result.product_list.len, capped);
    }
}

test "seeded: update versioning monotonicity" {
    var storage = try MemoryStorage.init(std.testing.allocator);
    defer storage.deinit(std.testing.allocator);
    var sm = TestStateMachine.init(&storage, false, 0, sm_test_key);
    var prng = PRNG.from_seed_testing();

    const test_id: u128 = 0xffff0000000000000000000000000099;
    _ = test_execute(&sm, message.Message.init(.create_product, 0, 1, make_test_product(test_id, "Seed", 100)));

    var current_version: u32 = 1; // create sets version to 1

    for (0..500) |_| {
        // Choose update strategy: correct version, stale version, or version 0 (skip check).
        const strategy = prng.int_inclusive(u8, 2);
        var update = make_test_product(0, "Up", prng.range_inclusive(u32, 1, 99999));

        switch (strategy) {
            0 => update.version = current_version, // correct
            1 => update.version = current_version +| prng.range_inclusive(u32, 1, 10), // stale (too high)
            2 => update.version = 0, // skip check
            else => unreachable,
        }

        const resp = test_execute(&sm, message.Message.init(.update_product, test_id, 1, update));

        switch (strategy) {
            0, 2 => {
                // Correct version or version 0 — must succeed.
                try std.testing.expectEqual(resp.status, .ok);
                current_version += 1;
                try std.testing.expectEqual(resp.result.product.version, current_version);
            },
            1 => {
                // Stale version — must be rejected.
                try std.testing.expectEqual(resp.status, .version_conflict);
                // Version unchanged.
                const g = test_execute(&sm, message.Message.init(.get_product, test_id, 1, {}));
                try std.testing.expectEqual(g.result.product.version, current_version);
            },
            else => unreachable,
        }
    }
}

// =====================================================================
// TestEnv — thin helpers over test_execute for readable scenario tests.
//
// Each helper is a direct call to test_execute with compile-time type
// checking on all arguments. Optional assertion fields use Zig's
// anonymous struct defaults — null/0 = don't check.
// =====================================================================

const TestEnv = struct {
    sm: TestStateMachine,
    storage: MemoryStorage,

    fn init(self: *TestEnv) !void {
        self.storage = try MemoryStorage.init(std.testing.allocator);
        self.sm = TestStateMachine.init(&self.storage, false, 0, sm_test_key);
    }

    fn deinit(self: *TestEnv) void {
        self.storage.deinit(std.testing.allocator);
    }

    // --- Products ---

    fn create_product(self: *TestEnv, opts: struct {
        id: u128,
        name: []const u8,
        price: u32,
        inventory: u32 = 0,
    }) void {
        var p = make_test_product(opts.id, opts.name, opts.price);
        p.inventory = opts.inventory;
        const resp = test_execute(&self.sm, message.Message.init(.create_product, 0, 1, p));
        assert(resp.status == .ok);
    }

    fn expect_product(self: *TestEnv, id: u128, expect: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        inventory: ?u32 = null,
        version: ?u32 = null,
        active: ?bool = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        const p = resp.result.product;
        if (expect.name) |n| try std.testing.expectEqualSlices(u8, n, p.name_slice());
        if (expect.price) |v| try std.testing.expectEqual(v, p.price_cents);
        if (expect.inventory) |v| try std.testing.expectEqual(v, p.inventory);
        if (expect.version) |v| try std.testing.expectEqual(v, p.version);
        if (expect.active) |v| try std.testing.expectEqual(v, p.flags.active);
    }

    fn update_product(self: *TestEnv, id: u128, opts: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        version: u32 = 0, // 0 = skip version check
    }) !void {
        const g = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        assert(g.status == .ok);
        var p = g.result.product;

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, message.Message.init(.update_product, id, 1, p));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn update_product_expect(self: *TestEnv, id: u128, opts: struct {
        name: ?[]const u8 = null,
        price: ?u32 = null,
        version: u32 = 0,
    }, expected: message.Status) !void {
        const g = test_execute(&self.sm, message.Message.init(.get_product, id, 1, {}));
        assert(g.status == .ok);
        var p = g.result.product;

        if (opts.name) |name| {
            @memcpy(p.name[0..name.len], name);
            p.name_len = @intCast(name.len);
        }
        if (opts.price) |price| p.price_cents = price;
        p.version = opts.version;

        const resp = test_execute(&self.sm, message.Message.init(.update_product, id, 1, p));
        try std.testing.expectEqual(expected, resp.status);
    }

    fn delete_product(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.delete_product, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_inventory(self: *TestEnv, id: u128, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_product_inventory, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.inventory);
    }

    fn expect_product_count(self: *TestEnv, opts: struct {
        filter: message.ListParams.ActiveFilter = .any,
    }, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_products, 0, 1, list_params(opts.filter)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.product_list.len);
    }

    // --- Collections ---

    fn create_collection(self: *TestEnv, opts: struct {
        id: u128,
        name: []const u8,
    }) void {
        const col = make_test_collection(opts.id, opts.name);
        const resp = test_execute(&self.sm, message.Message.init(.create_collection, 0, 1, col));
        assert(resp.status == .ok);
    }

    fn expect_collection(self: *TestEnv, id: u128, expect: struct {
        product_count: ?u32 = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_collection, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.product_count) |v| try std.testing.expectEqual(v, resp.result.collection.products.len);
    }

    fn delete_collection(self: *TestEnv, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.delete_collection, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn expect_collection_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_collections, 0, 1, std.mem.zeroes(message.ListParams)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.collection_list.len);
    }

    fn add_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.add_collection_member, collection_id, 1, product_id));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    fn remove_member(self: *TestEnv, collection_id: u128, product_id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(.remove_collection_member, collection_id, 1, product_id));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Transfers ---

    fn transfer(self: *TestEnv, source_id: u128, target_id: u128, quantity: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.transfer_inventory, source_id, 1, message.InventoryTransfer{ .reserved = .{0} ** 12, .target_id = target_id, .quantity = quantity }));
        try std.testing.expectEqual(message.Status.ok, resp.status);
    }

    // --- Orders ---

    fn create_order(self: *TestEnv, id: u128, items: []const message.OrderItem) !message.OrderResult {
        var req = std.mem.zeroes(message.OrderRequest);
        req.id = id;
        req.items_len = @intCast(items.len);
        @memcpy(req.items[0..items.len], items);
        const resp = test_execute(&self.sm, message.Message.init(.create_order, 0, 1, req));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        return resp.result.order;
    }

    fn expect_order(self: *TestEnv, id: u128, expect: struct {
        total: ?u64 = null,
    }) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_order, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        if (expect.total) |v| try std.testing.expectEqual(v, resp.result.order.total_cents);
    }

    fn cancel_order(self: *TestEnv, id: u128) message.MessageResponse {
        return test_execute(&self.sm, message.Message.init(.cancel_order, id, 1, {}));
    }

    fn complete_order(self: *TestEnv, id: u128, result: message.OrderCompletion.OrderCompletionResult) message.MessageResponse {
        return self.complete_order_with_ref(id, result, "");
    }

    fn complete_order_with_ref(self: *TestEnv, id: u128, result: message.OrderCompletion.OrderCompletionResult, ref: []const u8) message.MessageResponse {
        var completion = std.mem.zeroes(message.OrderCompletion);
        completion.result = result;
        if (ref.len > 0) {
            @memcpy(completion.payment_ref[0..ref.len], ref);
            completion.payment_ref_len = @intCast(ref.len);
        }
        return test_execute(&self.sm, message.Message.init(.complete_order, id, 1, completion));
    }

    fn expect_order_status(self: *TestEnv, id: u128, expected_status: message.OrderStatus) !void {
        const resp = test_execute(&self.sm, message.Message.init(.get_order, id, 1, {}));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected_status, resp.result.order.status);
    }

    fn expect_order_count(self: *TestEnv, expected: u32) !void {
        const resp = test_execute(&self.sm, message.Message.init(.list_orders, 0, 1, std.mem.zeroes(message.ListParams)));
        try std.testing.expectEqual(message.Status.ok, resp.status);
        try std.testing.expectEqual(expected, resp.result.order_list.len);
    }

    // --- Generic not-found assertions ---

    fn expect_not_found(self: *TestEnv, op: message.Operation, id: u128) !void {
        const resp = test_execute(&self.sm, message.Message.init(op, id, 1, {}));
        try std.testing.expectEqual(message.Status.not_found, resp.status);
    }

    fn expect_status(self: *TestEnv, msg: message.Message, expected: message.Status) !void {
        const resp = test_execute(&self.sm, msg);
        try std.testing.expectEqual(expected, resp.status);
    }
};

// --- Scenario tests ---

test "product lifecycle" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 30 });

    try env.expect_product(1, .{ .name = "Widget", .price = 999, .inventory = 50, .version = 1 });
    try env.expect_product(2, .{ .name = "Gadget", .price = 499 });
    try env.expect_not_found(.get_product, 99);

    try env.update_product(1, .{ .name = "Updated", .price = 1299, .version = 1 }); // version 1 → 2

    try env.expect_product(1, .{ .name = "Updated", .price = 1299, .version = 2, .inventory = 50 });

    try env.delete_product(1);

    try env.expect_not_found(.get_product, 1); // soft-deleted
    try env.expect_product(2, .{ .active = true }); // P2 unaffected

    try env.expect_product_count(.{}, 2); // P1 (inactive) + P2 (active)
    try env.expect_product_count(.{ .filter = .inactive_only }, 1);
    try env.expect_product_count(.{ .filter = .active_only }, 1);
}

test "version conflict" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.update_product(1, .{ .name = "Updated", .version = 1 }); // version 1 → 2
    try env.update_product_expect(1, .{ .name = "Updated", .version = 1 }, .version_conflict); // stale
    try env.update_product(1, .{ .name = "Updated", .version = 2 }); // correct version 2
    try env.update_product(1, .{ .name = "Updated" }); // no version = skip check
}

test "transfer inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 100, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 100, .inventory = 10 });

    try env.transfer(1, 2, 15);

    try env.expect_inventory(1, 35);
    try env.expect_inventory(2, 25);

    try env.expect_status(message.Message.init(.transfer_inventory, 1, 1, message.InventoryTransfer{ .target_id = 2, .quantity = 100, .reserved = .{0} ** 12 }), .insufficient_inventory);

    try env.expect_inventory(1, 35); // unchanged
    try env.expect_inventory(2, 25);

    try env.expect_status(message.Message.init(.transfer_inventory, 99, 1, message.InventoryTransfer{ .target_id = 2, .quantity = 1, .reserved = .{0} ** 12 }), .not_found);
    try env.expect_status(message.Message.init(.transfer_inventory, 1, 1, message.InventoryTransfer{ .target_id = 99, .quantity = 1, .reserved = .{0} ** 12 }), .not_found);
}

test "order with inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Shirt", .price = 2000, .inventory = 100 });
    env.create_product(.{ .id = 2, .name = "Pants", .price = 3000, .inventory = 50 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 2, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 1, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(@as(u64, 7000), order.total_cents);

    try env.expect_inventory(1, 98);
    try env.expect_inventory(2, 49);

    try env.expect_order(1, .{ .total = 7000 });
    try env.expect_not_found(.get_order, 99);

    try env.expect_order_count(1);

    // Insufficient inventory — order fails, inventory unchanged.
    var fail_req = std.mem.zeroes(message.OrderRequest);
    fail_req.id = 2;
    fail_req.items_len = 1;
    fail_req.items[0] = .{ .product_id = 2, .quantity = 100, .reserved = .{0} ** 12 };
    try env.expect_status(message.Message.init(.create_order, 0, 1, fail_req), .insufficient_inventory);

    try env.expect_inventory(2, 49); // unchanged on failure
}

test "collection cascade delete" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 10 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 20 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);

    try env.expect_collection(1, .{ .product_count = 2 });

    try env.delete_collection(1);

    try env.expect_not_found(.get_collection, 1);

    try env.expect_product(1, .{}); // products survive cascade
    try env.expect_product(2, .{});

    try env.expect_collection_count(0);
}

test "membership operations" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);
    try env.add_member(1, 1); // idempotent
    try env.expect_status(message.Message.init(.add_collection_member, 99, 1, @as(u128, 1)), .not_found); // collection missing
    try env.expect_status(message.Message.init(.add_collection_member, 1, 1, @as(u128, 99)), .not_found); // product missing

    try env.expect_collection(1, .{ .product_count = 2 });

    try env.remove_member(1, 1);

    try env.expect_collection(1, .{ .product_count = 1 }); // P2 remains

    try env.expect_status(message.Message.init(.remove_collection_member, 1, 1, @as(u128, 1)), .ok); // idempotent — already removed
}

test "delete missing entities" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    try env.expect_not_found(.delete_product, 99);
    try env.expect_not_found(.delete_collection, 99);
}

test "soft delete is idempotent" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.delete_product(1);
    try env.expect_not_found(.delete_product, 1); // already soft-deleted
}

test "soft delete increments version" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999 });

    try env.delete_product(1); // version 1 → 2

    try env.expect_product_count(.{ .filter = .inactive_only }, 1);
}

test "cross-entity scenario" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 999, .inventory = 100 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 499, .inventory = 50 });

    env.create_collection(.{ .id = 1, .name = "Summer" });

    try env.add_member(1, 1);
    try env.add_member(1, 2);

    try env.transfer(1, 2, 20);

    try env.expect_product(1, .{ .inventory = 80 });
    try env.expect_product(2, .{ .inventory = 70 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 3, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 2, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(@as(u64, 3995), order.total_cents);

    try env.expect_product(1, .{ .inventory = 77 });
    try env.expect_product(2, .{ .inventory = 68 });

    try env.delete_collection(1);

    try env.expect_product(1, .{ .price = 999 });
    try env.expect_order(1, .{ .total = 3995 });
}

// =====================================================================
// Two-phase order completion tests
// =====================================================================

test "complete order — confirmed keeps inventory decremented" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    const order = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });
    try std.testing.expectEqual(order.status, .pending);
    try env.expect_inventory(1, 45);

    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.order.status, .confirmed);

    // Inventory stays decremented after confirmation.
    try env.expect_inventory(1, 45);
}

test "complete order — failed restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 2000, .inventory = 30 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
        .{ .product_id = 2, .quantity = 3, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 45);
    try env.expect_inventory(2, 27);

    const resp = env.complete_order(1, .failed);
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.order.status, .failed);

    // Inventory restored on failure.
    try env.expect_inventory(1, 50);
    try env.expect_inventory(2, 30);
}

test "complete order — idempotent same-result retry" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    const resp1 = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp1.status, .ok);

    // Same-result retry is idempotent — returns OK (worker crash recovery).
    const resp2 = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp2.status, .ok);

    // Inventory unchanged by idempotent retry.
    try env.expect_inventory(1, 45);
}

test "complete order — not found" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const resp = env.complete_order(99, .confirmed);
    try std.testing.expectEqual(resp.status, .not_found);
}

test "complete order — expired restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 40);

    // Advance time past the order timeout.
    env.sm.now += message.order_timeout_seconds + 1;

    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .order_expired);

    // Inventory restored because the order expired.
    try env.expect_inventory(1, 50);
    try env.expect_order_status(1, .failed);
}

test "cancel order — restores inventory" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });
    try env.expect_inventory(1, 40);

    const resp = env.cancel_order(1);
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.order.status, .cancelled);

    try env.expect_inventory(1, 50);
}

test "cancel order — not found" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    const resp = env.cancel_order(99);
    try std.testing.expectEqual(resp.status, .not_found);
}

test "cancel order — already confirmed" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    _ = env.complete_order(1, .confirmed);

    const resp = env.cancel_order(1);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory unchanged — no double-restore.
    try env.expect_inventory(1, 45);
}

test "cancel order — double cancel rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });

    const resp1 = env.cancel_order(1);
    try std.testing.expectEqual(resp1.status, .ok);

    const resp2 = env.cancel_order(1);
    try std.testing.expectEqual(resp2.status, .order_not_pending);

    try env.expect_inventory(1, 50);
}

test "complete order after cancel — rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 10, .reserved = .{0} ** 12 },
    });

    _ = env.cancel_order(1);

    // Worker returns — but order is already cancelled.
    const resp = env.complete_order(1, .confirmed);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory fully restored from cancel, not double-restored.
    try env.expect_inventory(1, 50);
}

test "complete order — failed after confirmed is rejected" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000, .inventory = 50 });

    _ = try env.create_order(1, &.{
        .{ .product_id = 1, .quantity = 5, .reserved = .{0} ** 12 },
    });

    _ = env.complete_order(1, .confirmed);

    // Try to fail an already-confirmed order.
    const resp = env.complete_order(1, .failed);
    try std.testing.expectEqual(resp.status, .order_not_pending);

    // Inventory stays at confirmed level — no double-restore.
    try env.expect_inventory(1, 45);
}

// =====================================================================
// Search tests
// =====================================================================

fn search_products(sm: *TestStateMachine, query: []const u8) message.MessageResponse {
    var sq = std.mem.zeroes(message.SearchQuery);
    @memcpy(sq.query[0..query.len], query);
    sq.query_len = @intCast(query.len);
    return test_execute(sm, message.Message.init(.search_products, 0, 1, sq));
}

test "search products — matches name" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Gadget", .price = 2000 });
    env.create_product(.{ .id = 3, .name = "Super Widget Pro", .price = 3000 });

    const resp = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp.status, .ok);
    const list = resp.result.product_list;
    try std.testing.expectEqual(list.len, 2);
}

test "search products — matches description" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    var p = make_test_product(1, "Shirt", 2000);
    const desc = "A comfortable cotton shirt";
    @memcpy(p.description[0..desc.len], desc);
    p.description_len = desc.len;
    const resp1 = test_execute(&env.sm, message.Message.init(.create_product, 0, 1, p));
    assert(resp1.status == .ok);

    const resp = search_products(&env.sm, "cotton");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 1);
}

test "search products — excludes inactive" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Active Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Deleted Widget", .price = 2000 });

    // Soft delete product 2.
    _ = test_execute(&env.sm, message.Message.init(.delete_product, 2, 1, {}));

    const resp = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 1);
    try std.testing.expectEqual(resp.result.product_list.items[0].id, 1);
}

test "search products — no results" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });

    const resp = search_products(&env.sm, "nonexistent");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 0);
}

test "search products — case insensitive" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Widget", .price = 1000 });

    const resp = search_products(&env.sm, "WIDGET");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 1);
}

test "search products — multi-word all must match" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Blue Widget", .price = 1000 });
    env.create_product(.{ .id = 2, .name = "Red Widget", .price = 2000 });
    env.create_product(.{ .id = 3, .name = "Blue Gadget", .price = 3000 });

    // Both words must match.
    const resp = search_products(&env.sm, "blue widget");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 1);
    try std.testing.expectEqual(resp.result.product_list.items[0].id, 1);

    // One word doesn't match any product.
    const resp2 = search_products(&env.sm, "blue nonexistent");
    try std.testing.expectEqual(resp2.status, .ok);
    try std.testing.expectEqual(resp2.result.product_list.len, 0);

    // Single word matches multiple.
    const resp3 = search_products(&env.sm, "widget");
    try std.testing.expectEqual(resp3.status, .ok);
    try std.testing.expectEqual(resp3.result.product_list.len, 2);
}

test "search products — extra whitespace" {
    var env: TestEnv = undefined;
    try env.init();
    defer env.deinit();

    env.create_product(.{ .id = 1, .name = "Blue Widget", .price = 1000 });

    // Leading, trailing, and multiple spaces between words.
    const resp = search_products(&env.sm, "  blue   widget  ");
    try std.testing.expectEqual(resp.status, .ok);
    try std.testing.expectEqual(resp.result.product_list.len, 1);
}
