//! WAL replay tool — reads SQL-write WAL entries.
//!
//! Commands:
//!   verify   Validate checksums and hash chain
//!   inspect  Print human-readable entry summaries
//!   replay   Re-execute SQL writes against a database
//!   query    Run SQL against a database after partial replay
//!
//! Each entry is: EntryHeader(64B) + SQL writes (variable size).
//! Entries are read sequentially (forward scan, length-prefixed).

const std = @import("std");
const assert = std.debug.assert;
const flags = @import("tiger_framework").flags;
const wal_mod = @import("tiger_framework").wal;
const cs = @import("tiger_framework").checksum;
const message = @import("message.zig");
const protocol = @import("protocol.zig");
const Storage = @import("storage.zig").SqliteStorage;

const EntryHeader = wal_mod.EntryHeader;
const Wal = wal_mod.WalType(message.Operation);

const log = std.log.scoped(.replay);

pub var log_level_runtime: std.log.Level = .info;

pub fn log_runtime(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(log_level_runtime)) {
        std.log.defaultLog(message_level, scope, format, args);
    }
}

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log_runtime,
};

const CliArgs = union(enum) {
    verify: VerifyArgs,
    inspect: InspectArgs,
    replay: ReplayArgs,
    query: QueryArgs,

    pub const help =
        \\Usage: tiger-replay <command> [options]
        \\
        \\Commands:
        \\  verify   Validate WAL checksums and hash chain
        \\  inspect  Print human-readable entry summaries
        \\  replay   Replay SQL writes against a database
        \\  query    Run SQL after partial replay
        \\
    ;
};

const VerifyArgs = struct {
    @"--": void,
    path: []const u8,
};

const InspectArgs = struct {
    filter: ?[]const u8 = null,
    after: ?u64 = null,
    before: ?u64 = null,
    verbose: bool = false,
    @"--": void,
    path: []const u8,
};

const ReplayArgs = struct {
    @"stop-at": ?u64 = null,
    verbose: bool = false,
    @"--": void,
    path: []const u8,
    db: []const u8,
};

const QueryArgs = struct {
    @"--": void,
    path: []const u8,
    db: []const u8,
    sql: []const u8,
};

pub fn main() !void {
    var args = std.process.args();
    const cli = flags.parse(&args, CliArgs);

    switch (cli) {
        .verify => |v| verify(v.path),
        .inspect => |i| inspect(i),
        .replay => |r| {
            if (r.verbose) log_level_runtime = .debug;
            replay(r);
        },
        .query => |q| query(q),
    }
}

// =====================================================================
// Verify — validate checksums and hash chain
// =====================================================================

fn verify(path: []const u8) void {
    const fd = open_wal(path);
    defer std.posix.close(fd);
    const file_size = get_file_size(fd);
    if (file_size == 0) fatal("empty file");

    const stdout = std.io.getStdOut().writer();
    var buf = alloc_entry_buf();
    defer free_entry_buf(buf);

    // Verify root.
    const root_hdr = read_header(fd, 0) orelse fatal_ret("cannot read root header");
    const expected = Wal.root_entry();
    if (root_hdr.checksum != expected.checksum) {
        fatal("root checksum mismatch — WAL written by incompatible version");
    }

    var prev_checksum = root_hdr.checksum;
    var prev_op: u64 = 0;
    var offset: u64 = @sizeOf(EntryHeader); // skip root (header only, no writes)
    var entries: u64 = 1;
    var errors: u64 = 0;
    var first_timestamp: i64 = 0;
    var last_timestamp: i64 = 0;

    while (offset < file_size) {
        const hdr = read_header(fd, offset) orelse break;
        if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > wal_mod.entry_max) {
            stdout.print("error: invalid entry_len {d} at offset {d}\n", .{ hdr.entry_len, offset }) catch {};
            errors += 1;
            break;
        }
        if (offset + hdr.entry_len > file_size) break;

        // Read full entry for checksum.
        const n = std.posix.pread(fd, buf[0..hdr.entry_len], offset) catch break;
        if (n != hdr.entry_len) break;

        // Checksum.
        const checksum_offset = @offsetOf(EntryHeader, "checksum") + @sizeOf(u128);
        const computed = cs.checksum(buf[checksum_offset..hdr.entry_len]);
        if (computed != hdr.checksum) {
            stdout.print("error: checksum failed at op {d} offset {d}\n", .{ hdr.op, offset }) catch {};
            errors += 1;
            offset += hdr.entry_len;
            entries += 1;
            continue;
        }

        // Parent chain.
        if (hdr.parent != prev_checksum) {
            stdout.print("error: hash chain broken at op {d}: parent={x}, expected={x}\n", .{ hdr.op, hdr.parent, prev_checksum }) catch {};
            errors += 1;
        }

        // Sequential op.
        if (hdr.op != prev_op + 1) {
            stdout.print("error: op not sequential at offset {d}: got {d}, expected {d}\n", .{ offset, hdr.op, prev_op + 1 }) catch {};
            errors += 1;
        }

        if (first_timestamp == 0) first_timestamp = hdr.timestamp;
        last_timestamp = hdr.timestamp;

        prev_checksum = hdr.checksum;
        prev_op = hdr.op;
        offset += hdr.entry_len;
        entries += 1;
    }

    if (errors == 0) {
        stdout.print("OK: {d} entries, ops 0..{d}\n", .{ entries, prev_op }) catch {};
        if (first_timestamp != 0) {
            stdout.print("    timestamps: {d} .. {d}\n", .{ first_timestamp, last_timestamp }) catch {};
        }
    } else {
        stdout.print("{d} errors in {d} entries\n", .{ errors, entries }) catch {};
        std.process.exit(1);
    }
}

// =====================================================================
// Inspect — print human-readable entry summaries
// =====================================================================

fn inspect(args: InspectArgs) void {
    const fd = open_wal(args.path);
    defer std.posix.close(fd);
    const file_size = get_file_size(fd);
    const stdout = std.io.getStdOut().writer();
    var buf = alloc_entry_buf();
    defer free_entry_buf(buf);

    var offset: u64 = 0;
    while (offset < file_size) {
        const hdr = read_header(fd, offset) orelse break;
        if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > wal_mod.entry_max) break;
        if (offset + hdr.entry_len > file_size) break;

        // Apply filters.
        if (args.after) |after_op| {
            if (hdr.op <= after_op) {
                offset += hdr.entry_len;
                continue;
            }
        }
        if (args.before) |before_op| {
            if (hdr.op >= before_op) {
                offset += hdr.entry_len;
                continue;
            }
        }

        const op_name = op_name_or_unknown(hdr.operation);
        if (args.filter) |f| {
            if (std.mem.indexOf(u8, op_name, f) == null) {
                offset += hdr.entry_len;
                continue;
            }
        }

        stdout.print("op={d} {s} writes={d} ts={d} len={d}\n", .{
            hdr.op, op_name, hdr.write_count, hdr.timestamp, hdr.entry_len,
        }) catch {};

        if (args.verbose and hdr.entry_len > @sizeOf(EntryHeader)) {
            // Read full entry and print SQL writes.
            const n = std.posix.pread(fd, buf[0..hdr.entry_len], offset) catch break;
            if (n == hdr.entry_len) {
                print_writes(stdout, buf[@sizeOf(EntryHeader)..hdr.entry_len], hdr.write_count);
            }
        }

        offset += hdr.entry_len;
    }
}

// =====================================================================
// Replay — re-execute SQL writes against a database
// =====================================================================

fn replay(args: ReplayArgs) void {
    const fd = open_wal(args.path);
    defer std.posix.close(fd);
    const file_size = get_file_size(fd);
    const stdout = std.io.getStdOut().writer();
    var buf = alloc_entry_buf();
    defer free_entry_buf(buf);

    // Open target database.
    var storage = Storage.init(to_sentinel(args.db)) catch {
        fatal("failed to open database");
    };
    defer storage.deinit();

    var offset: u64 = 0;
    var entries_replayed: u64 = 0;

    // Skip root.
    {
        const root = read_header(fd, 0) orelse fatal_ret("cannot read root");
        offset = root.entry_len;
    }

    while (offset < file_size) {
        const hdr = read_header(fd, offset) orelse break;
        if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > wal_mod.entry_max) break;
        if (offset + hdr.entry_len > file_size) break;

        if (args.@"stop-at") |stop| {
            if (hdr.op > stop) break;
        }

        if (hdr.write_count > 0 and hdr.entry_len > @sizeOf(EntryHeader)) {
            // Read full entry.
            const n = std.posix.pread(fd, buf[0..hdr.entry_len], offset) catch break;
            if (n != hdr.entry_len) break;

            // Execute writes inside a transaction.
            storage.begin();
            const ok = execute_entry_writes(&storage, buf[@sizeOf(EntryHeader)..hdr.entry_len], hdr.write_count);
            if (ok) {
                storage.commit();
                entries_replayed += 1;
                log.debug("op={d} {s} writes={d} — applied", .{
                    hdr.op, op_name_or_unknown(hdr.operation), hdr.write_count,
                });
            } else {
                storage.rollback();
                stdout.print("warning: op={d} write failed, rolled back\n", .{hdr.op}) catch {};
            }
        }

        offset += hdr.entry_len;
    }

    stdout.print("replay complete: {d} entries applied\n", .{entries_replayed}) catch {};
}

/// Execute SQL writes from a WAL entry against storage.
pub fn execute_entry_writes(storage: *Storage, data: []const u8, write_count: u8) bool {
    var dpos: usize = 0;
    for (0..write_count) |_| {
        // sql: [u16 BE sql_len][sql_bytes]
        if (dpos + 2 > data.len) return false;
        const sql_len = std.mem.readInt(u16, data[dpos..][0..2], .big);
        dpos += 2;
        if (dpos + sql_len > data.len) return false;
        const sql = data[dpos..][0..sql_len];
        dpos += sql_len;

        // params: [u8 param_count][params...]
        if (dpos >= data.len) return false;
        const param_count = data[dpos];
        dpos += 1;
        const params_start = dpos;

        // Scan past params.
        for (0..param_count) |_| {
            if (dpos >= data.len) return false;
            const tag = std.meta.intToEnum(protocol.TypeTag, data[dpos]) catch return false;
            dpos += 1;
            switch (tag) {
                .integer, .float => dpos += 8,
                .text, .blob => {
                    if (dpos + 2 > data.len) return false;
                    const vlen = std.mem.readInt(u16, data[dpos..][0..2], .big);
                    dpos += 2 + vlen;
                },
                .null => {},
            }
        }

        if (!storage.execute_raw(sql, data[params_start..dpos], param_count)) {
            return false;
        }
    }
    return true;
}

// =====================================================================
// Query — run SQL after replay
// =====================================================================

fn query(args: QueryArgs) void {
    // First replay all entries, then run the query.
    const fd = open_wal(args.path);
    defer std.posix.close(fd);
    const file_size = get_file_size(fd);
    var buf = alloc_entry_buf();
    defer free_entry_buf(buf);

    var storage = Storage.init(to_sentinel(args.db)) catch {
        fatal("failed to open database");
    };
    defer storage.deinit();

    // Replay all entries.
    var offset: u64 = 0;
    {
        const root = read_header(fd, 0) orelse fatal_ret("cannot read root");
        offset = root.entry_len;
    }
    while (offset < file_size) {
        const hdr = read_header(fd, offset) orelse break;
        if (hdr.entry_len < @sizeOf(EntryHeader) or hdr.entry_len > wal_mod.entry_max) break;
        if (offset + hdr.entry_len > file_size) break;

        if (hdr.write_count > 0 and hdr.entry_len > @sizeOf(EntryHeader)) {
            const n = std.posix.pread(fd, buf[0..hdr.entry_len], offset) catch break;
            if (n != hdr.entry_len) break;
            storage.begin();
            if (execute_entry_writes(&storage, buf[@sizeOf(EntryHeader)..hdr.entry_len], hdr.write_count)) {
                storage.commit();
            } else {
                storage.rollback();
            }
        }
        offset += hdr.entry_len;
    }

    // Execute the user's query.
    const stdout = std.io.getStdOut().writer();
    var out_buf: [protocol.frame_max]u8 = undefined;
    const result = storage.query_raw(args.sql, "", 0, .all, &out_buf);
    if (result) |row_data| {
        // Parse and print the row set.
        const hdr = protocol.read_row_set_header(row_data, 0) orelse {
            stdout.print("(no results)\n", .{}) catch {};
            return;
        };
        const rc = protocol.read_row_count(row_data, hdr.pos) orelse return;

        // Print column names.
        for (0..hdr.count) |i| {
            if (i > 0) stdout.print("\t", .{}) catch {};
            stdout.print("{s}", .{hdr.columns[i].name}) catch {};
        }
        stdout.print("\n", .{}) catch {};

        // Print rows.
        var rpos = rc.pos;
        for (0..rc.count) |_| {
            for (0..hdr.count) |i| {
                if (i > 0) stdout.print("\t", .{}) catch {};
                const val = protocol.read_value(row_data, rpos, hdr.columns[i].type_tag) orelse break;
                rpos = val.pos;
                switch (val.value) {
                    .integer => |v| stdout.print("{d}", .{v}) catch {},
                    .float => |v| stdout.print("{d}", .{v}) catch {},
                    .text => |v| stdout.print("{s}", .{v}) catch {},
                    .blob => |v| stdout.print("(blob {d}B)", .{v.len}) catch {},
                    .null => stdout.print("NULL", .{}) catch {},
                }
            }
            stdout.print("\n", .{}) catch {};
        }
    } else {
        stdout.print("(query failed)\n", .{}) catch {};
    }
}

// =====================================================================
// Helpers
// =====================================================================

fn read_header(fd: std.posix.fd_t, offset: u64) ?EntryHeader {
    var hdr_buf: [@sizeOf(EntryHeader)]u8 align(@alignOf(EntryHeader)) = undefined;
    const n = std.posix.pread(fd, &hdr_buf, offset) catch return null;
    if (n < @sizeOf(EntryHeader)) return null;
    const hdr: *const EntryHeader = @ptrCast(@alignCast(&hdr_buf));
    return hdr.*;
}

fn op_name_or_unknown(op_byte: u8) []const u8 {
    return if (std.meta.intToEnum(message.Operation, op_byte)) |op|
        @tagName(op)
    else |_|
        "unknown";
}

fn print_writes(writer: anytype, data: []const u8, write_count: u8) void {
    var dpos: usize = 0;
    for (0..write_count) |i| {
        if (dpos + 2 > data.len) break;
        const sql_len = std.mem.readInt(u16, data[dpos..][0..2], .big);
        dpos += 2;
        if (dpos + sql_len > data.len) break;
        const sql = data[dpos..][0..sql_len];
        dpos += sql_len;

        writer.print("  [{d}] {s}\n", .{ i, sql }) catch {};

        // Skip params.
        if (dpos >= data.len) break;
        const param_count = data[dpos];
        dpos += 1;
        for (0..param_count) |_| {
            if (dpos >= data.len) break;
            const tag = std.meta.intToEnum(protocol.TypeTag, data[dpos]) catch break;
            dpos += 1;
            switch (tag) {
                .integer, .float => dpos += 8,
                .text, .blob => {
                    if (dpos + 2 > data.len) break;
                    const vlen = std.mem.readInt(u16, data[dpos..][0..2], .big);
                    dpos += 2 + vlen;
                },
                .null => {},
            }
        }
    }
}

fn alloc_entry_buf() []align(@alignOf(EntryHeader)) u8 {
    return std.heap.page_allocator.alignedAlloc(u8, @alignOf(EntryHeader), wal_mod.entry_max) catch
        @panic("replay: failed to allocate entry buffer");
}

fn free_entry_buf(buf: []align(@alignOf(EntryHeader)) u8) void {
    std.heap.page_allocator.free(buf);
}

/// Convert a []const u8 to [:0]const u8 using a thread-local buffer.
/// CLI args from argv are null-terminated in memory, but the Zig type
/// system doesn't know. This copies into a buffer and adds the sentinel.
var path_buf_a: [4096]u8 = undefined;
var path_buf_b: [4096]u8 = undefined;
var path_buf_toggle: bool = false;

fn to_sentinel(path: []const u8) [:0]const u8 {
    // Alternate between two buffers so two calls can coexist.
    const buf = if (path_buf_toggle) &path_buf_b else &path_buf_a;
    path_buf_toggle = !path_buf_toggle;
    if (path.len >= buf.len) fatal("path too long");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn open_wal(path: []const u8) std.posix.fd_t {
    return std.posix.open(to_sentinel(path), .{ .ACCMODE = .RDONLY }, 0) catch {
        fatal("cannot open WAL file");
    };
}

fn get_file_size(fd: std.posix.fd_t) u64 {
    const stat = std.posix.fstat(fd) catch fatal_ret("fstat failed");
    return @intCast(stat.size);
}

fn fatal(msg: []const u8) noreturn {
    std.io.getStdErr().writer().print("fatal: {s}\n", .{msg}) catch {};
    std.process.exit(1);
}

fn fatal_ret(msg: []const u8) noreturn {
    fatal(msg);
}

// =====================================================================
// Tests
// =====================================================================

test "execute_entry_writes round trip" {
    var storage = try Storage.init(":memory:");
    defer storage.deinit();

    try std.testing.expect(storage.execute("CREATE TABLE t (id INTEGER, name TEXT);", .{}));

    // Build a write entry: INSERT INTO t VALUES (?1, ?2) with params (42, "Hello").
    var data: [256]u8 = undefined;
    var pos: usize = 0;

    const sql = "INSERT INTO t VALUES (?1, ?2)";
    std.mem.writeInt(u16, data[pos..][0..2], sql.len, .big);
    pos += 2;
    @memcpy(data[pos..][0..sql.len], sql);
    pos += sql.len;
    data[pos] = 2; // 2 params
    pos += 1;
    data[pos] = 0x01; // integer
    pos += 1;
    std.mem.writeInt(i64, data[pos..][0..8], 42, .little);
    pos += 8;
    data[pos] = 0x03; // text
    pos += 1;
    std.mem.writeInt(u16, data[pos..][0..2], 5, .big);
    pos += 2;
    @memcpy(data[pos..][0..5], "Hello");
    pos += 5;

    storage.begin();
    try std.testing.expect(execute_entry_writes(&storage, data[0..pos], 1));
    storage.commit();

    // Verify.
    const Row = struct { id: i64, name: [32]u8 };
    const row = storage.query(Row, "SELECT id, name FROM t;", .{});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 42), row.?.id);
    try std.testing.expectEqualStrings("Hello", std.mem.sliceTo(&row.?.name, 0));
}
