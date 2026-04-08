//! Row format fuzzer — generates random row sets, serializes them to the
//! binary row format, deserializes back, and asserts round-trip agreement.
//!
//! The format is driven by what the fuzzer exercises. Every code path in
//! write_row_set_header, write_value, read_row_set_header, read_value
//! must be reachable by some seed.
//!
//! Follows TigerBeetle's fuzz pattern: library called by fuzz_tests.zig.

const std = @import("std");
const assert = std.debug.assert;
const protocol = @import("protocol.zig");
const FuzzArgs = @import("fuzz_lib.zig").FuzzArgs;
const PRNG = @import("stdx").PRNG;

const log = std.log.scoped(.fuzz);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    var stats = Stats{};

    for (0..events_max) |_| {
        const event = prng.chances(.{
            .valid_row_set = 8,
            .empty_row_set = 2,
            .single_value = 4,
            .max_columns = 1,
            .corrupt_read = 3,
            .skip_params = 3,
        });

        switch (event) {
            .valid_row_set => fuzz_valid_row_set(allocator, &prng, &stats),
            .empty_row_set => fuzz_empty_row_set(&stats),
            .single_value => fuzz_single_value(&prng, &stats),
            .max_columns => fuzz_max_columns(&prng, &stats),
            .corrupt_read => fuzz_corrupt_read(&prng, &stats),
            .skip_params => fuzz_skip_params(&prng, &stats),
        }
    }

    log.info(
        \\Row format fuzz done:
        \\  events={}
        \\  valid_row_sets={} empty={} single_values={}
        \\  max_columns={} corrupt_reads={} corrupt_rejected={}
        \\  skip_params_valid={} skip_params_rejected={}
    , .{
        events_max,
        stats.valid_row_sets,
        stats.empty_row_sets,
        stats.single_values,
        stats.max_columns,
        stats.corrupt_reads,
        stats.corrupt_rejected,
        stats.skip_params_valid,
        stats.skip_params_rejected,
    });

    // Sanity: we exercised all paths.
    assert(stats.valid_row_sets > 0);
    assert(stats.single_values > 0);
    assert(stats.corrupt_reads > 0);
    assert(stats.skip_params_valid > 0);
    assert(stats.skip_params_rejected > 0);
}

const Stats = struct {
    valid_row_sets: u64 = 0,
    empty_row_sets: u64 = 0,
    single_values: u64 = 0,
    max_columns: u64 = 0,
    corrupt_reads: u64 = 0,
    corrupt_rejected: u64 = 0,
    skip_params_valid: u64 = 0,
    skip_params_rejected: u64 = 0,
};

// =====================================================================
// Fuzz: valid row set round trip
// =====================================================================

fn fuzz_valid_row_set(allocator: std.mem.Allocator, prng: *PRNG, stats: *Stats) void {
    stats.valid_row_sets += 1;

    const col_count = prng.range_inclusive(u16, 1, 8);
    var columns: [protocol.columns_max]protocol.Column = undefined;
    var col_names: [protocol.columns_max][protocol.column_name_max]u8 = undefined;

    for (0..col_count) |i| {
        // Occasionally test max-length names.
        const name_len = if (prng.chance(.{ .numerator = 1, .denominator = 20 }))
            protocol.column_name_max
        else
            prng.range_inclusive(usize, 1, @min(31, protocol.column_name_max));
        for (0..name_len) |j| {
            col_names[i][j] = prng.range_inclusive(u8, 'a', 'z');
        }
        columns[i] = .{
            .type_tag = random_type_tag(prng),
            .name = col_names[i][0..name_len],
        };
    }

    const row_count = prng.range_inclusive(u32, 0, 10);

    // Generate random values for each cell.
    // Heap-allocated backing — allows full cell_value_max testing in row sets.
    const max_cells = 10 * 8;
    var values: [max_cells]protocol.Value = undefined;

    // Allocate one contiguous backing block for all cell data.
    const backing_block = allocator.alloc(u8, max_cells * protocol.cell_value_max) catch return;
    defer allocator.free(backing_block);

    for (0..row_count) |r| {
        for (0..col_count) |c| {
            const idx = r * col_count + c;
            const offset = idx * protocol.cell_value_max;
            values[idx] = random_value_bounded(prng, columns[c].type_tag, backing_block[offset..][0..protocol.cell_value_max]);
        }
    }

    // Serialize into heap buffer (frame_max may be large).
    const buf = allocator.alloc(u8, protocol.frame_max) catch return;
    defer allocator.free(buf);
    var pos = protocol.write_row_set_header(buf, columns[0..col_count]) orelse {
        // Buffer too small for this combination — skip.
        return;
    };
    pos = protocol.write_row_count(buf, pos, row_count) orelse return;

    for (0..row_count) |r| {
        for (0..col_count) |c| {
            pos = protocol.write_value(buf, pos, values[r * col_count + c]) orelse return;
        }
    }

    // Deserialize and assert agreement.
    const hdr = protocol.read_row_set_header(buf, 0) orelse unreachable;
    assert(hdr.count == col_count);

    for (0..col_count) |i| {
        assert(std.mem.eql(u8, hdr.columns[i].name, columns[i].name));
        assert(hdr.columns[i].type_tag == columns[i].type_tag);
    }

    const rc = protocol.read_row_count(buf, hdr.pos) orelse unreachable;
    assert(rc.count == row_count);

    var rpos = rc.pos;
    for (0..row_count) |r| {
        for (0..col_count) |c| {
            const idx = r * col_count + c;
            const result = protocol.read_value(buf, rpos, columns[c].type_tag) orelse unreachable;
            assert_value_equal(values[idx], result.value);
            rpos = result.pos;
        }
    }

    // Positions must match.
    assert(rpos == pos);
}

// =====================================================================
// Fuzz: empty row set (0 columns, 0 rows)
// =====================================================================

fn fuzz_empty_row_set(stats: *Stats) void {
    stats.empty_row_sets += 1;

    var buf: [64]u8 = undefined;
    const empty_cols = [_]protocol.Column{};
    const pos = protocol.write_row_set_header(&buf, &empty_cols) orelse unreachable;
    const write_end = protocol.write_row_count(&buf, pos, 0) orelse unreachable;

    const hdr = protocol.read_row_set_header(&buf, 0) orelse unreachable;
    assert(hdr.count == 0);

    const rc = protocol.read_row_count(&buf, hdr.pos) orelse unreachable;
    assert(rc.count == 0);
    assert(rc.pos == write_end);
}

// =====================================================================
// Fuzz: single value round trip for each type
// =====================================================================

fn fuzz_single_value(prng: *PRNG, stats: *Stats) void {
    stats.single_values += 1;

    const tag = random_type_tag(prng);
    var backing: [protocol.cell_value_max]u8 = undefined;
    const value = random_value_bounded(prng, tag, &backing);

    // Worst case: cell_value_max text/blob + 2 byte length prefix.
    var buf: [protocol.cell_value_max + 8]u8 = undefined;
    const pos = protocol.write_value(&buf, 0, value) orelse unreachable;
    const result = protocol.read_value(&buf, 0, tag) orelse unreachable;
    assert(result.pos == pos);
    assert_value_equal(value, result.value);
}

// =====================================================================
// Fuzz: max columns row set
// =====================================================================

fn fuzz_max_columns(prng: *PRNG, stats: *Stats) void {
    stats.max_columns += 1;

    var columns: [protocol.columns_max]protocol.Column = undefined;
    var col_names: [protocol.columns_max][4]u8 = undefined;

    for (0..protocol.columns_max) |i| {
        col_names[i][0] = 'c';
        col_names[i][1] = @intCast('0' + @as(u8, @intCast(i / 10)));
        col_names[i][2] = @intCast('0' + @as(u8, @intCast(i % 10)));
        col_names[i][3] = 0;
        columns[i] = .{
            .type_tag = random_type_tag(prng),
            .name = col_names[i][0..3],
        };
    }

    var buf: [protocol.frame_max]u8 = undefined;
    const pos = protocol.write_row_set_header(&buf, &columns) orelse unreachable;
    const hdr = protocol.read_row_set_header(&buf, 0) orelse unreachable;
    assert(hdr.count == protocol.columns_max);
    assert(hdr.pos == pos);
}

// =====================================================================
// Fuzz: corrupt read — random bytes, must not crash
// =====================================================================

fn fuzz_corrupt_read(prng: *PRNG, stats: *Stats) void {
    stats.corrupt_reads += 1;

    // Occasionally use a larger buffer to exercise max-boundary checks.
    var small_buf: [256]u8 = undefined;
    var large_buf: [8192]u8 = undefined;
    const use_large = prng.chance(.{ .numerator = 1, .denominator = 5 });
    const buf: []u8 = if (use_large) &large_buf else &small_buf;
    prng.fill(buf);

    // Try to read as header — must return null or a valid result, never crash.
    if (protocol.read_row_set_header(buf, 0)) |hdr| {
        // If it parsed, try reading values with the claimed column types.
        if (protocol.read_row_count(buf, hdr.pos)) |rc| {
            var rpos = rc.pos;
            var valid = true;
            for (0..@min(rc.count, 3)) |_| {
                for (0..hdr.count) |c| {
                    if (protocol.read_value(buf, rpos, hdr.columns[c].type_tag)) |result| {
                        rpos = result.pos;
                    } else {
                        valid = false;
                        break;
                    }
                }
                if (!valid) break;
            }
        }
    } else {
        stats.corrupt_rejected += 1;
    }

    // Also try reading random type tags.
    const tag_byte = prng.range_inclusive(u8, 0, 0xFF);
    if (std.meta.intToEnum(protocol.TypeTag, tag_byte)) |tag| {
        _ = protocol.read_value(buf, 0, tag);
    } else |_| {
        stats.corrupt_rejected += 1;
    }
}

// =====================================================================
// Helpers
// =====================================================================

fn random_type_tag(prng: *PRNG) protocol.TypeTag {
    return prng.enum_uniform(protocol.TypeTag);
}

fn random_value_bounded(prng: *PRNG, tag: protocol.TypeTag, backing: []u8) protocol.Value {
    const max = @min(backing.len, protocol.cell_value_max);
    return switch (tag) {
        .integer => .{ .integer = @bitCast(prng.int(u64)) },
        .float => .{ .float = @bitCast(prng.int(u64)) },
        .text => blk: {
            // Occasionally test near-max values.
            const len = if (max > 64 and prng.chance(.{ .numerator = 1, .denominator = 20 }))
                max
            else
                prng.range_inclusive(usize, 0, @min(255, max));
            for (0..len) |i| backing[i] = prng.range_inclusive(u8, 0x20, 0x7e);
            break :blk .{ .text = backing[0..len] };
        },
        .blob => blk: {
            const len = if (max > 64 and prng.chance(.{ .numerator = 1, .denominator = 20 }))
                max
            else
                prng.range_inclusive(usize, 0, @min(255, max));
            prng.fill(backing[0..len]);
            break :blk .{ .blob = backing[0..len] };
        },
        .null => .{ .null = {} },
    };
}

fn assert_value_equal(expected: protocol.Value, actual: protocol.Value) void {
    assert(@intFromEnum(expected) == @intFromEnum(actual));
    switch (expected) {
        .integer => |v| assert(actual.integer == v),
        .float => |v| {
            // Bit-exact comparison (not approximate) — round-trip must be exact.
            assert(@as(u64, @bitCast(actual.float)) == @as(u64, @bitCast(v)));
        },
        .text => |v| assert(std.mem.eql(u8, actual.text, v)),
        .blob => |v| assert(std.mem.eql(u8, actual.blob, v)),
        .null => {},
    }
}

/// Fuzz skip_params: generate random param sequences (valid and corrupt),
/// assert it either returns a valid position or null — never crashes.
fn fuzz_skip_params(prng: *PRNG, stats: *Stats) void {
    var buf: [512]u8 = undefined;
    const TypeTag = protocol.TypeTag;

    // Decide: valid params or random garbage.
    if (prng.boolean()) {
        // Build valid params.
        var pos: usize = 0;
        const count = prng.range_inclusive(u8, 0, 8);
        for (0..count) |_| {
            if (pos >= buf.len - 11) break; // room for tag + max value
            const tag_choice = prng.range_inclusive(u8, 0, 4);
            switch (tag_choice) {
                0 => { // integer
                    buf[pos] = @intFromEnum(TypeTag.integer);
                    pos += 1;
                    std.mem.writeInt(u64, buf[pos..][0..8], prng.int(u64), .little);
                    pos += 8;
                },
                1 => { // float
                    buf[pos] = @intFromEnum(TypeTag.float);
                    pos += 1;
                    std.mem.writeInt(u64, buf[pos..][0..8], prng.int(u64), .little);
                    pos += 8;
                },
                2 => { // text — occasionally test large lengths to hit u16 boundary.
                    const tlen = if (prng.boolean()) prng.range_inclusive(u16, 0, 32) else prng.range_inclusive(u16, 0, 512);
                    buf[pos] = @intFromEnum(TypeTag.text);
                    pos += 1;
                    if (pos + 2 + tlen > buf.len) break;
                    std.mem.writeInt(u16, buf[pos..][0..2], tlen, .big);
                    pos += 2;
                    for (0..tlen) |j| {
                        buf[pos + j] = prng.range_inclusive(u8, 0x20, 0x7e);
                    }
                    pos += tlen;
                },
                3 => { // blob — occasionally test large lengths.
                    const blen = if (prng.boolean()) prng.range_inclusive(u16, 0, 32) else prng.range_inclusive(u16, 0, 512);
                    buf[pos] = @intFromEnum(TypeTag.blob);
                    pos += 1;
                    if (pos + 2 + blen > buf.len) break;
                    std.mem.writeInt(u16, buf[pos..][0..2], blen, .big);
                    pos += 2;
                    pos += blen;
                },
                else => { // null
                    buf[pos] = @intFromEnum(TypeTag.null);
                    pos += 1;
                },
            }
        }
        const result = protocol.skip_params(&buf, 0, count);
        if (result) |end_pos| {
            // Exact consumption: skip_params must land at the end of what we built.
            assert(end_pos == pos);
            stats.skip_params_valid += 1;
        } else {
            stats.skip_params_rejected += 1;
        }
    } else {
        // Random garbage bytes.
        const len = prng.range_inclusive(usize, 0, buf.len);
        for (0..len) |i| buf[i] = prng.int(u8);
        const count = prng.int(u8);
        const start = prng.range_inclusive(usize, 0, len);
        // Must not crash — either returns valid position or null.
        const result = protocol.skip_params(buf[0..len], start, count);
        if (result) |end_pos| {
            assert(end_pos >= start);
            assert(end_pos <= len);
            stats.skip_params_valid += 1;
        } else {
            stats.skip_params_rejected += 1;
        }
    }
}
