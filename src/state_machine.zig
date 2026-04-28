const std = @import("std");
const assert = std.debug.assert;
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

/// Validate a message's body for a given operation. Dispatches to the
/// handler's `input_valid` function if it exports one, otherwise returns true.
/// Used by the fuzzer to filter random messages before calling prefetch/commit.
pub fn input_valid(msg: message.Message) bool {
    const handlers = @import("generated/handlers.generated.zig");
    return switch (msg.operation) {
        .root => false,
        inline else => |comptime_op| {
            const H = comptime handlers.HandlerModule(comptime_op);
            if (H == void) return true; // sidecar-only — no native validation
            if (@hasDecl(H, "input_valid")) return H.input_valid(msg);
            return true; // no custom validation
        },
    };
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
