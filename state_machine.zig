const std = @import("std");
const assert = std.debug.assert;
const maybe = message.maybe;
const message = @import("message.zig");
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.state_machine));

/// Maximum number of entries in the KV store.
/// Power of 2 for efficient open-addressing.
const capacity = 4096;

/// Load factor threshold — rehashing not needed since capacity is fixed.
/// We assert on insert that we don't exceed this.
const capacity_max = capacity * 3 / 4;

pub const StateMachine = struct {
    const Entry = struct {
        key_buf: [message.key_max]u8,
        key_len: u16,
        value_buf: [message.value_max]u8,
        value_len: u32,
        occupied: bool,
    };

    pub const PrefetchResult = struct {
        found: bool,
        slot: u32,
    };

    entries: *[capacity]Entry,
    count: u32,
    phase: Phase,

    comptime {
        // capacity must be power of 2 for open-addressing wrap.
        assert(capacity > 0);
        assert(capacity & (capacity - 1) == 0);
        // Load factor limit must be below capacity.
        assert(capacity_max < capacity);
        assert(capacity_max > 0);
        // key_max must fit in u16 (RequestHeader.key_len).
        assert(message.key_max <= std.math.maxInt(u16));
        // value_max must fit in u32 (RequestHeader.value_len).
        assert(message.value_max <= std.math.maxInt(u32));
    }

    const empty_entry = Entry{
        .key_buf = undefined,
        .key_len = 0,
        .value_buf = undefined,
        .value_len = 0,
        .occupied = false,
    };

    /// Allocate all storage upfront. No allocation after init.
    pub fn init(allocator: std.mem.Allocator) !StateMachine {
        const entries = try allocator.create([capacity]Entry);
        @memset(entries, empty_entry);
        return .{
            .entries = entries,
            .count = 0,
            .phase = .idle,
        };
    }

    pub fn deinit(self: *StateMachine, allocator: std.mem.Allocator) void {
        allocator.destroy(self.entries);
    }

    const Phase = enum {
        idle,
        prefetched,
    };

    /// Phase 1: Look up a key. Returns whether it was found and the slot
    /// (either the existing entry's slot or the first free slot for insertion).
    /// This is a pure read — no mutation.
    pub fn prefetch(self: *StateMachine, key: []const u8) PrefetchResult {
        assert(self.phase == .idle);
        assert(key.len > 0);
        assert(key.len <= message.key_max);

        self.phase = .prefetched;

        var slot = hash(key);
        var probes: u32 = 0;
        while (probes < capacity) : (probes += 1) {
            const entry = &self.entries[slot];
            if (!entry.occupied) {
                return .{ .found = false, .slot = slot };
            }
            if (entry.key_len == key.len and
                std.mem.eql(u8, entry.key_buf[0..entry.key_len], key))
            {
                return .{ .found = true, .slot = slot };
            }
            slot = (slot + 1) % capacity;
        }

        // Table is full — should never happen due to capacity_max check on insert.
        unreachable;
    }

    /// Phase 2: Execute the operation using the prefetched result.
    /// This is where mutation happens for put/delete.
    /// Returns a Response (status + optional value).
    pub fn execute(
        self: *StateMachine,
        operation: message.Operation,
        key: []const u8,
        value: []const u8,
        prefetched: PrefetchResult,
    ) message.Response {
        assert(self.phase == .prefetched);
        self.phase = .idle;

        // Validate operation/value consistency.
        switch (operation) {
            .put => assert(value.len > 0),
            .get, .delete => assert(value.len == 0),
        }
        assert(key.len > 0);
        assert(key.len <= message.key_max);
        assert(value.len <= message.value_max);
        assert(prefetched.slot < capacity);

        switch (operation) {
            .get => return self.execute_get(prefetched),
            .put => return self.execute_put(key, value, prefetched),
            .delete => return self.execute_delete(prefetched),
        }
    }

    fn execute_get(self: *const StateMachine, prefetched: PrefetchResult) message.Response {
        // Key may or may not exist.
        maybe(prefetched.found);
        if (!prefetched.found) {
            return .{ .header = .{ .status = .not_found, .value_len = 0 }, .value = "" };
        }

        const entry = &self.entries[prefetched.slot];
        assert(entry.occupied);
        assert(entry.key_len > 0);
        assert(entry.key_len <= message.key_max);
        assert(entry.value_len > 0);
        assert(entry.value_len <= message.value_max);

        return .{
            .header = .{ .status = .ok, .value_len = entry.value_len },
            .value = entry.value_buf[0..entry.value_len],
        };
    }

    fn execute_put(self: *StateMachine, key: []const u8, value: []const u8, prefetched: PrefetchResult) message.Response {
        const entry = &self.entries[prefetched.slot];

        // Key may or may not already exist (insert vs overwrite).
        maybe(prefetched.found);
        if (!prefetched.found) {
            // New entry — check we haven't exceeded load factor.
            assert(!entry.occupied);
            assert(self.count < capacity_max);
            self.count += 1;
            if (self.count > capacity_max * 9 / 10) {
                log.mark.warn("approaching capacity: {d}/{d}", .{ self.count, capacity_max });
            }
            entry.occupied = true;
            entry.key_len = @intCast(key.len);
            @memcpy(entry.key_buf[0..key.len], key);
        } else {
            // Overwrite — existing key must match.
            assert(entry.occupied);
            assert(entry.key_len == key.len);
            assert(std.mem.eql(u8, entry.key_buf[0..entry.key_len], key));
        }

        assert(entry.occupied);
        entry.value_len = @intCast(value.len);
        @memcpy(entry.value_buf[0..value.len], value);

        return .{ .header = .{ .status = .ok, .value_len = 0 }, .value = "" };
    }

    fn execute_delete(self: *StateMachine, prefetched: PrefetchResult) message.Response {
        // Key may or may not exist.
        maybe(prefetched.found);
        if (!prefetched.found) {
            return .{ .header = .{ .status = .not_found, .value_len = 0 }, .value = "" };
        }

        // Tombstone deletion with re-probe of subsequent entries.
        // Mark slot as free and re-insert any entries that may have
        // been displaced by this slot.
        self.remove_and_reinsert(prefetched.slot);

        return .{ .header = .{ .status = .ok, .value_len = 0 }, .value = "" };
    }

    fn remove_and_reinsert(self: *StateMachine, removed_slot: u32) void {
        assert(removed_slot < capacity);
        assert(self.entries[removed_slot].occupied);
        assert(self.count > 0);
        const count_before = self.count;

        self.entries[removed_slot].occupied = false;
        self.count -= 1;

        // Re-probe subsequent entries to fill the gap.
        var slot = (removed_slot + 1) % capacity;
        while (self.entries[slot].occupied) {
            const entry = self.entries[slot];
            self.entries[slot].occupied = false;
            self.count -= 1;

            // Re-insert using the normal probe sequence.
            assert(entry.key_len > 0);
            assert(entry.key_len <= message.key_max);
            const key = entry.key_buf[0..entry.key_len];
            var target = hash(key);
            while (self.entries[target].occupied) {
                target = (target + 1) % capacity;
            }
            self.entries[target] = entry;
            self.count += 1;

            slot = (slot + 1) % capacity;
        }

        // Exactly one entry was removed.
        assert(self.count == count_before - 1);
    }

    fn hash(key: []const u8) u32 {
        // FNV-1a hash, masked to table size.
        var h: u32 = 2166136261;
        for (key) |byte| {
            h ^= byte;
            h *%= 16777619;
        }
        return h % capacity;
    }

    pub fn reset(self: *StateMachine) void {
        @memset(self.entries, empty_entry);
        self.count = 0;
        self.phase = .idle;
    }
};

test "put and get" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const prefetch_put = sm.prefetch("hello");
    const resp_put = sm.execute(.put, "hello", "world", prefetch_put);
    try std.testing.expectEqual(resp_put.header.status, .ok);

    const prefetch_get = sm.prefetch("hello");
    const resp_get = sm.execute(.get, "hello", "", prefetch_get);
    try std.testing.expectEqual(resp_get.header.status, .ok);
    try std.testing.expectEqualSlices(u8, resp_get.value, "world");
}

test "get missing key" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const prefetched = sm.prefetch("missing");
    const resp = sm.execute(.get, "missing", "", prefetched);
    try std.testing.expectEqual(resp.header.status, .not_found);
}

test "put overwrite" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const p1 = sm.prefetch("key");
    _ = sm.execute(.put, "key", "value1", p1);

    const p2 = sm.prefetch("key");
    _ = sm.execute(.put, "key", "value2", p2);

    const p3 = sm.prefetch("key");
    const resp = sm.execute(.get, "key", "", p3);
    try std.testing.expectEqualSlices(u8, resp.value, "value2");
}

test "delete" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const p1 = sm.prefetch("key");
    _ = sm.execute(.put, "key", "value", p1);

    const p2 = sm.prefetch("key");
    const resp_del = sm.execute(.delete, "key", "", p2);
    try std.testing.expectEqual(resp_del.header.status, .ok);

    const p3 = sm.prefetch("key");
    const resp_get = sm.execute(.get, "key", "", p3);
    try std.testing.expectEqual(resp_get.header.status, .not_found);
}

test "delete missing" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    const p = sm.prefetch("missing");
    const resp = sm.execute(.delete, "missing", "", p);
    try std.testing.expectEqual(resp.header.status, .not_found);
}

test "delete does not break probe chains" {
    var sm = try StateMachine.init(std.testing.allocator);
    defer sm.deinit(std.testing.allocator);

    // Insert multiple keys that may collide.
    const keys = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };
    for (keys) |key| {
        const p = sm.prefetch(key);
        _ = sm.execute(.put, key, "v", p);
    }

    // Delete one from the middle.
    const pd = sm.prefetch("charlie");
    _ = sm.execute(.delete, "charlie", "", pd);

    // All others should still be findable.
    for (keys) |key| {
        if (std.mem.eql(u8, key, "charlie")) continue;
        const p = sm.prefetch(key);
        const resp = sm.execute(.get, key, "", p);
        try std.testing.expectEqual(resp.header.status, .ok);
    }
}
