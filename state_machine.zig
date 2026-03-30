const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const message = @import("message.zig");
const auth = @import("framework/auth.zig");
const TracerType = @import("framework/tracer.zig").TracerType;
const Tracer = TracerType(message.Operation, message.Status);
const marks = @import("framework/marks.zig");
const log = marks.wrap_log(std.log.scoped(.state_machine));
const PRNG = @import("stdx").PRNG;

/// Storage result — the availability contract between framework and database.
///
/// This is NOT a domain result. It answers "did the storage cooperate?" not
/// "was the business logic correct?" Domain outcomes (insufficient inventory,
/// duplicate email, invalid state transition) are expressed in handler return
/// values, not storage results.
///
/// Both production and test builds use SqliteStorage (with :memory: for tests).
/// Fault injection is at the prefetch dispatch level (app.zig), not storage.
pub const StorageResult = enum { ok, not_found, err, busy, corruption };

/// State machine parameterized on a Storage backend.
/// Storage is SqliteStorage — production uses a file, tests use :memory:.
///
/// Request processing is split into two phases (TigerBeetle style):
/// - `prefetch(msg)` reads from storage into cache slots. Read-only — never mutates
///   storage. Returns false if storage is busy (retry next tick).
/// - `execute(msg)` decides from cache slots, then writes mutations to storage.
/// State machine parameterized on Storage and Handlers.
///
/// Storage is the database backend (SqliteStorage).
/// Handlers is the App's dispatch interface — it provides:
///   - Cache: tagged union of all handler Prefetch types
///   - handler_prefetch(storage, msg) → ?Cache
///   - handler_execute(cache, msg, fw, db) → HandleResult
///
/// The SM owns the pipeline (auth, transactions, tracer, invariants).
/// Handlers own the business logic. The SM never imports App — Handlers
/// is passed as a comptime parameter. Clean one-way dependency.

/// Handler's decision — status + optional session action.
/// Session action moves to writes in a future phase; until then,
/// only logout.zig sets it. All other handlers return bare status.
pub const HandleResult = struct {
    status: message.Status = .ok,
    session_action: message.SessionAction = .none,
};

/// Used by the fuzzer to filter random messages before calling prefetch/commit.
pub fn input_valid(msg: message.Message) bool {
    switch (msg.operation) {
        .root => return false,
        .create_product => {
            const p = msg.body_as(message.Product);
            if (p.id == 0) return false;
            // msg.id must agree with body ID or be 0.
            // Route sets msg.id = body.id. Tests may set msg.id = 0.
            // Disagreement (msg.id = X, body.id = Y, X != Y) is invalid.
            if (msg.id != 0 and msg.id != p.id) return false;
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
            if (msg.id != 0 and msg.id != col.id) return false;
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
            if (msg.id != 0 and msg.id != order.id) return false;
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
    @import("framework/read_only_storage.zig").assertReadView(Storage);

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

        /// WAL recording: if set, commit() records SQL writes into this buffer.
        /// The server sets this before process_inbox and reads wal_record_len
        /// after commit to get the recorded data for wal.append_writes().
        wal_record_buf: ?[]u8 = null,
        wal_record_len: usize = 0,
        wal_record_count: u8 = 0,

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
        pub const PrefetchResult = enum {
            complete, // Prefetch done — proceed to commit.
            busy,     // Storage busy — retry next tick.
            pending,  // Sidecar CALL in-flight — process_sidecar drives completion.
        };

        /// Start prefetch. Returns .complete (proceed), .busy (retry),
        /// or .pending (sidecar CALL sent, result arrives via on_recv).
        pub fn prefetch(self: *StateMachine, msg: message.Message) PrefetchResult {
            assert(self.prefetch_cache == null);

            // Auth: resolve cookie credential → identity.
            self.resolve_credential(msg);

            self.prefetch_cache = Handlers.handler_prefetch(self.storage, &msg);
            if (self.prefetch_cache != null) return .complete;

            // Null means busy OR sidecar pending. Side-channel check:
            // handler_prefetch returned null but the sidecar client has an
            // in-flight CALL — the prefetch is pending, not busy.
            // TODO: handler_prefetch should return a tagged type (complete/
            // busy/pending) instead of ?Cache + side-channel. Requires
            // changing the Handlers interface — deferred to scanner refactor.
            if (Handlers.is_sidecar_pending()) return .pending;
            return .busy;
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
        /// Cross-cutting concerns (auth, tracer) handled here so
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
        };

        /// Commit output — pipeline response + cache for render.
        /// The SM's job ends here. Cache ownership transfers to the caller
        /// so render can access prefetched data post-commit.
        pub const CommitOutput = struct {
            response: PipelineResponse,
            cache: Handlers.Cache,
            identity: message.PrefetchIdentity,
        };

        /// Phase 2: commit — returns CommitOutput (response + cache for render).
        /// The handler's domain data stays in the cache for the render phase.
        pub fn commit(self: *StateMachine, msg: message.Message) CommitOutput {
            const cache = self.prefetch_cache.?;
            defer self.prefetch_cache = null;
            defer self.prefetch_identity = null;

            const fw = Handlers.FwCtx{
                .identity = self.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity),
                .now = self.now,
                .is_sse = false, // Set by server when render is wired.
            };

            // Handle writes directly to storage. The transaction is
            // managed by begin_batch/commit_batch at the server level —
            // all writes in a tick share one transaction.
            var write_view = if (self.wal_record_buf) |buf|
                Storage.WriteView.init_recording(self.storage, buf)
            else
                Storage.WriteView.init(self.storage);
            const handle_result = Handlers.handler_execute(
                cache,
                msg,
                fw,
                &write_view,
            );
            // Store recording output for the server's WAL append.
            self.wal_record_len = write_view.record_pos;
            self.wal_record_count = write_view.record_count;

            const identity = self.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity);
            const is_auth = identity.is_authenticated != 0 or
                handle_result.session_action == .set_authenticated;

            const resp = PipelineResponse{
                .status = handle_result.status,
                .session_action = handle_result.session_action,
                .user_id = identity.user_id,
                .is_authenticated = is_auth,
                .is_new_visitor = identity.is_new != 0,
            };

            self.tracer.count_status(resp.status);
            return .{
                .response = resp,
                .cache = cache,
                .identity = self.prefetch_identity orelse std.mem.zeroes(message.PrefetchIdentity),
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

    };
}


