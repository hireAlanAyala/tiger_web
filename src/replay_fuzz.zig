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

    // Phase 4: Crash-restart equivalence. Phase 1-3 prove a clean
    // WAL round-trips. The contract durability actually rests on is
    // "the process can crash at any byte, restart, and recover a
    // consistent state — deterministically, without losing committed
    // work or inventing pending work that was never on disk." TB's
    // journal_checker enforces the equivalent property; we approximate
    // it by truncating the WAL at random offsets and re-running
    // recovery against a stronger ladder of assertions.
    try crash_restart_equivalence(wal_path, &prng, file_size, entries_written);
}

/// Truncate the WAL at random offsets and assert recovery is
/// well-formed AND deterministic. Each iteration copies the WAL,
/// truncates, and runs:
///
///   1. `pending.invariants()` — structural validity (no duplicate
///      ops, no entries beyond max_in_flight).
///   2. Bound check — `pending_count <= entries_written`. The
///      negative-space pair: truncation can only drop entries, never
///      invent them. A recovered pending count exceeding what was
///      ever written would mean the parser fabricated entries from
///      garbage tail bytes.
///   3. Op cap — every pending entry's `op` is ≤ the recovered WAL
///      op counter. Catches "pending references an op the WAL
///      doesn't know about" — the corruption shape that a stale
///      mmap or torn write would produce.
///   4. Determinism — re-init from the same truncated file gives the
///      same pending state. TB's first-class principle: same input,
///      same output. A recovery whose output drifts between cold
///      starts is broken even when each individual run looks fine.
fn crash_restart_equivalence(
    src_path: [:0]const u8,
    prng: *PRNG,
    file_size: u64,
    entries_written: u64,
) !void {
    const trunc_path: [:0]const u8 = "/tmp/tiger_replay_fuzz.crash.wal";
    std.fs.cwd().deleteFile(trunc_path) catch {};
    defer std.fs.cwd().deleteFile(trunc_path) catch {};

    const trunc_offsets = 16;
    var ok_truncations: u32 = 0;
    for (0..trunc_offsets) |_| {
        // Copy the WAL bytes 1:1 and truncate at a random point.
        const src = std.fs.cwd().openFileZ(src_path, .{}) catch unreachable;
        defer src.close();
        const dst = std.fs.cwd().createFileZ(trunc_path, .{ .truncate = true }) catch unreachable;
        defer dst.close();

        var copy_buf: [4096]u8 = undefined;
        var copied: u64 = 0;
        while (copied < file_size) {
            const want: usize = @intCast(@min(copy_buf.len, file_size - copied));
            const n = std.posix.pread(src.handle, copy_buf[0..want], copied) catch unreachable;
            if (n == 0) break;
            _ = std.posix.pwrite(dst.handle, copy_buf[0..n], copied) catch unreachable;
            copied += n;
        }
        const trunc_at: u64 = if (file_size == 0) 0 else prng.range_inclusive(u64, 0, file_size);
        std.posix.ftruncate(dst.handle, trunc_at) catch unreachable;

        // First recovery — record pending state.
        var pending_a = Wal.PendingIndex{};
        var wal_a = Wal.init(trunc_path, &pending_a);

        // (1) Structural invariants.
        pending_a.invariants();

        // (2) Negative-space bound — truncation can drop entries, not invent them.
        assert(pending_a.pending_count() <= entries_written);

        // (3) Pending ops fit inside the recovered op space.
        for (pending_a.entries[0..pending_a.len]) |*e| {
            assert(e.op <= wal_a.op);
        }
        // Snapshot the recovered values before tearing wal_a down — Wal.deinit
        // poisons the struct (`wal.* = undefined`), so reading `wal_a.op`
        // after deinit returns 0xAA garbage rather than the real op.
        const op_a = wal_a.op;
        const pending_a_snap = pending_a;
        wal_a.deinit();

        // (4) Determinism — second cold start produces identical pending state.
        var pending_b = Wal.PendingIndex{};
        var wal_b = Wal.init(trunc_path, &pending_b);
        defer wal_b.deinit();
        assert(wal_b.op == op_a);
        assert(pending_b.pending_count() == pending_a_snap.pending_count());
        for (pending_a_snap.entries[0..pending_a_snap.len], pending_b.entries[0..pending_b.len]) |*ea, *eb| {
            assert(ea.op == eb.op);
            assert(ea.name_len == eb.name_len);
            assert(ea.args_len == eb.args_len);
        }

        ok_truncations += 1;
    }

    log.info("Replay crash-restart done: truncations={d} all equivalent + deterministic", .{ok_truncations});
    assert(ok_truncations == trunc_offsets);
}
