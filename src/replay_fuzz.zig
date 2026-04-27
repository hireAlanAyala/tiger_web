//! Replay fuzzer — exercises WAL write + replay round trip.
//!
//! Generates random SQL writes, worker dispatches, completions, and
//! dead-dispatch entries. Replays the WAL against a fresh database
//! and verifies entries parse. Also verifies the pending index
//! recovers correctly.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const wal_mod = @import("framework/wal.zig");
const pd = @import("framework/pending_dispatch.zig");
const constants = @import("framework/constants.zig");
const Storage = @import("storage.zig").SqliteStorage;
const replay = @import("replay.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

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
    var wal = Wal.init(wal_path, null);
    var scratch: [8192]u8 = undefined;
    var entries_written: u64 = 0;

    // Track dispatches for generating valid completions/dead entries.
    var pending_ops: [64]u64 = undefined;
    var pending_count: usize = 0;

    for (0..events_max) |i| {
        const op = prng.enum_uniform(message.Operation);
        if (op == .root) continue;
        if (!op.is_mutation()) continue;

        // Generate a random write entry.
        var write_buf: [256]u8 = undefined;
        var wpos: usize = 0;
        const sql = "INSERT INTO fuzz_t VALUES (?1)";
        std.mem.writeInt(u16, write_buf[wpos..][0..2], sql.len, .big);
        wpos += 2;
        @memcpy(write_buf[wpos..][0..sql.len], sql);
        wpos += sql.len;
        write_buf[wpos] = 1; // 1 param
        wpos += 1;
        write_buf[wpos] = 0x01; // integer tag
        wpos += 1;
        std.mem.writeInt(i64, write_buf[wpos..][0..8], @intCast(i), .little);
        wpos += 8;

        // Decide entry type: 60% normal, 15% dispatch, 15% completion, 10% dead.
        const roll = prng.range_inclusive(u32, 0, 99);

        if (roll < 60) {
            // Normal write entry (no dispatches).
            wal.append_writes(op, @intCast(i), write_buf[0..wpos], 1, "", 0, &scratch);
        } else if (roll < 75) {
            // Write entry with a dispatch.
            var dispatch_buf: [128]u8 = undefined;
            var dpos: usize = 0;
            const name = "fuzz_worker";
            dispatch_buf[dpos] = @intCast(name.len);
            dpos += 1;
            @memcpy(dispatch_buf[dpos..][0..name.len], name);
            dpos += name.len;
            const args_len: u16 = prng.range_inclusive(u16, 0, 32);
            std.mem.writeInt(u16, dispatch_buf[dpos..][0..2], args_len, .big);
            dpos += 2;
            for (0..args_len) |_| {
                dispatch_buf[dpos] = prng.int(u8);
                dpos += 1;
            }

            wal.append_writes(op, @intCast(i), write_buf[0..wpos], 1, dispatch_buf[0..dpos], 1, &scratch);

            // Track this dispatch op for future completions.
            if (pending_count < pending_ops.len) {
                pending_ops[pending_count] = wal.op - 1; // op was incremented after append
                pending_count += 1;
            }
        } else if (roll < 90 and pending_count > 0) {
            // Completion entry referencing a pending dispatch.
            const idx = prng.range_inclusive(usize, 0, pending_count - 1);
            const dispatch_op = pending_ops[idx];

            wal.append_completion(op, @intCast(i), write_buf[0..wpos], 1, dispatch_op, &scratch);

            // Remove from pending (swap-remove).
            pending_count -= 1;
            if (idx < pending_count) {
                pending_ops[idx] = pending_ops[pending_count];
            }
        } else if (pending_count > 0) {
            // Dead-dispatch entry.
            const idx = prng.range_inclusive(usize, 0, pending_count - 1);
            const dispatch_op = pending_ops[idx];

            wal.append_dead_dispatch(op, @intCast(i), dispatch_op, &scratch);

            // Remove from pending.
            pending_count -= 1;
            if (idx < pending_count) {
                pending_ops[idx] = pending_ops[pending_count];
            }
        } else {
            // Fallback: normal write.
            wal.append_writes(op, @intCast(i), write_buf[0..wpos], 1, "", 0, &scratch);
        }

        entries_written += 1;
    }
    wal.deinit();

    // Phase 2: Replay the WAL against a fresh database.
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    assert(storage.execute("CREATE TABLE fuzz_t (val INTEGER);", .{}));

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
            if (replay.execute_entry_writes(&storage, buf[@sizeOf(wal_mod.EntryHeader)..hdr.entry_len], hdr.write_count)) {
                storage.commit();
                entries_replayed += 1;
            } else {
                storage.rollback();
            }
        }
        offset += hdr.entry_len;
    }

    // Phase 3: Verify recovery rebuilds the pending index correctly.
    {
        var pending = Wal.PendingIndex{};
        var wal2 = Wal.init(wal_path, &pending);
        defer wal2.deinit();

        // Pending count should match our local tracking.
        // (pending_count from phase 1 = dispatches not yet completed/dead)
        assert(pending.pending_count() == @as(u8, @intCast(pending_count)));
        pending.invariants();
    }

    log.info("Replay fuzz done: written={d} replayed={d} pending={d}", .{
        entries_written, entries_replayed, pending_count,
    });
    assert(entries_written > 0);
    assert(entries_replayed > 0);
}
