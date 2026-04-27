const std = @import("std");
const testing = std.testing;
const message = @import("message.zig");
const wal_mod = @import("framework/wal.zig");
const Wal = wal_mod.WalType(message.Operation);
const EntryHeader = wal_mod.EntryHeader;
const pd = @import("framework/pending_dispatch.zig");
const constants = @import("framework/constants.zig");

fn test_path() [:0]const u8 {
    return "/tmp/tiger_web_wal_test.wal";
}

fn cleanup() void {
    std.posix.unlink(test_path()) catch {};
}

// Sample SQL writes for testing — same format as sidecar protocol.
fn sample_writes() struct { data: [128]u8, len: usize } {
    var buf: [128]u8 = undefined;
    var pos: usize = 0;
    // Write 1: "INSERT INTO t VALUES (?1)" with 1 integer param (42).
    const sql = "INSERT INTO t VALUES (?1)";
    std.mem.writeInt(u16, buf[pos..][0..2], sql.len, .big);
    pos += 2;
    @memcpy(buf[pos..][0..sql.len], sql);
    pos += sql.len;
    buf[pos] = 1; // 1 param
    pos += 1;
    buf[pos] = 0x01; // integer tag
    pos += 1;
    std.mem.writeInt(i64, buf[pos..][0..8], 42, .little);
    pos += 8;
    return .{ .data = buf, .len = pos };
}

test "WAL create and recover" {
    cleanup();
    defer cleanup();

    // Create a new WAL, write some entries.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        try testing.expectEqual(@as(u64, 1), wal.op);
        try testing.expect(!wal.disabled);
        wal.invariants();

        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        wal.append_writes(.create_product, 1000, writes.data[0..writes.len], 1, "", 0, &scratch);
        wal.invariants();
        try testing.expectEqual(@as(u64, 2), wal.op);

        wal.append_writes(.create_product, 1001, writes.data[0..writes.len], 1, "", 0, &scratch);
        wal.invariants();
        try testing.expectEqual(@as(u64, 3), wal.op);
    }

    // Reopen — should recover op=3.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        try testing.expectEqual(@as(u64, 3), wal.op);
        try testing.expect(!wal.disabled);
        wal.invariants();

        // Can continue appending.
        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        wal.append_writes(.create_product, 1002, writes.data[0..writes.len], 1, "", 0, &scratch);
        try testing.expectEqual(@as(u64, 4), wal.op);
    }
}

test "WAL root deterministic" {
    const a = Wal.root_entry();
    const b = Wal.root_entry();
    try testing.expectEqual(a.checksum, b.checksum);
    try testing.expect(a.checksum != 0);
}

test "WAL hash chain" {
    cleanup();
    defer cleanup();

    var wal = Wal.init(test_path(), null);
    defer wal.deinit();

    const root_checksum = Wal.root_entry().checksum;
    try testing.expectEqual(wal.parent, root_checksum);

    const writes = sample_writes();
    var scratch: [4096]u8 = undefined;

    // After first entry, parent should have changed.
    const parent_before = wal.parent;
    wal.append_writes(.create_product, 100, writes.data[0..writes.len], 1, "", 0, &scratch);
    try testing.expect(wal.parent != parent_before);

    // After second entry, parent should be different again.
    const parent_after_1 = wal.parent;
    wal.append_writes(.create_product, 101, writes.data[0..writes.len], 1, "", 0, &scratch);
    try testing.expect(wal.parent != parent_after_1);
}

test "WAL truncation recovery" {
    cleanup();
    defer cleanup();

    var expected_op: u64 = undefined;

    // Write some entries.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        for (0..5) |i| {
            wal.append_writes(.create_product, @intCast(i), writes.data[0..writes.len], 1, "", 0, &scratch);
        }
        expected_op = wal.op;
    }

    // Append garbage (partial write from a crash).
    {
        const fd = std.posix.open(
            test_path(),
            .{ .ACCMODE = .WRONLY, .APPEND = true },
            0,
        ) catch unreachable;
        defer std.posix.close(fd);
        const garbage = [_]u8{0xDE} ** 100;
        _ = std.posix.write(fd, &garbage) catch unreachable;
    }

    // Recover — should ignore the garbage and resume from the last valid entry.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        try testing.expectEqual(wal.op, expected_op);
        wal.invariants();
    }
}

test "WAL empty writes (read-only mutation)" {
    cleanup();
    defer cleanup();

    var wal = Wal.init(test_path(), null);
    defer wal.deinit();

    // Append entry with zero writes — technically a mutation that decided
    // not to write (e.g., handler returned early with an error status).
    var scratch: [4096]u8 = undefined;
    wal.append_writes(.create_product, 1000, "", 0, "", 0, &scratch);

    try testing.expectEqual(@as(u64, 2), wal.op);
    wal.invariants();
}

test "WAL seeded corruption recovery" {
    // Write entries, corrupt random bytes, verify recovery doesn't crash
    // and resumes from the last valid entry before corruption.
    const PRNG = @import("stdx").PRNG;
    const iterations = 100;
    var prng = PRNG.from_seed(42);

    for (0..iterations) |_| {
        cleanup();

        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        const num_entries = prng.range_inclusive(u32, 1, 10);
        var last_op: u64 = 0;

        // Write entries.
        {
            var wal = Wal.init(test_path(), null);
            for (0..num_entries) |i| {
                wal.append_writes(.create_product, @intCast(i), writes.data[0..writes.len], 1, "", 0, &scratch);
            }
            last_op = wal.op;
            wal.deinit();
        }

        // Corrupt random bytes in the file.
        {
            const fd = std.posix.open(test_path(), .{ .ACCMODE = .WRONLY }, 0) catch continue;
            defer std.posix.close(fd);
            const stat = std.posix.fstat(fd) catch continue;
            const file_size: u64 = @intCast(stat.size);
            if (file_size < 2) continue;

            const num_corruptions = prng.range_inclusive(u32, 1, 5);
            for (0..num_corruptions) |_| {
                const offset = prng.range_inclusive(u64, 0, file_size - 1);
                const bad = [_]u8{prng.int(u8)};
                _ = std.posix.pwrite(fd, &bad, offset) catch {};
            }
        }

        // Recovery must not crash. Op may be anything from 1 (only root
        // survived) to last_op (corruption missed all entries).
        {
            var wal = Wal.init(test_path(), null);
            defer wal.deinit();
            wal.invariants();
            // Recovery must produce a valid state. Op is at least 1 (root).
            // May differ from last_op — corruption can shorten or (rarely)
            // misalign entries making recovery see different boundaries.
            try testing.expect(wal.op >= 1);
        }
    }
    cleanup();
}

// =========================================================================
// Worker dispatch tests
// =========================================================================

// Build a sample dispatch section: [name_len:1][name][args_len:2 BE][args]
fn sample_dispatch(name: []const u8, args: []const u8) struct { data: [256]u8, len: usize } {
    var buf: [256]u8 = undefined;
    var pos: usize = 0;
    buf[pos] = @intCast(name.len);
    pos += 1;
    @memcpy(buf[pos..][0..name.len], name);
    pos += name.len;
    std.mem.writeInt(u16, buf[pos..][0..2], @intCast(args.len), .big);
    pos += 2;
    if (args.len > 0) {
        @memcpy(buf[pos..][0..args.len], args);
        pos += args.len;
    }
    return .{ .data = buf, .len = pos };
}

test "WAL dispatch entry: writes + dispatches" {
    cleanup();
    defer cleanup();

    const writes = sample_writes();
    const dispatch = sample_dispatch("charge_payment", "test_args_123");
    var scratch: [4096]u8 = undefined;

    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        wal.append_writes(
            .create_order,
            2000,
            writes.data[0..writes.len],
            1,
            dispatch.data[0..dispatch.len],
            1,
            &scratch,
        );
        try testing.expectEqual(@as(u64, 2), wal.op);
    }

    // Recover and verify dispatch section is preserved in the hash chain.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();
        try testing.expectEqual(@as(u64, 2), wal.op);
    }
}

test "WAL dispatch recovery builds pending index" {
    cleanup();
    defer cleanup();

    const writes = sample_writes();
    const dispatch = sample_dispatch("process_image", "img_data");
    var scratch: [4096]u8 = undefined;

    // Write a dispatch entry.
    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        wal.append_writes(
            .create_product,
            3000,
            writes.data[0..writes.len],
            1,
            dispatch.data[0..dispatch.len],
            1,
            &scratch,
        );
        // op=1 was the dispatch entry.
        try testing.expectEqual(@as(u64, 2), wal.op);
    }

    // Recover with pending index — should find the dispatch.
    {
        var pending = Wal.PendingIndex{};
        var wal = Wal.init(test_path(), &pending);
        defer wal.deinit();

        try testing.expectEqual(@as(u8, 1), pending.pending_count());
        const found = pending.find_by_op(1);
        try testing.expect(found != null);
        try testing.expectEqualSlices(u8, "process_image", found.?.name_slice());
        try testing.expectEqualSlices(u8, "img_data", found.?.args_slice());
    }
}

test "WAL completion resolves dispatch in pending index" {
    cleanup();
    defer cleanup();

    const writes = sample_writes();
    const dispatch = sample_dispatch("charge_payment", "pay_args");
    var scratch: [4096]u8 = undefined;

    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        // Op 1: dispatch entry.
        wal.append_writes(
            .create_order,
            4000,
            writes.data[0..writes.len],
            1,
            dispatch.data[0..dispatch.len],
            1,
            &scratch,
        );

        // Op 2: completion entry referencing dispatch at op 1.
        wal.append_completion(
            .complete_order,
            4001,
            writes.data[0..writes.len],
            1,
            1, // completes_op
            &scratch,
        );
        try testing.expectEqual(@as(u64, 3), wal.op);
    }

    // Recover — dispatch should be resolved, pending index empty.
    {
        var pending = Wal.PendingIndex{};
        var wal = Wal.init(test_path(), &pending);
        defer wal.deinit();

        try testing.expectEqual(@as(u8, 0), pending.pending_count());
        try testing.expect(pending.find_by_op(1) == null);
    }
}

test "WAL dead-dispatch resolves dispatch in pending index" {
    cleanup();
    defer cleanup();

    const writes = sample_writes();
    const dispatch = sample_dispatch("slow_worker", "");
    var scratch: [4096]u8 = undefined;

    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        // Op 1: dispatch entry.
        wal.append_writes(
            .create_order,
            5000,
            writes.data[0..writes.len],
            1,
            dispatch.data[0..dispatch.len],
            1,
            &scratch,
        );

        // Op 2: dead-dispatch entry referencing dispatch at op 1.
        wal.append_dead_dispatch(
            .complete_order,
            5100,
            1, // completes_op
            &scratch,
        );
        try testing.expectEqual(@as(u64, 3), wal.op);
    }

    // Recover — dispatch should be resolved dead, pending index empty.
    {
        var pending = Wal.PendingIndex{};
        var wal = Wal.init(test_path(), &pending);
        defer wal.deinit();

        try testing.expectEqual(@as(u8, 0), pending.pending_count());
    }
}

test "WAL mixed entries: dispatch + complete + dispatch stays pending" {
    cleanup();
    defer cleanup();

    const writes = sample_writes();
    const d1 = sample_dispatch("worker_a", "a1");
    const d2 = sample_dispatch("worker_b", "b1");
    var scratch: [4096]u8 = undefined;

    {
        var wal = Wal.init(test_path(), null);
        defer wal.deinit();

        // Op 1: first dispatch.
        wal.append_writes(.create_order, 6000, writes.data[0..writes.len], 1, d1.data[0..d1.len], 1, &scratch);

        // Op 2: second dispatch.
        wal.append_writes(.create_order, 6001, writes.data[0..writes.len], 1, d2.data[0..d2.len], 1, &scratch);

        // Op 3: complete first dispatch.
        wal.append_completion(.complete_order, 6002, writes.data[0..writes.len], 1, 1, &scratch);
    }

    // Recover — only the second dispatch should be pending.
    {
        var pending = Wal.PendingIndex{};
        var wal = Wal.init(test_path(), &pending);
        defer wal.deinit();

        try testing.expectEqual(@as(u8, 1), pending.pending_count());
        try testing.expect(pending.find_by_op(1) == null); // resolved
        const found = pending.find_by_op(2);
        try testing.expect(found != null);
        try testing.expectEqualSlices(u8, "worker_b", found.?.name_slice());
    }
}
