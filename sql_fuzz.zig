//! db.sql() fuzz test — exercises the raw SQL interface with random
//! operations, parameter combinations, and column reads.
//!
//! Verifies:
//! - No crashes on any valid SQL + param combination
//! - Insert → select round-trips preserve data (u128, text, integers, bools)
//! - Column readers handle all stored values correctly
//! - QueryResult lifecycle (next/finish) is correct
//! - Empty result sets handled
//!
//! The db.sql() interface is the boundary between user-provided SQL and
//! the SQLite C API — the most dangerous surface in the framework.

const std = @import("std");
const assert = std.debug.assert;
const PRNG = @import("tiger_framework").prng;
const SqliteStorage = @import("storage.zig").SqliteStorage;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzArgs = fuzz_lib.FuzzArgs;

const log = std.log.scoped(.fuzz);

pub fn main(_: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var storage = try SqliteStorage.init(":memory:");
    defer storage.deinit();

    // Create a test table with all column types we support.
    {
        var result = storage.sql(
            "CREATE TABLE fuzz_test (" ++
                "id BLOB NOT NULL, " ++
                "name TEXT NOT NULL, " ++
                "description TEXT, " ++
                "price INTEGER NOT NULL, " ++
                "count INTEGER NOT NULL, " ++
                "active INTEGER NOT NULL, " ++
                "timestamp INTEGER NOT NULL" ++
                ");",
            .{},
        ) orelse @panic("CREATE TABLE failed");
        assert(result.next() == .done);
        result.finish();
    }

    var inserted: u32 = 0;
    var queried: u32 = 0;
    var empty_results: u32 = 0;
    var round_trips: u32 = 0;

    for (0..events_max) |_| {
        const action = prng.range_inclusive(u8, 0, 5);
        switch (action) {
            0, 1 => {
                // Insert a random row.
                const id = prng.int(u128);
                const name = random_text(&prng);
                const desc = random_text(&prng);
                const price = prng.int(u32);
                const count = prng.int(u32);
                const active = prng.boolean();
                const timestamp = @as(i64, @intCast(prng.range_inclusive(u32, 0, 2_000_000_000)));

                var result = storage.sql(
                    "INSERT INTO fuzz_test (id, name, description, price, count, active, timestamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
                    .{ id, @as([]const u8, &name.buf), @as([]const u8, &desc.buf), price, count, active, timestamp },
                ) orelse @panic("INSERT failed");
                assert(result.next() == .done);
                result.finish();
                inserted += 1;
            },
            2 => {
                // Select by random ID — may or may not exist.
                const id = prng.int(u128);
                var result = storage.sql(
                    "SELECT id, name, price, count, active, timestamp FROM fuzz_test WHERE id = ?1;",
                    .{id},
                ) orelse @panic("SELECT failed");
                defer result.finish();

                const step = result.next();
                if (step == .row) {
                    // Read all column types — must not crash.
                    const read_id = result.col_uuid(0);
                    _ = result.col_text(1);
                    _ = result.col_u32(2);
                    _ = result.col_u32(3);
                    _ = result.col_bool(4);
                    _ = result.col_i64(5);
                    assert(read_id == id); // pair assertion: queried by id, got same id back
                    queried += 1;
                } else {
                    assert(step == .done);
                    empty_results += 1;
                }
            },
            3 => {
                // Insert then immediately read back — full round-trip.
                const id = prng.int(u128);
                const name = random_text(&prng);
                const price = prng.int(u32);
                const count = prng.int(u32);
                const active = prng.boolean();
                const timestamp = @as(i64, @intCast(prng.range_inclusive(u32, 0, 2_000_000_000)));

                {
                    var result = storage.sql(
                        "INSERT INTO fuzz_test (id, name, description, price, count, active, timestamp) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
                        .{ id, @as([]const u8, &name.buf), @as([]const u8, ""), price, count, active, timestamp },
                    ) orelse @panic("INSERT failed");
                    assert(result.next() == .done);
                    result.finish();
                }

                {
                    var result = storage.sql(
                        "SELECT id, name, price, count, active, timestamp FROM fuzz_test WHERE id = ?1;",
                        .{id},
                    ) orelse @panic("SELECT after INSERT failed");
                    defer result.finish();

                    assert(result.next() == .row);
                    // Round-trip assertions — every value must survive the trip.
                    assert(result.col_uuid(0) == id);
                    const read_name = result.col_text(1);
                    assert(std.mem.eql(u8, read_name, &name.buf));
                    assert(result.col_u32(2) == price);
                    assert(result.col_u32(3) == count);
                    assert(result.col_bool(4) == active);
                    assert(result.col_i64(5) == timestamp);
                    // No second row.
                    assert(result.next() == .done);
                    round_trips += 1;
                }
            },
            4 => {
                // Count rows — exercises empty params and aggregate.
                var result = storage.sql("SELECT COUNT(*) FROM fuzz_test;", .{}) orelse @panic("COUNT failed");
                defer result.finish();
                assert(result.next() == .row);
                const count = result.col_i64(0);
                assert(count >= 0);
            },
            else => {
                // List with LIMIT — exercises multiple row iteration.
                const limit = prng.range_inclusive(u32, 1, 50);
                var result = storage.sql(
                    "SELECT id, name, price FROM fuzz_test LIMIT ?1;",
                    .{limit},
                ) orelse @panic("SELECT LIMIT failed");
                defer result.finish();

                var rows: u32 = 0;
                while (result.next() == .row) {
                    _ = result.col_uuid(0);
                    _ = result.col_text(1);
                    _ = result.col_u32(2);
                    rows += 1;
                    assert(rows <= limit);
                }
            },
        }
    }

    log.info("seed={d} events={d} inserted={d} queried={d} empty={d} round_trips={d}", .{
        seed, events_max, inserted, queried, empty_results, round_trips,
    });
}

const RandomText = struct {
    buf: [max_len]u8,
    len: u8,

    const max_len = 32;
};

fn random_text(prng: *PRNG) RandomText {
    var result = RandomText{ .buf = .{0} ** RandomText.max_len, .len = 0 };
    const len = prng.range_inclusive(u8, 1, RandomText.max_len);
    for (0..len) |i| {
        result.buf[i] = prng.range_inclusive(u8, 0x20, 0x7e); // printable ASCII
    }
    result.len = len;
    return result;
}
