const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx");
const message = @import("message.zig");
const auth = @import("framework/auth.zig");
// Tracer removed from SM — owned by server. See framework/trace.zig.
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

/// Handler's decision — status + optional session action.
/// Session action moves to writes in a future phase; until then,
/// only logout.zig sets it. All other handlers return bare status.
///
/// Defined here (not in handlers) because it's the interface contract
/// between framework and handlers. Both native and sidecar handlers
/// return this type.
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

/// State machine — framework services for the request pipeline.
///
/// Owns auth (credential resolution), transactions (begin/commit batch),
/// storage pointer, tracer, and PRNG.
///
/// Does NOT own handlers or per-request state. Those live per-slot on
/// the server. This separation is load-bearing:
///   - Handlers are per-slot so concurrent slots don't share state.
///   - Per-request state (cache, identity) lives on PipelineSlot so
///     slot.* = .{} resets everything.
///   - Adding a handlers field here would re-introduce the pointer-
///     swapping bug (one handler instance shared across slots).
///   - Adding per-request fields here would break concurrent dispatch
///     (prefetch on slot 0 clobbers slot 1's cache).
pub fn StateMachineType(comptime Storage: type) type {
    // Storage must define its own read/write split.
    @import("framework/read_only_storage.zig").assertReadView(Storage);

    return struct {
        const StateMachine = @This();

        storage: *Storage,
        prng: PRNG,
        secret_key: *const [auth.key_length]u8,

        /// Wall-clock time (seconds since epoch). Set by the server before
        /// each process_inbox call. Used for order timeout_at.
        now: i64,

        pub fn init(storage: *Storage, prng_seed: u64, secret_key: *const [auth.key_length]u8) StateMachine {
            return .{
                .storage = storage,
                .prng = PRNG.from_seed(prng_seed),
                .secret_key = secret_key,
                .now = 0,
            };
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

        /// Resolve cookie credential → identity. Cross-cutting auth concern
        /// owned by the SM, not the handlers. Returns the identity — caller
        /// stores it per-slot.
        pub fn resolve_credential(self: *StateMachine, msg: message.Message) message.PrefetchIdentity {
            if (msg.credential_slice()) |cv| {
                if (auth.verify_cookie(cv, self.secret_key)) |verified| {
                    return .{
                        .user_id = verified.user_id,
                        .kind = @enumFromInt(@intFromEnum(verified.kind)),
                        .is_authenticated = @intFromBool(verified.kind == .authenticated),
                        .is_new = 0,
                        .reserved = .{0} ** 13,
                    };
                }
            }
            // No credential or invalid — mint a new anonymous identity.
            const user_id = mint_user_id(&self.prng);
            return .{
                .user_id = user_id,
                .kind = .anonymous,
                .is_authenticated = 0,
                .is_new = 1,
                .reserved = .{0} ** 13,
            };
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
