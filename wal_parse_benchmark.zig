//! WAL body-parse primitive benchmark.
//!
//! **Port source:** `src/vsr/checksum_benchmark.zig` from TigerBeetle
//! (the cp-template for every primitive bench in phase C).
//!
//! **Survival:** ~22/43 lines of the template carry over (~50%). The
//! bench harness (Bench init/deinit, arena, sample loop, estimate,
//! hash-of-run print) is verbatim; the kernel, input shape, and
//! parameter are substituted.
//!
//! Substitutions relative to the template:
//!
//!   - Kernel: `checksum(blob)` → `Wal.skip_writes_section(body, n_writes)`
//!     followed by a loop of `parse_one_dispatch(body, &pos)`. This is
//!     the parse path exercised by every WAL recovery entry.
//!   - Input: PRNG-filled blob → pre-built in-memory body buffer with
//!     3 writes (SQL + params) + 2 dispatches (name + args). No IO.
//!   - Parameter: `bench.parameter("blob_size", KiB, MiB)` removed —
//!     the body shape is fixed per the WAL entry layout; varying
//!     lengths would measure a different thing.
//!   - Counter: `u128` checksum accumulator → `u64` parsed-entries
//!     counter (prevents dead-code elimination).
//!   - Report format: `"{} for whole blob"` →
//!     `"wal_parse = {d} ns"` (DR-2).
//!
//! Additions beyond the template (all principled):
//!
//!   - Pair-assertion at test start: parse round-trip against the
//!     known-good body. Both `skip_writes_section` and the dispatch
//!     loop must recover the exact dispatch names we encoded. If the
//!     on-disk format drifted, this fires before measurement.
//!   - `bench.assert_budget` call (same principled divergence
//!     documented in `framework/bench.zig`).
//!
//! **External commitment:** the WAL entry body format is on-disk.
//! Every existing WAL was encoded with this layout; changing the
//! parser without a migration breaks recovery. This bench protects
//! the parse throughput of that commitment — recovery time scales as
//! entries × ns/entry, so a 30% parse regression translates to 30%
//! slower startup on a large WAL.
//!
//! **Actionability:** if ns/entry rises >10%, check whether the WAL
//! entry body format gained fields or the parsing loops added
//! validation. If the pair assertion fires, the on-disk format
//! changed — coordinate migration before shipping. If ns/entry drops
//! sharply, verify a validation step wasn't removed (e.g., the
//! `worker_name_max`/`worker_args_max` bounds checks in
//! `parse_one_dispatch`).
//!
//! **Budget calibration:** 10 µs for one full-body parse.
//! Measured ~140 ns in Debug on dev machine (3 writes + 2 dispatches
//! of ~300 bytes). ~70× headroom — loose on purpose, because parse
//! cost grows linearly with write/dispatch counts and slow CI runners
//! may be 5× slower. Re-calibrate on ubuntu-22.04 in phase F.

const std = @import("std");
const assert = std.debug.assert;

const stdx = @import("stdx");

const Bench = @import("framework/bench.zig");

const message = @import("message.zig");
const Wal = @import("framework/wal.zig").WalType(message.Operation);
const parse_one_dispatch = @import("framework/pending_dispatch.zig").parse_one_dispatch;

const repetitions = 35;

const budget_smoke: stdx.Duration = .{ .ns = 10_000 }; // 10 µs per body parse

const write_count: u8 = 3;
const dispatch_count: u8 = 2;

test "benchmark: wal_parse" {
    var bench: Bench = .init();
    defer bench.deinit();

    var body_buf: [512]u8 = undefined;
    const body_len = build_body(&body_buf);
    const body = body_buf[0..body_len];

    // Pair-assertion: parse round-trip must recover exactly the dispatch
    // names we encoded. If this fires, the body format drifted.
    {
        const dispatch_start = Wal.skip_writes_section(body, write_count) orelse
            std.debug.panic("wal_parse: skip_writes_section rejected known-good body", .{});
        assert(dispatch_start <= body.len);

        var pos = dispatch_start;
        const first = parse_one_dispatch(body, &pos) orelse
            std.debug.panic("wal_parse: first dispatch missing", .{});
        if (!std.mem.eql(u8, first.name, "charge_payment")) {
            std.debug.panic("wal_parse: dispatch name mismatch: {s}", .{first.name});
        }
        const second = parse_one_dispatch(body, &pos) orelse
            std.debug.panic("wal_parse: second dispatch missing", .{});
        if (!std.mem.eql(u8, second.name, "send_email")) {
            std.debug.panic("wal_parse: dispatch name mismatch: {s}", .{second.name});
        }
        assert(parse_one_dispatch(body, &pos) == null); // exhausted
    }

    var duration_samples: [repetitions]stdx.Duration = undefined;
    var parse_counter: u64 = 0;

    for (&duration_samples) |*duration| {
        bench.start();
        const dispatch_start = Wal.skip_writes_section(body, write_count) orelse unreachable;
        var pos = dispatch_start;
        while (parse_one_dispatch(body, &pos)) |_| {
            parse_counter +%= 1;
        }
        duration.* = bench.stop();
    }

    const result = bench.estimate(&duration_samples);

    // Hash-of-run: total parsed dispatches across all reps. (repetitions
    // × dispatch_count). Printed on its own line, separate from the
    // parseable `wal_parse = ... ns` line.
    bench.report("parsed {d} dispatches", .{parse_counter});
    bench.report("wal_parse = {d} ns", .{result.ns});
    bench.assert_budget(result, budget_smoke, "wal_parse");
}

// ---------------------------------------------------------------------------
// Test body construction. Not on the hot path — only called once at test
// start. Shape:
//
//   writes ×3: [u16 sql_len][sql][u8 param_count=2][u8 tag=0x01][u64 int]
//                                               [u8 tag=0x03][u16 text_len][text]
//   dispatches ×2: [u8 name_len][name][u16 args_len][args]
//
// ---------------------------------------------------------------------------
fn build_body(buf: *[512]u8) usize {
    var pos: usize = 0;

    const writes = [_]struct { sql: []const u8, name: []const u8 }{
        .{ .sql = "INSERT INTO products (id, name) VALUES (?, ?)", .name = "apple" },
        .{ .sql = "UPDATE inventory SET qty = qty - ? WHERE id = ?", .name = "banana" },
        .{ .sql = "INSERT INTO ledger (account, amount) VALUES (?, ?)", .name = "cherry" },
    };
    assert(writes.len == write_count);

    for (writes) |w| {
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(w.sql.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..w.sql.len], w.sql);
        pos += w.sql.len;

        buf[pos] = 2; // param_count
        pos += 1;

        buf[pos] = 0x01; // int tag
        pos += 1;
        std.mem.writeInt(u64, buf[pos..][0..8], 42, .big);
        pos += 8;

        buf[pos] = 0x03; // text tag
        pos += 1;
        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(w.name.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..w.name.len], w.name);
        pos += w.name.len;
    }

    const dispatches = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = "charge_payment", .args = "customer=42;amount=9999" },
        .{ .name = "send_email", .args = "template=receipt;id=42" },
    };
    assert(dispatches.len == dispatch_count);

    for (dispatches) |d| {
        buf[pos] = @intCast(d.name.len);
        pos += 1;
        @memcpy(buf[pos..][0..d.name.len], d.name);
        pos += d.name.len;

        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(d.args.len), .big);
        pos += 2;
        @memcpy(buf[pos..][0..d.args.len], d.args);
        pos += d.args.len;
    }

    assert(pos < buf.len);
    return pos;
}
