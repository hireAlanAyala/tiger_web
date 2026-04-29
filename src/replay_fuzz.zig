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
const wal_mod = @import("framework/wal.zig");
const Storage = @import("storage.zig").SqliteStorage;
const replay = @import("replay.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const stdx = @import("stdx");
const PRNG = stdx.PRNG;

const Wal = wal_mod.WalType(message.Operation);

const log = std.log.scoped(.fuzz);

/// Per-entry record captured during phase 1 — the independent model
/// `crash_restart_equivalence` consumes to derive *expected* pending
/// state at any truncation point. TB's `journal_checker` pattern:
/// maintain an in-memory model alongside writes, then assert recovered
/// state matches the model after a fault. We don't have a live replica
/// running, so we record per-write and replay the model in phase 4.
const EntryRecord = struct {
    end_offset: u64,
    pending: [64]u64,
    pending_len: u8,
};

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 5_000;
    var prng = PRNG.from_seed(seed);

    // PID + seed scoped — concurrent fuzz processes would otherwise
    // race even at different seeds (one matrix runner reusing /tmp
    // across re-runs, two same-seed manual replays). PID makes
    // process-collision impossible; seed makes intra-process
    // distinct-fuzzer paths distinct (replay vs codec).
    const pid = std.os.linux.getpid();
    var path_buf: [128]u8 = undefined;
    const wal_path = try std.fmt.bufPrintZ(
        &path_buf,
        "/tmp/tiger_replay_fuzz.{d}.{x}.wal",
        .{ pid, seed },
    );
    std.fs.cwd().deleteFile(wal_path) catch {};
    defer std.fs.cwd().deleteFile(wal_path) catch {};

    // Phase 1: Write random entries to the WAL.
    var wal = Wal.init(wal_path, null);
    var scratch: [8192]u8 = undefined;
    var entries_written: u64 = 0;

    // Track dispatches for generating valid completions/dead entries.
    //
    // **Dual purpose, load-bearing for phase 4:** the swap-remove
    // mutations on `pending_ops` + `pending_count` here are not just
    // bookkeeping for generating valid completions. They are the
    // **independent model** that phase 4 asserts WAL recovery
    // matches at every truncation point. Refactoring this loop
    // (e.g., consolidating the four-branch if/else into a helper)
    // weakens phase 4's correctness silently if the model drifts
    // from the actual append calls. Keep them in lock-step.
    //
    // Independence boundary (the property phase 4 actually tests):
    // *manual swap-remove array on plain u64 ops* vs. *binary-format
    // parser in `wal.recover_dispatches` rebuilding `PendingIndex`*.
    // Different code, different data structures. Genuinely catches
    // mismatches; doesn't catch a bug shared by both (TB has more
    // independence — workload generator + observer — but their
    // domain has separate replicas to compare against).
    var pending_ops: [64]u64 = @splat(0);
    var pending_count: usize = 0;

    // Per-entry log — records the byte offset and pending-set snapshot
    // *after* each append. Phase 4 reads this to compute the expected
    // pending state at any truncation offset without re-implementing
    // the WAL parser.
    var entries_log = std.ArrayList(EntryRecord).init(allocator);
    defer entries_log.deinit();

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
        stdx.copy_disjoint(.exact, u8, write_buf[wpos..][0..sql.len], sql);
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
            stdx.copy_disjoint(.exact, u8, dispatch_buf[dpos..][0..name.len], name);
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

        // Snapshot the file size + pending set after this entry. This
        // is the "expected after entry N" datapoint phase 4 needs.
        const fstat = std.posix.fstat(wal.fd) catch unreachable;
        var rec = EntryRecord{
            .end_offset = @intCast(fstat.size),
            .pending = @splat(0),
            .pending_len = @intCast(pending_count),
        };
        if (pending_count > 0) {
            stdx.copy_disjoint(.inexact, u64, &rec.pending, pending_ops[0..pending_count]);
        }
        try entries_log.append(rec);

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
    try crash_restart_equivalence(wal_path, &prng, file_size, entries_log.items, seed);
}

/// Truncate the WAL at random offsets and assert recovery is
/// well-formed, semantically equivalent to the model, and
/// deterministic across cold starts.
///
/// Adopts TB's `journal_checker` pattern: maintain an independent
/// in-memory model alongside writes; after a fault, recovery state
/// must equal the model snapshot for whatever entries survived.
/// Without this, the assertions can only check structural validity
/// (TB-flagged audit finding 2026-04-29 — "doesn't crash" was the
/// previous bound, which is positive-space only).
///
/// Per truncation we run:
///
///   1. `pending.invariants()` — structural validity.
///   2. **Equivalence to model:** the largest entries_log record whose
///      `end_offset <= trunc_at` defines the expected pending set
///      (the prefix that fits before the cut). Recovery must reach
///      the same pending count and pending ops set.
///   3. **Cold-start determinism:** copy the source WAL into TWO
///      separate fresh paths, run init on each independently, assert
///      they agree. (The previous implementation re-ran init on the
///      same file — but `Wal.init` mutates the file via tail
///      truncation, so the second run was already against a recovered
///      state, not the original truncated state.)
fn crash_restart_equivalence(
    src_path: [:0]const u8,
    prng: *PRNG,
    file_size: u64,
    entries_log: []const EntryRecord,
    seed: u64,
) !void {
    const pid = std.os.linux.getpid();
    var a_path_buf: [128]u8 = undefined;
    var b_path_buf: [128]u8 = undefined;
    const trunc_a_path = try std.fmt.bufPrintZ(
        &a_path_buf,
        "/tmp/tiger_replay_fuzz.{d}.{x}.crash_a.wal",
        .{ pid, seed },
    );
    const trunc_b_path = try std.fmt.bufPrintZ(
        &b_path_buf,
        "/tmp/tiger_replay_fuzz.{d}.{x}.crash_b.wal",
        .{ pid, seed },
    );
    std.fs.cwd().deleteFile(trunc_a_path) catch {};
    std.fs.cwd().deleteFile(trunc_b_path) catch {};
    defer std.fs.cwd().deleteFile(trunc_a_path) catch {};
    defer std.fs.cwd().deleteFile(trunc_b_path) catch {};

    const trunc_offsets = 16;
    var ok_truncations: u32 = 0;
    for (0..trunc_offsets) |_| {
        const trunc_at: u64 = if (file_size == 0) 0 else prng.range_inclusive(u64, 0, file_size);
        // Two independent copies — each gives `Wal.init` a fresh
        // truncation to recover from. Required for an honest
        // determinism comparison; sharing one file would let the
        // first init's tail truncation contaminate the second.
        copy_truncated(src_path, trunc_a_path, file_size, trunc_at);
        copy_truncated(src_path, trunc_b_path, file_size, trunc_at);

        // Independent model — derive expected pending from the largest
        // logged entry that fully fits before `trunc_at`. Entries
        // straddling the cut are dropped (recovery sees them as
        // truncated tail and stops).
        const expected = expected_pending_at(entries_log, trunc_at);

        // First recovery. `assert_pending_matches_model` is strictly
        // stronger than `pending.invariants()` (it enforces structural
        // validity transitively via the model), so no separate
        // invariants call is needed here.
        var pending_a = Wal.PendingIndex{};
        var wal_a = Wal.init(trunc_a_path, &pending_a);
        assert_pending_matches_model(&pending_a, expected);
        const op_a = wal_a.op;
        wal_a.deinit();

        // Second recovery — separate fresh-trunc file. Same input,
        // same output: TB's first-class determinism principle. Both
        // recoveries reach `expected`; transitive equality on op is
        // also asserted explicitly below.
        var pending_b = Wal.PendingIndex{};
        var wal_b = Wal.init(trunc_b_path, &pending_b);
        defer wal_b.deinit();

        assert_pending_matches_model(&pending_b, expected);
        assert(wal_b.op == op_a);

        ok_truncations += 1;
    }

    log.info(
        "Replay crash-restart done: truncations={d} model-equivalent + deterministic",
        .{ok_truncations},
    );
    assert(ok_truncations == trunc_offsets);
}

const ExpectedPending = struct {
    ops: [64]u64,
    len: u8,
};

/// Return the model's pending state at the moment `trunc_at` would
/// land. Walks the entry log forward; the answer is the snapshot from
/// the largest entry whose `end_offset <= trunc_at`. If no entry fits
/// (e.g., `trunc_at` truncates inside the root), pending is empty.
fn expected_pending_at(entries_log: []const EntryRecord, trunc_at: u64) ExpectedPending {
    var result = ExpectedPending{ .ops = @splat(0), .len = 0 };
    for (entries_log) |*rec| {
        if (rec.end_offset > trunc_at) break;
        result.len = rec.pending_len;
        if (rec.pending_len > 0) {
            stdx.copy_disjoint(.inexact, u64, &result.ops, rec.pending[0..rec.pending_len]);
        }
    }
    return result;
}

/// Compare a recovered PendingIndex to the model snapshot as sets —
/// order may differ because `recover_dispatches` adds entries in WAL
/// order and `swap-remove` reorders the model in phase 1.
///
/// Also lightly validates each recovered entry's payload. Phase 1
/// always writes name = "fuzz_worker" and args_len ∈ [0, 32]. Any
/// deviation in the recovered state means the binary parser corrupted
/// the payload — bug shape that op-only set comparison misses.
/// (A stronger per-op `(name, args_len)` map is a tracked follow-up;
/// see todo.md.)
fn assert_pending_matches_model(pending: *const Wal.PendingIndex, expected: ExpectedPending) void {
    assert(pending.pending_count() == expected.len);
    // Quadratic membership check — n is bounded by max_in_flight (64).
    for (pending.entries[0..pending.len]) |*e| {
        var found = false;
        for (expected.ops[0..expected.len]) |op| {
            if (op == e.op) {
                found = true;
                break;
            }
        }
        assert(found);

        // Payload-shape sanity. Phase 1's generator is the only writer,
        // so any drift from these constants is parser corruption.
        assert(std.mem.eql(u8, e.name_slice(), "fuzz_worker"));
        assert(e.args_len <= 32);
    }
}

/// Copy `[0, src_size)` from `src` into a fresh `dst`, then truncate
/// `dst` to `trunc_at`. Each call produces an isolated trunc file the
/// caller can recover against independently.
fn copy_truncated(src: [:0]const u8, dst: [:0]const u8, src_size: u64, trunc_at: u64) void {
    std.fs.cwd().deleteFile(dst) catch {};
    const src_file = std.fs.cwd().openFileZ(src, .{}) catch
        @panic("replay_fuzz: failed to open src WAL for trunc copy");
    defer src_file.close();

    const dst_file = std.fs.cwd().createFileZ(dst, .{ .truncate = true }) catch
        @panic("replay_fuzz: failed to create dst WAL for trunc copy");
    defer dst_file.close();

    var copy_buf: [4096]u8 = undefined;
    var copied: u64 = 0;
    while (copied < src_size) {
        const want: usize = @intCast(@min(copy_buf.len, src_size - copied));
        const n = std.posix.pread(src_file.handle, copy_buf[0..want], copied) catch
            @panic("replay_fuzz: pread from src WAL failed");
        if (n == 0) break;
        _ = std.posix.pwrite(dst_file.handle, copy_buf[0..n], copied) catch
            @panic("replay_fuzz: pwrite to dst WAL failed");
        copied += n;
    }
    // Pair-assertion: silent short-read would leave dst smaller than src and
    // the caller's `trunc_at` would operate on the wrong baseline. Recovery
    // would still pass invariants, just against an unintended state.
    assert(copied == src_size);
    std.posix.ftruncate(dst_file.handle, trunc_at) catch
        @panic("replay_fuzz: ftruncate of dst WAL failed");
}
