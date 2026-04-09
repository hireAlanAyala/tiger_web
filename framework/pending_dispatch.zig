//! In-memory pending dispatch index — tracks unresolved worker dispatches.
//!
//! Rebuilt from WAL on startup. Updated on dispatch commit, completion
//! commit, and dead-dispatch resolution. Bounded by max_in_flight_workers
//! (comptime constant, static allocation).
//!
//! The WAL is the source of truth. This index is derived state — it can
//! always be rebuilt by replaying the WAL. The server owns the index;
//! the WAL populates it during recovery.

const std = @import("std");
const assert = std.debug.assert;
const constants = @import("constants.zig");

pub const PendingDispatch = struct {
    op: u64, // WAL op that recorded this dispatch
    operation: u8, // Operation enum value that created this dispatch
    name: [constants.worker_name_max]u8, // worker name (ASCII)
    name_len: u8, // length of name
    args: [constants.worker_args_max]u8, // serialized args (opaque)
    args_len: u16, // length of args
    dispatched_at: i64, // timestamp from WAL entry
    state: State,

    pub const State = enum(u8) {
        pending = 0, // dispatch recorded, no completion
        in_flight = 1, // CALL sent to sidecar, awaiting RESULT
        completed = 2, // completion entry committed
        failed = 3, // completion entry committed (worker_failed)
        dead = 4, // dead-dispatch entry committed
    };

    pub fn name_slice(self: *const PendingDispatch) []const u8 {
        assert(self.name_len > 0);
        assert(self.name_len <= constants.worker_name_max);
        return self.name[0..self.name_len];
    }

    pub fn args_slice(self: *const PendingDispatch) []const u8 {
        assert(self.args_len <= constants.worker_args_max);
        return self.args[0..self.args_len];
    }
};

pub fn PendingIndexType(comptime max_in_flight: u8) type {
    return struct {
        const Self = @This();

        entries: [max_in_flight]PendingDispatch = undefined,
        len: u8 = 0,

        /// Add a new dispatch to the index. Returns false if full or duplicate
        /// (recovery tolerance — corrupt WAL may produce duplicates).
        pub fn add(self: *Self, dispatch: PendingDispatch) bool {
            assert(dispatch.op > 0);
            assert(dispatch.state == .pending);
            assert(dispatch.name_len > 0); // A dispatch without a name is invalid.
            if (self.len >= max_in_flight) return false;

            // Reject duplicate ops (corrupt WAL recovery or server bug).
            for (self.entries[0..self.len]) |*e| {
                if (e.op == dispatch.op) return false;
            }

            self.entries[self.len] = dispatch;
            self.len += 1;
            return true;
        }

        /// Resolve a dispatch by op — transition to completed, failed, or dead.
        /// Removes the entry from the active set by swapping with the last.
        pub fn resolve(self: *Self, op: u64, state: PendingDispatch.State) void {
            assert(op > 0);
            assert(state == .completed or state == .failed or state == .dead);
            // Note: self.len may be 0 during WAL recovery (resolve for
            // a dispatch that was already resolved in a prior entry).

            for (self.entries[0..self.len], 0..) |*e, i| {
                if (e.op == op) {
                    // Swap-remove: replace with last entry.
                    self.len -= 1;
                    if (i < self.len) {
                        self.entries[i] = self.entries[self.len];
                    }
                    return;
                }
            }
            // Dispatch not found — WAL has a completion for an already-resolved
            // or unknown dispatch. This can happen during recovery if the WAL
            // contains entries from before a crash that already resolved.
            // Not an error — skip silently.
        }

        /// Find a dispatch by WAL op. Returns null if not found.
        pub fn find_by_op(self: *const Self, op: u64) ?*const PendingDispatch {
            assert(op > 0);
            assert(self.len <= max_in_flight);
            for (self.entries[0..self.len]) |*e| {
                if (e.op == op) return e;
            }
            return null;
        }

        /// Find a mutable dispatch by WAL op.
        pub fn find_by_op_mut(self: *Self, op: u64) ?*PendingDispatch {
            assert(op > 0);
            assert(self.len <= max_in_flight);
            for (self.entries[0..self.len]) |*e| {
                if (e.op == op) return e;
            }
            return null;
        }

        /// Number of dispatches in the given state.
        pub fn count_by_state(self: *const Self, state: PendingDispatch.State) u8 {
            assert(self.len <= max_in_flight);
            var n: u8 = 0;
            for (self.entries[0..self.len]) |*e| {
                if (e.state == state) n += 1;
            }
            return n;
        }

        /// Number of active (unresolved) dispatches.
        pub fn pending_count(self: *const Self) u8 {
            assert(self.len <= max_in_flight);
            return self.len;
        }

        /// Whether the index is at capacity.
        pub fn is_full(self: *const Self) bool {
            assert(self.len <= max_in_flight);
            return self.len >= max_in_flight;
        }

        pub fn invariants(self: *const Self) void {
            assert(self.len <= max_in_flight);

            // All active entries have valid ops.
            for (self.entries[0..self.len]) |*e| {
                assert(e.op > 0);
                assert(e.name_len > 0);
                assert(e.name_len <= constants.worker_name_max);
                assert(e.args_len <= constants.worker_args_max);
            }

            // No duplicate ops.
            for (self.entries[0..self.len], 0..) |*a, i| {
                for (self.entries[i + 1 .. self.len]) |*b| {
                    assert(a.op != b.op);
                }
            }
        }
    };
}

// =========================================================================
// Dispatch section parser — shared by WAL recovery and replay tool.
// =========================================================================

/// Parse a single dispatch entry from the binary dispatch section.
/// Returns the dispatch data and advances `pos` past it.
/// Format: [u8 name_len][name][u16 BE args_len][args]
pub fn parse_one_dispatch(data: []const u8, pos: *usize) ?struct {
    name: []const u8,
    args: []const u8,
} {
    if (pos.* >= data.len) return null;

    // name_len
    const name_len = data[pos.*];
    pos.* += 1;
    if (name_len == 0 or name_len > constants.worker_name_max) return null;
    if (pos.* + name_len > data.len) return null;
    const name = data[pos.*..][0..name_len];
    pos.* += name_len;

    // args_len
    if (pos.* + 2 > data.len) return null;
    const args_len = std.mem.readInt(u16, data[pos.*..][0..2], .big);
    pos.* += 2;
    if (args_len > constants.worker_args_max) return null;
    if (pos.* + args_len > data.len) return null;
    const args = data[pos.*..][0..args_len];
    pos.* += args_len;

    return .{ .name = name, .args = args };
}

// =========================================================================
// Tests
// =========================================================================

test "PendingIndex: add and find" {
    const PendingIndex = PendingIndexType(4);
    var index = PendingIndex{};

    const d1 = make_test_dispatch(10, "charge_payment");
    assert(index.add(d1));
    try std.testing.expectEqual(@as(u8, 1), index.len);

    const found = index.find_by_op(10);
    try std.testing.expect(found != null);
    try std.testing.expectEqualSlices(u8, "charge_payment", found.?.name_slice());

    try std.testing.expect(index.find_by_op(99) == null);
}

test "PendingIndex: resolve removes entry" {
    const PendingIndex = PendingIndexType(4);
    var index = PendingIndex{};

    assert(index.add(make_test_dispatch(10, "a")));
    assert(index.add(make_test_dispatch(20, "b")));
    assert(index.add(make_test_dispatch(30, "c")));
    try std.testing.expectEqual(@as(u8, 3), index.len);

    // Resolve middle entry.
    index.resolve(20, .completed);
    try std.testing.expectEqual(@as(u8, 2), index.len);
    try std.testing.expect(index.find_by_op(20) == null);
    try std.testing.expect(index.find_by_op(10) != null);
    try std.testing.expect(index.find_by_op(30) != null);

    index.invariants();
}

test "PendingIndex: resolve unknown op is silent" {
    const PendingIndex = PendingIndexType(4);
    var index = PendingIndex{};
    assert(index.add(make_test_dispatch(10, "a")));

    // Resolving an unknown op should not crash.
    index.resolve(999, .dead);
    try std.testing.expectEqual(@as(u8, 1), index.len);
}

test "PendingIndex: is_full" {
    const PendingIndex = PendingIndexType(2);
    var index = PendingIndex{};

    try std.testing.expect(!index.is_full());
    assert(index.add(make_test_dispatch(1, "a")));
    try std.testing.expect(!index.is_full());
    assert(index.add(make_test_dispatch(2, "b")));
    try std.testing.expect(index.is_full());
}

test "parse_one_dispatch: round trip" {
    // Build a dispatch entry: [name_len:1][name][args_len:2 BE][args]
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    const name = "process_image";
    const args = "test_args";

    buf[pos] = @intCast(name.len);
    pos += 1;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(args.len), .big);
    pos += 2;
    @memcpy(buf[pos..][0..args.len], args);
    pos += args.len;

    // Parse it back.
    var read_pos: usize = 0;
    const result = parse_one_dispatch(buf[0..pos], &read_pos);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, name, result.?.name);
    try std.testing.expectEqualSlices(u8, args, result.?.args);
    try std.testing.expectEqual(pos, read_pos);
}

fn make_test_dispatch(op: u64, name: []const u8) PendingDispatch {
    var d = PendingDispatch{
        .op = op,
        .operation = 1, // test value
        .name = undefined,
        .name_len = @intCast(name.len),
        .args = undefined,
        .args_len = 0,
        .dispatched_at = 0,
        .state = .pending,
    };
    @memcpy(d.name[0..name.len], name);
    return d;
}
