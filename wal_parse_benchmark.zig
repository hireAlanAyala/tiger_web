//! WAL body-parse primitive benchmark.
//!
//! **Port:** `cp` of TigerBeetle's `src/vsr/checksum_benchmark.zig`,
//! trimmed. Diff against TB's file is the audit trail.
//!
//! **Edits vs TB's original:**
//!
//!   - Import paths rewritten for our layout (principled).
//!   - Kernel: `checksum(blob)` → `Wal.skip_writes_section` +
//!     loop of `parse_one_dispatch` (principled — our domain).
//!   - `cache_line_size` + arena + `alignedAlloc` + `prng.fill`
//!     removed (principled — body is a stack `[512]u8` built
//!     deterministically by `build_body`).
//!   - `blob_size` parameter + `KiB`/`MiB` removed (principled —
//!     WAL body shape is fixed by the entry layout; parametric
//!     size would measure a different property).
//!   - Counter `u128` → `u64` (principled).
//!   - Report format per DR-2.
//!   - Pair-assertions added (flaw fix — TIGER_STYLE golden rule):
//!     positive round-trip recovers the dispatch names we encoded;
//!     negative truncated-header probe must return null.
//!   - `bench.assert_budget` call (flaw fix — documented in
//!     `framework/bench.zig`).
//!   - `build_body` helper added — ours, not transplanted (WAL
//!     layout is ours). Off-hot-path, called once at test start.
//!
//! **External commitment:** WAL entry body format is on-disk. Every
//! existing WAL was encoded with this layout; changing the parser
//! without a migration breaks recovery.
//!
//! **Actionability:** if ns/entry rises >10%, check whether the
//! entry body format gained fields or parsing loops added
//! validation. Recovery time scales as entries × ns/entry. If the
//! positive pair-assertion fires, the on-disk format changed —
//! coordinate migration. If the *negative* pair-assertion fires,
//! the parser is accepting malformed entries — correctness
//! regression. If ns/entry drops sharply, verify a bounds check
//! wasn't removed (e.g., `worker_name_max` / `worker_args_max`
//! guards).
//!
//! **Budget:** `docs/internal/benchmark-budgets.md#wal_parse_benchmarkzig`
//! holds the 3-run calibration. Phase F regenerates on `ubuntu-22.04`.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const message = @import("message.zig");
const Wal = @import("framework/wal.zig").WalType(message.Operation);
const parse_one_dispatch = @import("framework/pending_dispatch.zig").parse_one_dispatch;

const repetitions = 35;

const write_count: u8 = 3;
const dispatch_count: u8 = 2;

// Budget — see docs/internal/benchmark-budgets.md.
const budget_ns_smoke_max: stdx.Duration = .{ .ns = 2_000 };

test "benchmark: wal_parse" {
    var bench: Bench = .init();
    defer bench.deinit();

    var body_buffer: [512]u8 = undefined;
    const body_len = build_body(&body_buffer);
    const body = body_buffer[0..body_len];

    // Pair-assertion — positive: round-trip recovers the encoded names.
    {
        const dispatch_start = Wal.skip_writes_section(body, write_count) orelse
            std.debug.panic("wal_parse: skip_writes_section rejected known-good body", .{});
        assert(dispatch_start <= body.len);

        var pos = dispatch_start;
        const first = parse_one_dispatch(body, &pos) orelse
            std.debug.panic("wal_parse: first dispatch missing", .{});
        assert(std.mem.eql(u8, first.name, "charge_payment"));
        const second = parse_one_dispatch(body, &pos) orelse
            std.debug.panic("wal_parse: second dispatch missing", .{});
        assert(std.mem.eql(u8, second.name, "send_email"));
        assert(parse_one_dispatch(body, &pos) == null);
    }

    // Pair-assertion — negative: truncated header (declared name_len
    // exceeds remaining bytes) must return null.
    {
        var truncated: [3]u8 = undefined;
        truncated[0] = 200;
        truncated[1] = 'x';
        truncated[2] = 'y';
        var pos: usize = 0;
        if (parse_one_dispatch(&truncated, &pos) != null) {
            std.debug.panic("wal_parse: truncated dispatch accepted", .{});
        }
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var parse_counter_sum: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        const dispatch_start = Wal.skip_writes_section(body, write_count) orelse unreachable;
        var pos = dispatch_start;
        while (parse_one_dispatch(body, &pos)) |_| {
            parse_counter_sum +%= 1;
        }
        duration.* = bench.stop();
    }

    const result = bench.estimate(&duration_samples);

    bench.report("parsed {d} dispatches", .{parse_counter_sum});
    bench.report("wal_parse = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_ns_smoke_max, "wal_parse");
}

// Off-hot-path body construction. Body layout per
// `framework/wal.zig:skip_writes_section` +
// `framework/pending_dispatch.zig:parse_one_dispatch`.
fn build_body(buffer: *[512]u8) usize {
    var pos: usize = 0;

    const writes = [_]struct { sql: []const u8, name: []const u8 }{
        .{ .sql = "INSERT INTO products (id, name) VALUES (?, ?)", .name = "apple" },
        .{ .sql = "UPDATE inventory SET qty = qty - ? WHERE id = ?", .name = "banana" },
        .{ .sql = "INSERT INTO ledger (account, amount) VALUES (?, ?)", .name = "cherry" },
    };
    assert(writes.len == write_count);

    for (writes) |w| {
        std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(w.sql.len), .big);
        pos += 2;
        @memcpy(buffer[pos..][0..w.sql.len], w.sql);
        pos += w.sql.len;

        buffer[pos] = 2; // param_count
        pos += 1;

        buffer[pos] = 0x01; // int tag
        pos += 1;
        std.mem.writeInt(u64, buffer[pos..][0..8], 42, .big);
        pos += 8;

        buffer[pos] = 0x03; // text tag
        pos += 1;
        std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(w.name.len), .big);
        pos += 2;
        @memcpy(buffer[pos..][0..w.name.len], w.name);
        pos += w.name.len;
    }

    const dispatches = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "charge_payment", .args = "customer=42;amount=9999" },
        .{ .name = "send_email", .args = "template=receipt;id=42" },
    };
    assert(dispatches.len == dispatch_count);

    for (dispatches) |d| {
        buffer[pos] = @intCast(d.name.len);
        pos += 1;
        @memcpy(buffer[pos..][0..d.name.len], d.name);
        pos += d.name.len;

        std.mem.writeInt(u16, buffer[pos..][0..2], @intCast(d.args.len), .big);
        pos += 2;
        @memcpy(buffer[pos..][0..d.args.len], d.args);
        pos += d.args.len;
    }

    assert(pos < buffer.len);
    return pos;
}
