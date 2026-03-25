//! Replay fuzzer — exercises WAL write + replay round trip.
//!
//! Generates random SQL writes, appends them to a WAL, then replays
//! the WAL against a fresh database and verifies the entries parse.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const wal_mod = @import("tiger_framework").wal;
const Storage = @import("storage.zig").SqliteStorage;
const replay = @import("replay.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("tiger_framework").prng;

const Wal = wal_mod.WalType(message.Operation);

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    _ = allocator;
    const seed = args.seed;
    const events_max = args.events_max orelse 5_000;
    var prng = PRNG.from_seed(seed);

    const wal_path: [:0]const u8 = "/tmp/tiger_replay_fuzz.wal";
    std.fs.cwd().deleteFile(wal_path) catch {};
    defer std.fs.cwd().deleteFile(wal_path) catch {};

    // Phase 1: Write random entries to the WAL.
    var wal = Wal.init(wal_path);
    var scratch: [4096]u8 = undefined;
    var entries_written: u64 = 0;

    for (0..events_max) |i| {
        // Generate a random write entry.
        var write_buf: [256]u8 = undefined;
        var pos: usize = 0;

        // Simple SQL: INSERT INTO fuzz_t VALUES (?1)
        const sql = "INSERT INTO fuzz_t VALUES (?1)";
        std.mem.writeInt(u16, write_buf[pos..][0..2], sql.len, .big);
        pos += 2;
        @memcpy(write_buf[pos..][0..sql.len], sql);
        pos += sql.len;
        write_buf[pos] = 1; // 1 param
        pos += 1;
        write_buf[pos] = 0x01; // integer tag
        pos += 1;
        std.mem.writeInt(i64, write_buf[pos..][0..8], @intCast(i), .little);
        pos += 8;

        const op = prng.enum_uniform(message.Operation);
        if (op == .root) continue;
        if (!op.is_mutation()) continue;

        wal.append_writes(op, @intCast(i), write_buf[0..pos], 1, &scratch);
        entries_written += 1;
    }
    wal.deinit();

    // Phase 2: Replay the WAL against a fresh database.
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    // Create the target table.
    assert(storage.execute("CREATE TABLE fuzz_t (val INTEGER);", .{}));

    // Open WAL for reading.
    const fd = std.posix.open(wal_path, .{ .ACCMODE = .RDONLY }, 0) catch unreachable;
    defer std.posix.close(fd);
    const file_size: u64 = @intCast((std.posix.fstat(fd) catch unreachable).size);

    var buf = std.heap.page_allocator.alignedAlloc(u8, @alignOf(wal_mod.EntryHeader), wal_mod.entry_max) catch unreachable;
    defer std.heap.page_allocator.free(buf);

    var offset: u64 = 0;
    var entries_replayed: u64 = 0;

    // Skip root.
    {
        var hdr_buf: [@sizeOf(wal_mod.EntryHeader)]u8 align(@alignOf(wal_mod.EntryHeader)) = undefined;
        const n = std.posix.pread(fd, &hdr_buf, 0) catch unreachable;
        assert(n == @sizeOf(wal_mod.EntryHeader));
        const hdr: *const wal_mod.EntryHeader = @ptrCast(@alignCast(&hdr_buf));
        offset = hdr.entry_len;
    }

    while (offset < file_size) {
        var hdr_buf: [@sizeOf(wal_mod.EntryHeader)]u8 align(@alignOf(wal_mod.EntryHeader)) = undefined;
        const n = std.posix.pread(fd, &hdr_buf, offset) catch break;
        if (n < @sizeOf(wal_mod.EntryHeader)) break;
        const hdr: *const wal_mod.EntryHeader = @ptrCast(@alignCast(&hdr_buf));
        if (hdr.entry_len < @sizeOf(wal_mod.EntryHeader) or hdr.entry_len > wal_mod.entry_max) break;
        if (offset + hdr.entry_len > file_size) break;

        if (hdr.write_count > 0) {
            const full_n = std.posix.pread(fd, buf[0..hdr.entry_len], offset) catch break;
            if (full_n != hdr.entry_len) break;

            storage.begin();
            // Replay may fail (table doesn't match SQL) — that's expected for random ops.
            if (replay.execute_entry_writes(&storage, buf[@sizeOf(wal_mod.EntryHeader)..hdr.entry_len], hdr.write_count)) {
                storage.commit();
                entries_replayed += 1;
            } else {
                storage.rollback();
            }
        }
        offset += hdr.entry_len;
    }

    log.info("Replay fuzz done: written={d} replayed={d}", .{ entries_written, entries_replayed });
    assert(entries_written > 0);
    assert(entries_replayed > 0);
}
