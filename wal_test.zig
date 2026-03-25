const std = @import("std");
const testing = std.testing;
const message = @import("message.zig");
const wal_mod = @import("tiger_framework").wal;
const Wal = wal_mod.WalType(message.Operation);
const EntryHeader = wal_mod.EntryHeader;

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
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(@as(u64, 1), wal.op);
        try testing.expect(!wal.disabled);
        wal.invariants();

        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        wal.append_writes(.create_product, 1000, writes.data[0..writes.len], 1, &scratch);
        wal.invariants();
        try testing.expectEqual(@as(u64, 2), wal.op);

        wal.append_writes(.create_product, 1001, writes.data[0..writes.len], 1, &scratch);
        wal.invariants();
        try testing.expectEqual(@as(u64, 3), wal.op);
    }

    // Reopen — should recover op=3.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(@as(u64, 3), wal.op);
        try testing.expect(!wal.disabled);
        wal.invariants();

        // Can continue appending.
        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        wal.append_writes(.create_product, 1002, writes.data[0..writes.len], 1, &scratch);
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

    var wal = Wal.init(test_path());
    defer wal.deinit();

    const root_checksum = Wal.root_entry().checksum;
    try testing.expectEqual(wal.parent, root_checksum);

    const writes = sample_writes();
    var scratch: [4096]u8 = undefined;

    // After first entry, parent should have changed.
    const parent_before = wal.parent;
    wal.append_writes(.create_product, 100, writes.data[0..writes.len], 1, &scratch);
    try testing.expect(wal.parent != parent_before);

    // After second entry, parent should be different again.
    const parent_after_1 = wal.parent;
    wal.append_writes(.create_product, 101, writes.data[0..writes.len], 1, &scratch);
    try testing.expect(wal.parent != parent_after_1);
}

test "WAL truncation recovery" {
    cleanup();
    defer cleanup();

    var expected_op: u64 = undefined;

    // Write some entries.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        const writes = sample_writes();
        var scratch: [4096]u8 = undefined;
        for (0..5) |i| {
            wal.append_writes(.create_product, @intCast(i), writes.data[0..writes.len], 1, &scratch);
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
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(wal.op, expected_op);
        wal.invariants();
    }
}

test "WAL empty writes (read-only mutation)" {
    cleanup();
    defer cleanup();

    var wal = Wal.init(test_path());
    defer wal.deinit();

    // Append entry with zero writes — technically a mutation that decided
    // not to write (e.g., handler returned early with an error status).
    var scratch: [4096]u8 = undefined;
    wal.append_writes(.create_product, 1000, "", 0, &scratch);

    try testing.expectEqual(@as(u64, 2), wal.op);
    wal.invariants();
}
