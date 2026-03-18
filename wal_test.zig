const std = @import("std");
const testing = std.testing;
const message = @import("message.zig");
const Message = message.Message;
const Wal = @import("tiger_framework").wal.WalType(Message, message.wal_root);

fn test_path() [:0]const u8 {
    return "/tmp/tiger_web_wal_test.wal";
}

fn cleanup() void {
    std.posix.unlink(test_path()) catch {};
}

test "WAL create and recover" {
    cleanup();
    defer cleanup();

    // Create a new WAL, write some entries.
    const product = std.mem.zeroes(message.Product);
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(wal.op, 1);
        try testing.expect(!wal.disabled);
        wal.invariants();

        const msg = Message.init(.create_product, 42, 7, product);
        const entry = wal.prepare(msg, 1000);
        wal.append(&entry);
        wal.invariants();

        try testing.expectEqual(wal.op, 2);

        const msg2 = Message.init(.create_product, 43, 7, product);
        const entry2 = wal.prepare(msg2, 1001);
        wal.append(&entry2);
        wal.invariants();

        try testing.expectEqual(wal.op, 3);
    }

    // Reopen — should recover op=3, parent from the last entry.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(wal.op, 3);
        try testing.expect(!wal.disabled);
        wal.invariants();

        // Can continue appending.
        const msg3 = Message.init(.create_product, 44, 7, product);
        const entry3 = wal.prepare(msg3, 1002);
        wal.append(&entry3);

        try testing.expectEqual(wal.op, 4);
        wal.invariants();
    }
}

test "WAL root deterministic" {
    const a = Wal.root();
    const b = Wal.root();
    try testing.expectEqual(a.checksum, b.checksum);
    try testing.expectEqual(a.checksum_body, b.checksum_body);
    try testing.expect(a.valid_checksum());
    try testing.expect(a.checksum != 0);

    // Stability — if the Message layout or checksum function changes,
    // the root checksum changes and this test catches it.
    try testing.expectEqual(a.checksum, 0x09AE007A4A26F6D66E3BD522A08C1920);
}

test "WAL root sentinel detects same-size field swaps" {
    // The sentinel exists to catch same-size field reorders that an
    // all-zero body would miss. Simulate swapping price_cents and
    // inventory (both u32) — the root checksum must change.
    const root_entry = Wal.root();

    // Construct a root with swapped fields.
    var swapped_sentinel: message.Product = .{
        .id = 0x0101010101010101_0101010101010101,
        .description = [_]u8{0x02} ** message.product_description_max,
        .name = [_]u8{0x03} ** message.product_name_max,
        .price_cents = 0x05050505, // was 0x04040404 (swapped with inventory)
        .inventory = 0x04040404, // was 0x05050505 (swapped with price_cents)
        .version = 0x06060606,
        .description_len = 0x0707,
        .name_len = 0x08,
        .flags = @bitCast(@as(u8, 0x09)),
    };

    var swapped_entry = std.mem.zeroes(Message);
    swapped_entry.operation = .root;
    @memcpy(swapped_entry.body[0..@sizeOf(message.Product)], std.mem.asBytes(&swapped_sentinel));
    swapped_entry.set_checksum();

    // The checksums must differ — this is the whole point of the sentinel.
    try testing.expect(swapped_entry.checksum != root_entry.checksum);
    try testing.expect(swapped_entry.checksum_body != root_entry.checksum_body);

    // Also verify swapping name_len and flags (both 1 byte) is detected.
    var swapped2 = std.mem.zeroes(message.Product);
    swapped2.id = 0x0101010101010101_0101010101010101;
    swapped2.description = [_]u8{0x02} ** message.product_description_max;
    swapped2.name = [_]u8{0x03} ** message.product_name_max;
    swapped2.price_cents = 0x04040404;
    swapped2.inventory = 0x05050505;
    swapped2.version = 0x06060606;
    swapped2.description_len = 0x0707;
    swapped2.name_len = 0x09; // was 0x08 (swapped with flags)
    swapped2.flags = @bitCast(@as(u8, 0x08)); // was 0x09 (swapped with name_len)

    var swapped2_entry = std.mem.zeroes(Message);
    swapped2_entry.operation = .root;
    @memcpy(swapped2_entry.body[0..@sizeOf(message.Product)], std.mem.asBytes(&swapped2));
    swapped2_entry.set_checksum();

    try testing.expect(swapped2_entry.checksum != root_entry.checksum);
}

test "WAL hash chain" {
    cleanup();
    defer cleanup();

    var wal = Wal.init(test_path());
    defer wal.deinit();

    const root_checksum = Wal.root().checksum;
    try testing.expectEqual(wal.parent, root_checksum);

    const product = std.mem.zeroes(message.Product);

    // Entry 1: parent should be root's checksum.
    const msg1 = Message.init(.create_product, 1, 1, product);
    const entry1 = wal.prepare(msg1, 100);
    try testing.expectEqual(entry1.parent, root_checksum);
    wal.append(&entry1);

    // Entry 2: parent should be entry 1's checksum.
    const msg2 = Message.init(.create_product, 2, 1, product);
    const entry2 = wal.prepare(msg2, 101);
    try testing.expectEqual(entry2.parent, entry1.checksum);
    wal.append(&entry2);
}

test "WAL truncation recovery" {
    cleanup();
    defer cleanup();

    const product = std.mem.zeroes(message.Product);
    var expected_op: u64 = undefined;

    // Write some entries.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        for (0..5) |i| {
            const msg = Message.init(.create_product, @intCast(i), 1, product);
            const entry = wal.prepare(msg, @intCast(i));
            wal.append(&entry);
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

    // Recover — should ignore the partial entry and resume from entry 5.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(wal.op, expected_op);
        wal.invariants();
    }
}

test "WAL corrupt tail recovery" {
    cleanup();
    defer cleanup();

    const product = std.mem.zeroes(message.Product);
    var entry3_op: u64 = undefined;
    var entry3_checksum: u128 = undefined;

    // Write 5 entries.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        for (0..5) |i| {
            const msg = Message.init(.create_product, @intCast(i), 1, product);
            const entry = wal.prepare(msg, @intCast(i));
            wal.append(&entry);
            if (i == 2) {
                entry3_op = entry.op;
                entry3_checksum = entry.checksum;
            }
        }
    }

    // Corrupt the last two complete entries (entries 4 and 5, which are at
    // slots 5 and 6 including the root). Write a bad byte into each.
    {
        const fd = std.posix.open(
            test_path(),
            .{ .ACCMODE = .WRONLY },
            0,
        ) catch unreachable;
        defer std.posix.close(fd);

        const bad = [_]u8{0xFF};
        // Corrupt slot 5 (entry at op=4) — write bad byte into the middle.
        _ = std.posix.pwrite(fd, &bad, 5 * @sizeOf(Message) + 100) catch unreachable;
        // Corrupt slot 4 (entry at op=3) — write bad byte into the middle.
        _ = std.posix.pwrite(fd, &bad, 4 * @sizeOf(Message) + 100) catch unreachable;
    }

    // Recovery should scan backwards past the two corrupt entries
    // and resume from entry at op=2 (slot 3).
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();

        try testing.expectEqual(wal.op, entry3_op + 1);
        try testing.expectEqual(wal.parent, entry3_checksum);
        wal.invariants();
    }
}

test "WAL version mismatch panics" {
    cleanup();
    defer cleanup();

    // Create a valid WAL.
    {
        var wal = Wal.init(test_path());
        defer wal.deinit();
    }

    // Corrupt the root entry's checksum.
    {
        const fd = std.posix.open(
            test_path(),
            .{ .ACCMODE = .WRONLY },
            0,
        ) catch unreachable;
        defer std.posix.close(fd);
        // Overwrite the first byte of the checksum field.
        const bad = [_]u8{0xFF};
        _ = std.posix.pwrite(fd, &bad, 0) catch unreachable;
    }

    // Reopen should panic on version mismatch.
    // We can't test @panic directly, so verify the root checksum mismatch
    // would be detected by checking the logic manually.
    const read_fd = std.posix.open(
        test_path(),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch unreachable;
    defer std.posix.close(read_fd);

    const entry = Wal.read_entry(read_fd, 0);
    try testing.expect(entry != null);
    const expected_root = Wal.root();
    try testing.expect(entry.?.checksum != expected_root.checksum);
}

test "WAL write_all handles partial writes" {
    // write_all loops on partial writes. We can't easily inject partial
    // writes, but verify it handles the full write case correctly.
    cleanup();
    defer cleanup();

    const fd = std.posix.open(
        test_path(),
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o644,
    ) catch unreachable;
    defer std.posix.close(fd);

    const data = [_]u8{0xAB} ** 1024;
    try testing.expect(Wal.write_all(fd, &data));
}
