//! Write-ahead log for production replay.
//!
//! Appends every committed Message to an append-only file. No fsync —
//! the kernel flushes on its own schedule. SQLite is the authority;
//! the WAL is a diagnostic notebook.
//!
//! Each entry is a fixed-size Message (784 bytes) with:
//! - checksum_body: Aegis128L over the body region
//! - checksum: Aegis128L over the header region (covers checksum_body)
//! - parent: previous entry's checksum (hash chain)
//! - op: sequential counter, monotonically increasing
//! - timestamp: wall clock from set_time()
//!
//! Op 0 is a root entry (TB pattern). The root has operation .root
//! (enum value 0) and deterministic content — its checksum is fully
//! determined by the code. On recovery, if the root checksum doesn't
//! match what this code produces, the WAL was written by an incompatible
//! version.
//!
//! Append ordering: the server commits to the database first, then
//! appends to the WAL. This is a deliberate choice between two options:
//!
//!   Option A — WAL first, then DB:
//!     If the server crashes between append and commit, the WAL contains
//!     a mutation the database never applied. The entry is valid, the
//!     chain is intact, and there's no way to detect the phantom. The
//!     WAL lies silently.
//!
//!   Option B — DB first, then WAL (chosen):
//!     If the server crashes between commit and append, the database has
//!     the mutation but the WAL doesn't. The chain ends one entry early.
//!     This is detectable — `tiger-replay verify` reports the clean stop.
//!     The WAL is honest but incomplete.
//!
//! Option B is strictly better: a missing entry is obvious and safe,
//! a phantom entry is silent and dangerous. The gap is exactly one entry
//! wide and only exists during a process crash (kill -9, OOM, power loss).
//! During normal operation the gap doesn't matter — the database is
//! the authority and has the data.
//!
//! This ordering holds regardless of storage backend. The framework is
//! DB-agnostic — different databases have different WAL semantics or
//! none at all. The framework's WAL is independent of the storage engine.
//!
//! On crash, the tail may also be truncated mid-write. The replay tool
//! reads entries sequentially and stops at the first invalid checksum.
//!
//! If a write fails (disk full, IO error), the WAL disables itself and
//! logs a warning. The server continues serving — the WAL is secondary.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const Message = message.Message;
const cs = @import("checksum.zig");

const log = std.log.scoped(.wal);

pub const Wal = struct {
    fd: std.posix.fd_t,
    op: u64,
    parent: u128,
    disabled: bool,

    /// Construct the root entry — deterministic, same code always produces
    /// the same bytes. Operation is .root (enum value 0), which is not a
    /// valid application operation. Follows TigerBeetle's Header.Prepare.root().
    ///
    /// The body contains a layout sentinel — a Product with distinct values
    /// in every numeric field. If fields are reordered (same size, different
    /// semantic meaning), the body bytes change and the root checksum catches
    /// the incompatibility. An all-zero body would not detect same-size swaps.
    pub fn root() Message {
        var entry = std.mem.zeroes(Message);
        entry.operation = .root;
        const sentinel: message.Product = .{
            .id = 0x0101010101010101_0101010101010101,
            .description = [_]u8{0x02} ** message.product_description_max,
            .name = [_]u8{0x03} ** message.product_name_max,
            .price_cents = 0x04040404,
            .inventory = 0x05050505,
            .version = 0x06060606,
            .description_len = 0x0707,
            .name_len = 0x08,
            .flags = @bitCast(@as(u8, 0x09)),
        };
        @memcpy(entry.body[0..@sizeOf(message.Product)], std.mem.asBytes(&sentinel));
        entry.set_checksum();
        return entry;
    }

    /// Open or create the WAL file. On creation, writes the root entry
    /// at op 0. On recovery, verifies the root checksum matches this
    /// code's root, then scans backwards from the last complete entry
    /// to find the last valid one and continues the chain from there.
    pub fn init(path: [:0]const u8) Wal {
        const fd = std.posix.open(
            path,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true },
            0o644,
        ) catch |err| {
            log.err("open failed: {}", .{err});
            @panic("wal: failed to open file");
        };

        var op: u64 = 0;
        var parent: u128 = 0;

        const stat = std.posix.fstat(fd) catch |err| {
            log.err("fstat failed: {}", .{err});
            @panic("wal: failed to stat file");
        };
        const file_size: u64 = @intCast(stat.size);

        if (file_size > 0) {
            const entry_count = file_size / @sizeOf(Message);
            if (entry_count > 0) {
                const read_fd = std.posix.open(
                    path,
                    .{ .ACCMODE = .RDONLY },
                    0,
                ) catch |err| {
                    log.err("open for recovery failed: {}", .{err});
                    @panic("wal: failed to open file for recovery");
                };
                defer std.posix.close(read_fd);

                // Verify root entry matches this code's version.
                const root_entry = read_entry(read_fd, 0);
                if (root_entry) |re| {
                    const expected_root = Wal.root();
                    if (re.checksum != expected_root.checksum) {
                        log.err("root checksum mismatch — WAL written by incompatible version", .{});
                        @panic("wal: version mismatch");
                    }
                } else {
                    log.err("failed to read root entry", .{});
                    @panic("wal: failed to read root entry");
                }

                // Scan backwards from the last entry to find the last valid one.
                // A crash mid-write may corrupt the tail — skip corrupt entries
                // to maintain the hash chain from the last known-good point.
                // The root was already verified above, so the scan always finds
                // at least one valid entry.
                var last_valid_slot: u64 = 0; // root, guaranteed valid
                var slot = entry_count;
                while (slot > 0) {
                    slot -= 1;
                    const entry = read_entry(read_fd, slot * @sizeOf(Message));
                    if (entry) |e| {
                        if (e.valid_checksum_header()) {
                            op = e.op + 1;
                            parent = e.checksum;
                            last_valid_slot = slot;
                            if (slot + 1 < entry_count) {
                                log.warn("skipped {d} corrupt entries at tail", .{entry_count - slot - 1});
                            }
                            log.info("recovered: entries={d} next_op={d}", .{ slot + 1, op });
                            break;
                        }
                    }
                } else unreachable; // root is always valid

                // Truncate corrupt tail so the replay tool sees a clean
                // sequential file and new appends follow the last valid entry.
                const valid_size = (last_valid_slot + 1) * @sizeOf(Message);
                if (valid_size < file_size) {
                    std.posix.ftruncate(fd, valid_size) catch |err| {
                        log.warn("ftruncate failed: {}", .{err});
                        // Non-fatal — the file has corrupt entries at the tail
                        // but new appends still go after them. The replay tool
                        // will stop at the corruption boundary.
                    };
                }
            }
        } else {
            // New file — write the root entry at op 0.
            const root_entry = Wal.root();
            if (!write_all(fd, std.mem.asBytes(&root_entry))) {
                log.err("root write failed", .{});
                @panic("wal: failed to write root entry");
            }

            op = 1;
            parent = root_entry.checksum;
            log.info("created new WAL", .{});
        }

        var wal = Wal{
            .fd = fd,
            .op = op,
            .parent = parent,
            .disabled = false,
        };
        wal.invariants();
        return wal;
    }

    pub fn deinit(wal: *Wal) void {
        std.posix.close(wal.fd);
        wal.* = undefined;
    }

    /// Prepare a message for the WAL: assign op, timestamp, parent,
    /// and compute checksums. Returns the prepared message.
    pub fn prepare(wal: *const Wal, msg: Message, timestamp: i64) Message {
        assert(wal.op > 0); // op 0 is the root
        assert(!wal.disabled);
        var entry = msg;
        entry.op = wal.op;
        entry.timestamp = timestamp;
        entry.parent = wal.parent;
        entry.set_checksum();
        return entry;
    }

    /// Append a prepared message to the WAL file. Updates op counter
    /// and parent for the next entry. On write failure, disables the
    /// WAL and logs a warning — the server continues serving.
    pub fn append(wal: *Wal, entry: *const Message) void {
        assert(entry.valid_checksum());
        assert(entry.op == wal.op);
        assert(entry.op > 0); // op 0 is the root
        assert(entry.parent == wal.parent);
        assert(!wal.disabled);
        defer wal.invariants();

        const bytes = std.mem.asBytes(entry);
        if (!write_all(wal.fd, bytes)) {
            log.warn("write failed, disabling WAL", .{});
            wal.disabled = true;
            return;
        }

        wal.parent = entry.checksum;
        wal.op += 1;
    }

    fn invariants(wal: *const Wal) void {
        assert(wal.fd > 0);
        assert(wal.op > 0); // root is always op 0; next op is at least 1
        if (wal.disabled) return;
        // parent must be non-zero after root (root's checksum is non-zero).
        assert(wal.parent != 0);
    }

    /// Read a single entry from the WAL at the given byte offset.
    /// Returns null if the read fails or returns fewer bytes than expected.
    pub fn read_entry(fd: std.posix.fd_t, offset: u64) ?Message {
        var buf: [@sizeOf(Message)]u8 align(@alignOf(Message)) = undefined;
        const n = std.posix.pread(fd, &buf, offset) catch return null;
        if (n != @sizeOf(Message)) return null;
        const entry: *const Message = @ptrCast(@alignCast(&buf));
        return entry.*;
    }

    /// Write all bytes to fd, retrying on partial writes (signal interruption).
    /// Returns false on error.
    fn write_all(fd: std.posix.fd_t, bytes: []const u8) bool {
        var remaining = bytes;
        while (remaining.len > 0) {
            const written = std.posix.write(fd, remaining) catch return false;
            if (written == 0) return false;
            remaining = remaining[written..];
        }
        return true;
    }
};

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

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

        const msg = message.Message.init(.create_product, 42, 7, product);
        const entry = wal.prepare(msg, 1000);
        wal.append(&entry);
        wal.invariants();

        try testing.expectEqual(wal.op, 2);

        const msg2 = message.Message.init(.create_product, 43, 7, product);
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
        const msg3 = message.Message.init(.create_product, 44, 7, product);
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
    try testing.expectEqual(a.checksum, 0xC12AC0E2DD6948D3353BBB83E282A889);
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
    const msg1 = message.Message.init(.create_product, 1, 1, product);
    const entry1 = wal.prepare(msg1, 100);
    try testing.expectEqual(entry1.parent, root_checksum);
    wal.append(&entry1);

    // Entry 2: parent should be entry 1's checksum.
    const msg2 = message.Message.init(.create_product, 2, 1, product);
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
            const msg = message.Message.init(.create_product, @intCast(i), 1, product);
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
            const msg = message.Message.init(.create_product, @intCast(i), 1, product);
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
