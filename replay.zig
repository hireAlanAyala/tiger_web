const std = @import("std");
const assert = std.debug.assert;
const stdx = @import("stdx.zig");
const flags = @import("flags.zig");
const Wal = @import("wal.zig").Wal;
const message = @import("message.zig");
const Message = message.Message;
const state_machine = @import("state_machine.zig");
const SqliteStorage = @import("storage.zig").SqliteStorage;

const sqlite = @cImport({
    @cInclude("sqlite3.h");
});

const log = std.log.scoped(.replay);

/// Runtime log level — same pattern as main.zig.
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
        \\  replay   Replay WAL entries against a snapshot
        \\  query    Run SQL against WAL entries
        \\
    ;
};

const VerifyArgs = struct {
    @"--": void,
    path: []const u8,
};

const InspectArgs = struct {
    filter: ?[]const u8 = null,
    id: ?[]const u8 = null,
    after: ?u64 = null,
    before: ?u64 = null,
    user: ?[]const u8 = null,
    verbose: bool = false,
    @"--": void,
    path: []const u8,
};

const ReplayArgs = struct {
    @"stop-at": ?u64 = null,
    trace: bool = false,
    @"--": void,
    path: []const u8,
    snapshot: []const u8,
};

const QueryArgs = struct {
    @"--": void,
    path: []const u8,
    sql: []const u8,
};

pub fn main() !void {
    var args = std.process.args();
    const cli = flags.parse(&args, CliArgs);

    switch (cli) {
        .verify => |v| verify(v.path),
        .inspect => |i| inspect(i),
        .query => |q| query(q),
        .replay => |r| {
            if (r.trace) log_level_runtime = .debug;
            const replayed = replay(r);
            const stdout = std.io.getStdOut().writer();
            stdout.print("replay complete: {d} entries\n", .{replayed}) catch {};
        },
    }
}

// =====================================================================
// Verify
// =====================================================================

/// Validate WAL checksums and hash chain.
fn verify(path: []const u8) void {
    const fd = open_wal(path);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    if (file_size == 0) {
        fatal("empty file");
    }

    const entry_count = file_size / @sizeOf(Message);
    const remainder = file_size % @sizeOf(Message);
    if (remainder != 0) {
        write_stderr("warning: file has {d} trailing bytes (partial entry)\n", .{remainder});
    }

    if (entry_count == 0) {
        fatal("file too small for even a root entry");
    }

    // Verify root.
    const root_entry = read_entry_or_fatal(fd, 0);
    const expected_root = Wal.root();
    if (root_entry.checksum != expected_root.checksum) {
        fatal("root checksum mismatch at op 0 — WAL written by incompatible version");
    }
    if (!root_entry.valid_checksum()) {
        fatal("root entry fails full checksum validation at op 0");
    }
    assert(root_entry.operation == .root); // Pair: Wal.root() sets .root.

    var prev_checksum = root_entry.checksum;
    var prev_op: u64 = 0;
    var first_timestamp: i64 = 0;
    var last_timestamp: i64 = 0;
    var errors: u64 = 0;

    // Verify chain.
    var batch_buf: [read_ahead]Message = undefined;
    var slot: u64 = 1;
    while (slot < entry_count) {
        const batch = read_batch(fd, &batch_buf, slot, entry_count);
        for (batch) |*entry| {
            // Header checksum.
            if (!entry.valid_checksum_header()) {
                write_stderr("error: header checksum failed at slot {d}\n", .{slot});
                errors += 1;
                slot += 1;
                continue;
            }

            // Body checksum.
            if (!entry.valid_checksum_body()) {
                write_stderr("error: body checksum failed at op {d} (slot {d})\n", .{ entry.op, slot });
                errors += 1;
                slot += 1;
                continue;
            }

            // Hash chain.
            if (entry.parent != prev_checksum) {
                write_stderr("error: hash chain broken at op {d} (slot {d}): parent={x}, expected={x}\n", .{
                    entry.op, slot, entry.parent, prev_checksum,
                });
                errors += 1;
            }

            // Sequential op.
            if (entry.op != prev_op + 1) {
                write_stderr("error: op not sequential at slot {d}: got {d}, expected {d}\n", .{
                    slot, entry.op, prev_op + 1,
                });
                errors += 1;
            }

            // WAL entries must be mutations — reads are never appended.
            if (!entry.operation.is_mutation()) {
                write_stderr("error: non-mutation operation '{s}' at op {d} (slot {d})\n", .{ @tagName(entry.operation), entry.op, slot });
                errors += 1;
            }

            if (first_timestamp == 0) first_timestamp = entry.timestamp;
            last_timestamp = entry.timestamp;

            prev_checksum = entry.checksum;
            prev_op = entry.op;
            slot += 1;
        }
    }

    assert(slot == entry_count); // We visited every slot.
    if (errors == 0) {
        assert(prev_op == entry_count - 1); // Ops sequential from 1..N.
        assert(last_timestamp >= first_timestamp); // Timestamps monotonic.
    }

    const stdout = std.io.getStdOut().writer();
    if (errors == 0) {
        stdout.print("ok: entries={d} ops=1..{d} time={d}..{d} size={d}\n", .{
            entry_count - 1, prev_op, first_timestamp, last_timestamp, file_size,
        }) catch {};
    } else {
        stdout.print("FAILED: entries={d} errors={d}\n", .{ entry_count - 1, errors }) catch {};
        std.process.exit(1);
    }
}

// =====================================================================
// Inspect
// =====================================================================

fn inspect(args: InspectArgs) void {
    const fd = open_wal(args.path);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    const entry_count = file_size / @sizeOf(Message);

    if (entry_count < 2) {
        write_stderr("no entries (only root)\n", .{});
        return;
    }

    // Parse filter operation if provided.
    const filter_op: ?message.Operation = if (args.filter) |name|
        parse_operation_name(name) orelse fatal_fmt("unknown operation: '{s}'", .{name})
    else
        null;

    const filter_user: ?u128 = if (args.user) |u|
        stdx.parse_uuid(u) orelse fatal_fmt("invalid user UUID: '{s}' (expected 32 hex chars)", .{u})
    else
        null;

    const filter_id: ?u128 = if (args.id) |i|
        stdx.parse_uuid(i) orelse fatal_fmt("invalid entity UUID: '{s}' (expected 32 hex chars)", .{i})
    else
        null;

    const stdout = std.io.getStdOut().writer();

    var batch_buf: [read_ahead]Message = undefined;
    var json_buf: [4096]u8 = undefined;
    var slot: u64 = 1; // skip root
    while (slot < entry_count) {
        const batch = read_batch(fd, &batch_buf, slot, entry_count);
        for (batch) |*entry| {
            slot += 1;

            if (!entry.valid_checksum_header()) continue;

            // Apply filters.
            if (args.after) |after| {
                if (entry.op <= after) continue;
            }
            if (args.before) |before| {
                if (entry.op >= before) continue;
            }
            if (filter_op) |f| {
                if (entry.operation != f) continue;
            }
            if (filter_user) |u| {
                if (entry.user_id != u) continue;
            }
            if (filter_id) |i| {
                if (entity_id(entry) != i) continue;
            }

            var id_buf: [36]u8 = undefined;
            var user_buf: [36]u8 = undefined;
            format_uuid(&id_buf, entity_id(entry));
            format_uuid(&user_buf, entry.user_id);

            stdout.print("op={d:<6} t={d}  {s:<24} id={s}  user={s}", .{
                entry.op,
                entry.timestamp,
                @tagName(entry.operation),
                &id_buf,
                &user_buf,
            }) catch return;

            if (args.verbose) {
                const json = body_to_json(&json_buf, entry);
                stdout.print("  {s}", .{json}) catch return;
            }

            stdout.print("\n", .{}) catch return;
        }
    }
    assert(slot == entry_count); // We visited every slot.
}

// =====================================================================
// Query
// =====================================================================

fn query(args: QueryArgs) void {
    const fd = open_wal(args.path);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    const entry_count = file_size / @sizeOf(Message);

    if (entry_count < 2) {
        write_stderr("no entries (only root)\n", .{});
        return;
    }

    // Open in-memory SQLite database.
    var db: ?*sqlite.sqlite3 = null;
    if (sqlite.sqlite3_open(":memory:", &db) != sqlite.SQLITE_OK) {
        fatal("failed to open in-memory database");
    }
    defer _ = sqlite.sqlite3_close(db);

    // Query lives in the same binary as replay because SQLite is already
    // linked for the replay command. A separate binary would duplicate the
    // dependency for no benefit.
    //
    // Header columns from Message + JSON body. Header columns are framework
    // fields that change only if Message itself changes (compiler catches that
    // because the INSERT code references entry.op, entry.timestamp, etc.).
    // Body is comptime-generated JSON — zero maintenance when entity types change.
    const create_sql =
        \\CREATE TABLE entries (
        \\  op INTEGER PRIMARY KEY,
        \\  timestamp INTEGER,
        \\  operation TEXT,
        \\  id TEXT,
        \\  user_id TEXT,
        \\  body TEXT
        \\)
    ;
    if (sqlite.sqlite3_exec(db, create_sql, null, null, null) != sqlite.SQLITE_OK) {
        fatal("failed to create entries table");
    }

    const insert_sql =
        \\INSERT INTO entries (op, timestamp, operation, id, user_id, body)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;
    var insert_stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, insert_sql, -1, &insert_stmt, null) != sqlite.SQLITE_OK) {
        fatal("failed to prepare insert statement");
    }
    defer _ = sqlite.sqlite3_finalize(insert_stmt);

    // Load WAL entries into the table.
    assert(sqlite.sqlite3_exec(db, "BEGIN", null, null, null) == sqlite.SQLITE_OK);

    var batch_buf: [read_ahead]Message = undefined;
    var json_buf: [4096]u8 = undefined;
    var slot: u64 = 1;
    while (slot < entry_count) {
        const batch = read_batch(fd, &batch_buf, slot, entry_count);
        for (batch) |*entry| {
            slot += 1;
            if (!entry.valid_checksum_header()) continue;

            assert(sqlite.sqlite3_reset(insert_stmt) == sqlite.SQLITE_OK);

            // Header columns.
            assert(sqlite.sqlite3_bind_int64(insert_stmt, 1, @intCast(entry.op)) == sqlite.SQLITE_OK);
            assert(sqlite.sqlite3_bind_int64(insert_stmt, 2, entry.timestamp) == sqlite.SQLITE_OK);
            const op_name = @tagName(entry.operation);
            assert(sqlite.sqlite3_bind_text(insert_stmt, 3, op_name.ptr, @intCast(op_name.len), sqlite.SQLITE_STATIC) == sqlite.SQLITE_OK);

            var id_buf: [32]u8 = undefined;
            var user_buf: [32]u8 = undefined;
            stdx.write_uuid_to_buf(&id_buf, entity_id(entry));
            stdx.write_uuid_to_buf(&user_buf, entry.user_id);
            assert(sqlite.sqlite3_bind_text(insert_stmt, 4, &id_buf, 32, sqlite.SQLITE_STATIC) == sqlite.SQLITE_OK);
            assert(sqlite.sqlite3_bind_text(insert_stmt, 5, &user_buf, 32, sqlite.SQLITE_STATIC) == sqlite.SQLITE_OK);

            // Body as comptime-generated JSON.
            const json = body_to_json(&json_buf, entry);
            assert(json.len >= 2); // At minimum "{}"
            assert(sqlite.sqlite3_bind_text(insert_stmt, 6, json.ptr, @intCast(json.len), sqlite.SQLITE_STATIC) == sqlite.SQLITE_OK);

            assert(sqlite.sqlite3_step(insert_stmt) == sqlite.SQLITE_DONE);
        }
    }
    assert(slot == entry_count); // We visited every slot.

    assert(sqlite.sqlite3_exec(db, "COMMIT", null, null, null) == sqlite.SQLITE_OK);

    write_stderr("loaded {d} entries\n", .{entry_count - 1});

    // Execute the user's SQL query.
    var query_stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, args.sql.ptr, @intCast(args.sql.len), &query_stmt, null) != sqlite.SQLITE_OK) {
        const err_msg = sqlite.sqlite3_errmsg(db);
        write_stderr("SQL error: {s}\n", .{std.mem.span(err_msg)});
        std.process.exit(1);
    }
    defer _ = sqlite.sqlite3_finalize(query_stmt);

    const col_count: usize = @intCast(sqlite.sqlite3_column_count(query_stmt));
    const stdout = std.io.getStdOut().writer();

    // Print column headers.
    for (0..col_count) |i| {
        if (i > 0) stdout.print("\t", .{}) catch return;
        const name = sqlite.sqlite3_column_name(query_stmt, @intCast(i));
        stdout.print("{s}", .{std.mem.span(name)}) catch return;
    }
    stdout.print("\n", .{}) catch return;

    // Print rows.
    while (sqlite.sqlite3_step(query_stmt) == sqlite.SQLITE_ROW) {
        for (0..col_count) |i| {
            if (i > 0) stdout.print("\t", .{}) catch return;
            const col_type = sqlite.sqlite3_column_type(query_stmt, @intCast(i));
            switch (col_type) {
                sqlite.SQLITE_NULL => stdout.print("NULL", .{}) catch return,
                sqlite.SQLITE_INTEGER => {
                    const val = sqlite.sqlite3_column_int64(query_stmt, @intCast(i));
                    stdout.print("{d}", .{val}) catch return;
                },
                else => {
                    const text = sqlite.sqlite3_column_text(query_stmt, @intCast(i));
                    if (text) |t| {
                        stdout.print("{s}", .{std.mem.span(t)}) catch return;
                    } else {
                        stdout.print("NULL", .{}) catch return;
                    }
                },
            }
        }
        stdout.print("\n", .{}) catch return;
    }
}

/// Serialize the entry's body as JSON using comptime struct reflection.
/// For void-bodied operations returns "{}". For struct-bodied operations,
/// walks fields at comptime: [N]u8 arrays with _len → strings, u128 → hex
/// UUID, enums → tag name, packed structs → backing integer. [N]T arrays
/// (T != u8) are skipped — their _len field carries the count.
///
/// No std.fmt — uses stdx.format_u32/format_u64/write_uuid_to_buf.
fn body_to_json(buf: *[4096]u8, entry: *const Message) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    switch (entry.operation) {
        .root => w.writeAll("{}") catch return "{}",
        inline else => |comptime_op| {
            const T = comptime comptime_op.EventType();
            if (T == void) {
                w.writeAll("{}") catch return "{}";
            } else if (T == u128) {
                const value = entry.body_as(u128).*;
                var uuid_buf: [32]u8 = undefined;
                stdx.write_uuid_to_buf(&uuid_buf, value);
                w.writeAll("{\"value\":\"") catch return "{}";
                w.writeAll(&uuid_buf) catch return "{}";
                w.writeAll("\"}") catch return "{}";
            } else {
                write_json_struct(T, w, entry.body_as(T)) catch return "{}";
            }
        },
    }

    const written = stream.getWritten();
    assert(written.len >= 2); // At minimum "{}".
    return written;
}

/// Serialize a typed struct as JSON. Comptime-walks fields, skipping
/// reserved/padding, pairing [N]u8 arrays with their _len companions
/// as strings, and formatting u128 as hex UUIDs.
fn write_json_struct(comptime T: type, w: anytype, ptr: *const T) !void {
    comptime {
        assert(@typeInfo(T).@"struct".layout == .@"extern");
        assert(stdx.no_padding(T));
    }
    try w.writeByte('{');

    var first = true;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const skip = comptime blk: {
            if (std.mem.eql(u8, field.name, "reserved")) break :blk true;
            if (std.mem.eql(u8, field.name, "padding")) break :blk true;
            // Skip [N]T arrays where T != u8 (complex nested data).
            if (@typeInfo(field.type) == .array and @typeInfo(field.type).array.child != u8) break :blk true;
            // Skip _len fields whose base is a [N]u8 array (consumed by the array field).
            if (is_byte_array_len(T, field.name)) break :blk true;
            break :blk false;
        };

        if (!skip) {
            if (!first) try w.writeByte(',');
            first = false;

            try w.writeAll("\"" ++ field.name ++ "\":");
            const value = @field(ptr.*, field.name);

            switch (@typeInfo(field.type)) {
                .int => |info| {
                    if (info.bits == 128) {
                        var uuid_buf: [32]u8 = undefined;
                        stdx.write_uuid_to_buf(&uuid_buf, value);
                        try w.writeByte('"');
                        try w.writeAll(&uuid_buf);
                        try w.writeByte('"');
                    } else if (info.bits <= 32) {
                        var int_buf: [10]u8 = undefined;
                        try w.writeAll(stdx.format_u32(&int_buf, @intCast(value)));
                    } else {
                        var int_buf: [20]u8 = undefined;
                        try w.writeAll(stdx.format_u64(&int_buf, @intCast(value)));
                    }
                },
                .array => {
                    // Only [N]u8 arrays reach here (non-u8 filtered above).
                    const len_name = comptime field.name ++ "_len";
                    if (comptime @hasField(T, len_name)) {
                        const len = @field(ptr.*, len_name);
                        try w.writeByte('"');
                        try write_json_string(w, value[0..len]);
                        try w.writeByte('"');
                    } else {
                        try w.writeAll("null");
                    }
                },
                .@"enum" => {
                    try w.writeByte('"');
                    try w.writeAll(@tagName(value));
                    try w.writeByte('"');
                },
                .@"struct" => |s| {
                    if (s.layout == .@"packed") {
                        if (s.backing_integer) |BackingInt| {
                            const int_val: BackingInt = @bitCast(value);
                            if (@bitSizeOf(BackingInt) <= 32) {
                                var int_buf: [10]u8 = undefined;
                                try w.writeAll(stdx.format_u32(&int_buf, @intCast(int_val)));
                            } else {
                                var int_buf: [20]u8 = undefined;
                                try w.writeAll(stdx.format_u64(&int_buf, @intCast(int_val)));
                            }
                        } else {
                            try w.writeAll("null");
                        }
                    } else {
                        try w.writeAll("null");
                    }
                },
                else => try w.writeAll("null"),
            }
        }
    }

    try w.writeByte('}');
}

/// True if `name` ends with "_len" and the corresponding base field
/// in T is a [N]u8 array. These _len fields are consumed by the array
/// serializer (emitted as string length), so they're skipped as columns.
fn is_byte_array_len(comptime T: type, comptime name: []const u8) bool {
    if (!std.mem.endsWith(u8, name, "_len")) return false;
    const base = name[0 .. name.len - 4];
    for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, base)) {
            return @typeInfo(f.type) == .array and @typeInfo(f.type).array.child == u8;
        }
    }
    return false;
}

/// Write a string with JSON escaping (quotes, backslashes, control chars).
fn write_json_string(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    // \u00XX — control chars are always 00XX.
                    const hex = "0123456789abcdef";
                    try w.writeAll("\\u00");
                    try w.writeByte(hex[c >> 4]);
                    try w.writeByte(hex[c & 0xf]);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}


// =====================================================================
// Replay
// =====================================================================

fn replay(args: ReplayArgs) u64 {
    const StateMachine = state_machine.StateMachineType(SqliteStorage);

    // Copy snapshot to a work path derived from the WAL path so
    // concurrent replays don't collide and the original is never modified.
    var work_buf: [4096]u8 = undefined;
    const work_path = derive_work_path(&work_buf, args.path);
    copy_file(args.snapshot, work_path);

    var storage = SqliteStorage.init(work_path) catch |err| {
        fatal_fmt("failed to open snapshot copy: {}", .{err});
    };
    defer storage.deinit();

    var sm = StateMachine.init(&storage, args.trace, 0);

    // Open WAL and validate structure.
    const fd = open_wal(args.path);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    if (file_size == 0) fatal("empty WAL file");

    if (file_size % @sizeOf(Message) != 0) {
        fatal("WAL has partial entry — file truncated or corrupted");
    }

    const entry_count = file_size / @sizeOf(Message);
    if (entry_count == 0) fatal("WAL too small for root entry");

    const root_entry = read_entry_or_fatal(fd, 0);
    const expected_root = Wal.root();
    if (root_entry.checksum != expected_root.checksum) {
        fatal("root checksum mismatch — WAL written by incompatible version");
    }
    assert(root_entry.operation == .root); // Pair: Wal.root() sets .root.

    const stop_at = args.@"stop-at" orelse std.math.maxInt(u64);

    return replay_entries(fd, &sm, entry_count, root_entry.checksum, stop_at);
}

/// Core replay loop — reads WAL entries from fd, validates the hash chain,
/// and executes each mutation against the state machine. Used by both the
/// CLI replay command and the replay fuzzer.
///
/// Panics on invariant violations (broken chain, storage errors). These
/// are programming errors or infrastructure failures, not user input errors
/// — the WAL was either written by our code or is corrupt.
pub fn replay_entries(
    fd: std.posix.fd_t,
    sm: *state_machine.StateMachineType(SqliteStorage),
    entry_count: u64,
    root_checksum: u128,
    stop_at: u64,
) u64 {
    var replayed: u64 = 0;
    var prev_checksum = root_checksum;
    var slot: u64 = 1;
    while (slot < entry_count) : (slot += 1) {
        const entry = Wal.read_entry(fd, slot * @sizeOf(Message)) orelse {
            @panic("replay: failed to read entry");
        };

        if (!entry.valid_checksum()) {
            @panic("replay: checksum failed");
        }

        if (!entry.operation.is_mutation()) {
            @panic("replay: non-mutation in WAL");
        }

        assert(entry.op == slot); // Ops sequential — no gaps.
        assert(entry.parent == prev_checksum); // Hash chain intact.

        if (entry.op > stop_at) break;

        // Set time to match the recorded timestamp.
        sm.set_time(entry.timestamp);

        // Wrap each entry in its own transaction.
        sm.begin_batch();

        sm.tracer.start(.prefetch);
        if (!sm.prefetch(entry)) {
            @panic("replay: prefetch returned busy — storage should not be busy during replay");
        }
        sm.tracer.stop(.prefetch, entry.operation);

        sm.tracer.start(.execute);
        const resp = sm.commit(entry);
        sm.tracer.stop(.execute, entry.operation);
        sm.tracer.trace_log(entry.operation, resp.status, 0);

        sm.commit_batch();

        if (resp.status == .storage_error) {
            @panic("replay: storage error — cannot continue");
        }

        prev_checksum = entry.checksum;
        replayed += 1;
    }

    // Post-loop: if we didn't stop early, we must have replayed every entry.
    if (stop_at == std.math.maxInt(u64)) {
        assert(replayed == entry_count - 1); // All entries replayed (minus root).
    }

    return replayed;
}

/// Derive a work database path from the WAL path: "<wal-path>.replay.db\0".
fn derive_work_path(buf: *[4096]u8, wal_path: []const u8) [:0]const u8 {
    assert(wal_path.len > 0);
    const suffix = ".replay.db";
    if (wal_path.len + suffix.len + 1 > buf.len) {
        fatal("WAL path too long");
    }
    @memcpy(buf[0..wal_path.len], wal_path);
    @memcpy(buf[wal_path.len..][0..suffix.len], suffix);
    buf[wal_path.len + suffix.len] = 0;
    return buf[0 .. wal_path.len + suffix.len :0];
}

/// Copy a file from src path to a sentinel-terminated dst path.
fn copy_file(src: []const u8, dst: [:0]const u8) void {
    var path_buf: [4096]u8 = undefined;
    const src_fd = std.posix.open(
        to_sentinel(&path_buf, src),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |err| {
        fatal_fmt("cannot open snapshot '{s}': {}", .{ src, err });
    };
    defer std.posix.close(src_fd);

    const dst_fd = std.posix.open(
        dst,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch |err| {
        fatal_fmt("cannot create work file '{s}': {}", .{ dst, err });
    };
    defer std.posix.close(dst_fd);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(src_fd, &buf) catch |err| {
            fatal_fmt("read snapshot failed: {}", .{err});
        };
        if (n == 0) break;
        var remaining = buf[0..n];
        while (remaining.len > 0) {
            const written = std.posix.write(dst_fd, remaining) catch |err| {
                fatal_fmt("write work file failed: {}", .{err});
            };
            if (written == 0) fatal("write returned 0");
            remaining = remaining[written..];
        }
    }
}

// =====================================================================
// Helpers
// =====================================================================

fn open_wal(path: []const u8) std.posix.fd_t {
    var buf: [4096]u8 = undefined;
    return std.posix.open(
        to_sentinel(&buf, path),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |err| {
        write_stderr("error: cannot open '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
}

/// Copy a slice into a caller-owned buffer with null terminator.
fn to_sentinel(buf: *[4096]u8, path: []const u8) [:0]const u8 {
    assert(path.len > 0); // Empty path is never valid for posix.open.
    if (path.len >= buf.len) fatal("path too long");
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn get_file_size(fd: std.posix.fd_t) u64 {
    const stat = std.posix.fstat(fd) catch |err| {
        write_stderr("error: fstat failed: {}\n", .{err});
        std.process.exit(1);
    };
    return @intCast(stat.size);
}

fn read_entry_or_fatal(fd: std.posix.fd_t, offset: u64) Message {
    return Wal.read_entry(fd, offset) orelse {
        write_stderr("error: failed to read entry at offset {d}\n", .{offset});
        std.process.exit(1);
    };
}

/// Read up to read_ahead entries starting at start_slot. Returns a slice
/// of the buffer containing the entries read. One syscall per batch instead
/// of one per entry.
const read_ahead = 64;

fn read_batch(fd: std.posix.fd_t, buf: *[read_ahead]Message, start_slot: u64, entry_count: u64) []const Message {
    assert(start_slot < entry_count);
    const remaining = entry_count - start_slot;
    const to_read: usize = @intCast(@min(remaining, read_ahead));
    const bytes_wanted = to_read * @sizeOf(Message);
    const offset = start_slot * @sizeOf(Message);
    const bytes_read = std.posix.pread(fd, std.mem.asBytes(buf)[0..bytes_wanted], offset) catch |err| {
        fatal_fmt("read failed at slot {d}: {}", .{ start_slot, err });
    };
    assert(bytes_read % @sizeOf(Message) == 0); // No partial entries.
    const entries_read = bytes_read / @sizeOf(Message);
    assert(entries_read > 0);
    return buf[0..entries_read];
}

/// Extract the primary entity ID for display. Operations that carry
/// their entity ID in the body (create_product, create_collection, etc.)
/// need body-aware extraction; the rest use msg.id from the header.
/// Exhaustive switch — adding a new operation forces handling here.
fn entity_id(entry: *const Message) u128 {
    return switch (entry.operation) {
        .create_product => entry.body_as(message.Product).id,
        .create_collection => entry.body_as(message.ProductCollection).id,
        .create_order => entry.body_as(message.OrderRequest).id,
        .root,
        .update_product,
        .delete_product,
        .delete_collection,
        .add_collection_member,
        .remove_collection_member,
        .transfer_inventory,
        .complete_order,
        .cancel_order,
        .get_product,
        .get_collection,
        .get_order,
        .get_product_inventory,
        .list_products,
        .list_collections,
        .list_orders,
        .search_products,
        .page_load_dashboard,
        .page_load_login,
        .request_login_code,
        .verify_login_code,
        .logout,
        => entry.id,
    };
}

fn parse_operation_name(name: []const u8) ?message.Operation {
    inline for (comptime std.enums.values(message.Operation)) |op| {
        if (std.mem.eql(u8, name, @tagName(op))) return op;
    }
    return null;
}

fn format_uuid(buf: *[36]u8, value: u128) void {
    const bytes: [16]u8 = @bitCast(value);
    const hex = "0123456789abcdef";
    const pattern = [_]u8{
        hex[bytes[15] >> 4], hex[bytes[15] & 0xf],
        hex[bytes[14] >> 4], hex[bytes[14] & 0xf],
        hex[bytes[13] >> 4], hex[bytes[13] & 0xf],
        hex[bytes[12] >> 4], hex[bytes[12] & 0xf],
        '-',
        hex[bytes[11] >> 4], hex[bytes[11] & 0xf],
        hex[bytes[10] >> 4], hex[bytes[10] & 0xf],
        '-',
        hex[bytes[9] >> 4],  hex[bytes[9] & 0xf],
        hex[bytes[8] >> 4],  hex[bytes[8] & 0xf],
        '-',
        hex[bytes[7] >> 4],  hex[bytes[7] & 0xf],
        hex[bytes[6] >> 4],  hex[bytes[6] & 0xf],
        '-',
        hex[bytes[5] >> 4],  hex[bytes[5] & 0xf],
        hex[bytes[4] >> 4],  hex[bytes[4] & 0xf],
        hex[bytes[3] >> 4],  hex[bytes[3] & 0xf],
        hex[bytes[2] >> 4],  hex[bytes[2] & 0xf],
        hex[bytes[1] >> 4],  hex[bytes[1] & 0xf],
        hex[bytes[0] >> 4],  hex[bytes[0] & 0xf],
    };
    buf.* = pattern;
}

fn write_stderr(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print(fmt, args) catch {};
}

fn fatal(comptime msg: []const u8) noreturn {
    write_stderr("error: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn fatal_fmt(comptime fmt: []const u8, args: anytype) noreturn {
    write_stderr("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn test_path() [:0]const u8 {
    return "/tmp/tiger_replay_test.wal";
}

fn cleanup() void {
    std.posix.unlink(test_path()) catch {};
}

/// Create a test WAL with N entries and return the fd for reading.
fn create_test_wal(n: u32) std.posix.fd_t {
    cleanup();
    var wal = Wal.init(test_path());

    const product = std.mem.zeroes(message.Product);
    for (0..n) |i| {
        const msg = message.Message.init(.create_product, @as(u128, @intCast(i)) + 1, 42, product);
        const entry = wal.prepare(msg, @as(i64, @intCast(i)) + 1000);
        wal.append(&entry);
    }
    wal.deinit();

    return std.posix.open(
        test_path(),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch unreachable;
}

test "verify: valid WAL passes" {
    defer cleanup();
    const fd = create_test_wal(5);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    const entry_count = file_size / @sizeOf(Message);
    try testing.expectEqual(entry_count, 6); // root + 5

    // Verify root.
    const root_entry = Wal.read_entry(fd, 0).?;
    try testing.expectEqual(root_entry.checksum, Wal.root().checksum);
    try testing.expect(root_entry.valid_checksum());

    // Verify chain.
    var prev_checksum = root_entry.checksum;
    var slot: u64 = 1;
    while (slot < entry_count) : (slot += 1) {
        const entry = Wal.read_entry(fd, slot * @sizeOf(Message)).?;
        try testing.expect(entry.valid_checksum_header());
        try testing.expect(entry.valid_checksum_body());
        try testing.expectEqual(entry.parent, prev_checksum);
        try testing.expectEqual(entry.op, slot);
        try testing.expect(entry.operation != .root);
        prev_checksum = entry.checksum;
    }
}

test "verify: corrupt entry detected" {
    defer cleanup();
    _ = create_test_wal(5);
    // Close the read fd — we need write access.
    // Reopen for writing to corrupt an entry.
    {
        const write_fd = std.posix.open(
            test_path(),
            .{ .ACCMODE = .WRONLY },
            0,
        ) catch unreachable;
        defer std.posix.close(write_fd);
        const bad = [_]u8{0xFF};
        _ = std.posix.pwrite(write_fd, &bad, 3 * @sizeOf(Message) + 50) catch unreachable;
    }

    const fd = std.posix.open(
        test_path(),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch unreachable;
    defer std.posix.close(fd);

    // Entry at slot 3 should have invalid checksum.
    const entry = Wal.read_entry(fd, 3 * @sizeOf(Message)).?;
    try testing.expect(!entry.valid_checksum_header());
}

test "verify: hash chain break detected" {
    defer cleanup();
    const fd = create_test_wal(5);
    defer std.posix.close(fd);

    // Read entries 1 and 2 — entry 2's parent should be entry 1's checksum.
    const entry1 = Wal.read_entry(fd, 1 * @sizeOf(Message)).?;
    const entry2 = Wal.read_entry(fd, 2 * @sizeOf(Message)).?;
    try testing.expectEqual(entry2.parent, entry1.checksum);

    // If we check entry 2 against a fake previous checksum, chain is broken.
    try testing.expect(entry2.parent != 0xDEADBEEF);
}

test "inspect: format_uuid" {
    var buf: [36]u8 = undefined;
    format_uuid(&buf, 0);
    try testing.expectEqualSlices(u8, &buf, "00000000-0000-0000-0000-000000000000");

    format_uuid(&buf, 1);
    try testing.expectEqualSlices(u8, &buf, "00000000-0000-0000-0000-000000000001");
}

test "inspect: parse_operation_name" {
    try testing.expectEqual(parse_operation_name("create_product"), .create_product);
    try testing.expectEqual(parse_operation_name("root"), .root);
    try testing.expectEqual(parse_operation_name("nonexistent"), null);
}

test "inspect: entries readable" {
    defer cleanup();
    const fd = create_test_wal(3);
    defer std.posix.close(fd);

    // Read entry 1 — should be a create_product.
    const entry = Wal.read_entry(fd, 1 * @sizeOf(Message)).?;
    try testing.expectEqual(entry.operation, .create_product);
    try testing.expectEqual(entry.op, 1);
    try testing.expectEqual(entry.user_id, 42);
    try testing.expectEqual(entry.timestamp, 1000);
}

test "write_json_string: escaping" {
    var buf: [256]u8 = undefined;

    const cases = .{
        // Plain ASCII — no escaping.
        .{ "hello", "hello" },
        // Quotes and backslashes.
        .{ "say \"hi\"", "say \\\"hi\\\"" },
        .{ "a\\b", "a\\\\b" },
        // Newline, carriage return, tab.
        .{ "line1\nline2", "line1\\nline2" },
        .{ "col1\tcol2", "col1\\tcol2" },
        .{ "a\rb", "a\\rb" },
        // Control char (0x01) — \u00XX escape.
        .{ &[_]u8{0x01}, "\\u0001" },
        .{ &[_]u8{0x00}, "\\u0000" },
        .{ &[_]u8{0x1f}, "\\u001f" },
        // Mixed: control char + quote + normal.
        .{ &[_]u8{ 0x02, '"', 'x' }, "\\u0002\\\"x" },
        // Empty string.
        .{ "", "" },
        // Printable boundary (0x20 = space, not escaped).
        .{ " ", " " },
    };

    inline for (cases) |case| {
        var stream = std.io.fixedBufferStream(&buf);
        try write_json_string(stream.writer(), case[0]);
        try testing.expectEqualSlices(u8, case[1], stream.getWritten());
    }
}

test "body_to_json: every mutation operation" {
    var json_buf: [4096]u8 = undefined;

    // Product body (create_product, update_product).
    {
        var product = std.mem.zeroes(message.Product);
        product.id = 1;
        product.price_cents = 999;
        product.inventory = 50;
        product.version = 3;
        product.name_len = 6;
        @memcpy(product.name[0..6], "Widget");
        product.flags = .{ .active = true };

        const msg = Message.init(.create_product, 1, 42, product);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(json.len > 2);
        try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Widget\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"price_cents\":999") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"inventory\":50") != null);

        // update_product uses the same body type.
        const msg2 = Message.init(.update_product, 1, 42, product);
        const json2 = body_to_json(&json_buf, &msg2);
        try testing.expect(std.mem.indexOf(u8, json2, "\"price_cents\":999") != null);
    }

    // ProductCollection body (create_collection).
    {
        var coll = std.mem.zeroes(message.ProductCollection);
        coll.id = 2;
        coll.name_len = 4;
        @memcpy(coll.name[0..4], "Sale");

        const msg = Message.init(.create_collection, 2, 42, coll);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Sale\"") != null);
    }

    // u128 body (add_collection_member, remove_collection_member).
    {
        const member_id: u128 = 0xAABBCCDD;
        const msg = Message.init(.add_collection_member, 1, 42, member_id);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(std.mem.indexOf(u8, json, "\"value\":\"") != null);

        const msg2 = Message.init(.remove_collection_member, 1, 42, member_id);
        const json2 = body_to_json(&json_buf, &msg2);
        try testing.expect(std.mem.indexOf(u8, json2, "\"value\":\"") != null);
    }

    // InventoryTransfer body (transfer_inventory).
    {
        var xfer = std.mem.zeroes(message.InventoryTransfer);
        xfer.target_id = 2;
        xfer.quantity = 5;

        const msg = Message.init(.transfer_inventory, 0, 42, xfer);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(std.mem.indexOf(u8, json, "\"quantity\":5") != null);
    }

    // OrderRequest body (create_order).
    {
        var order = std.mem.zeroes(message.OrderRequest);
        order.id = 10;

        const msg = Message.init(.create_order, 10, 42, order);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(json.len > 2);
    }

    // OrderCompletion body (complete_order).
    {
        var completion = std.mem.zeroes(message.OrderCompletion);
        completion.result = .confirmed;
        completion.payment_ref_len = 3;
        @memcpy(completion.payment_ref[0..3], "abc");

        const msg = Message.init(.complete_order, 10, 42, completion);
        const json = body_to_json(&json_buf, &msg);
        try testing.expect(std.mem.indexOf(u8, json, "\"result\":\"confirmed\"") != null);
        try testing.expect(std.mem.indexOf(u8, json, "\"payment_ref\":\"abc\"") != null);
    }

    // Void body operations (delete_product, delete_collection, cancel_order).
    {
        inline for (.{ .delete_product, .delete_collection, .cancel_order }) |op| {
            const msg = Message.init(op, 1, 42, {});
            const json = body_to_json(&json_buf, &msg);
            try testing.expectEqualSlices(u8, json, "{}");
        }
    }
}

// =====================================================================
// Replay tests
// =====================================================================

const replay_wal_path: [:0]const u8 = "/tmp/tiger_replay_replay_test.wal";
const replay_snap_path: [:0]const u8 = "/tmp/tiger_replay_snapshot.db";
const replay_work_path: [:0]const u8 = "/tmp/tiger_replay_replay_test.wal.replay.db";

fn replay_cleanup() void {
    // Delete main files and SQLite auxiliary files (-wal, -shm).
    // Stale -wal/-shm files from a previous run cause SQLite to replay
    // a journal against the wrong database, producing constraint errors.
    for (replay_test_files) |path| {
        std.posix.unlink(path) catch {};
    }
    // Assert cleanup worked — a bug here surfaces as a clear assertion
    // failure rather than a confusing storage error during replay.
    for (replay_test_files) |path| {
        assert(file_not_found(path));
    }
}

/// All files a replay test may produce, including SQLite auxiliary files.
const replay_test_files = expand_sqlite_paths(&.{ replay_wal_path, replay_snap_path, replay_work_path });

fn expand_sqlite_paths(base: []const [:0]const u8) [base.len * 3][:0]const u8 {
    var out: [base.len * 3][:0]const u8 = undefined;
    for (base, 0..) |path, i| {
        out[i * 3 + 0] = path;
        out[i * 3 + 1] = path ++ "-wal";
        out[i * 3 + 2] = path ++ "-shm";
    }
    return out;
}

fn file_not_found(path: [:0]const u8) bool {
    _ = std.posix.fstatat(std.posix.AT.FDCWD, path, 0) catch |err| {
        return err == error.FileNotFound;
    };
    return false;
}

fn make_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = id;
    p.price_cents = price;
    p.inventory = 10;
    p.version = 1;
    p.name_len = @intCast(name.len);
    p.flags = .{ .active = true };
    @memcpy(p.name[0..name.len], name);
    return p;
}

test "replay: full round-trip" {
    const StateMachine = state_machine.StateMachineType(SqliteStorage);

    replay_cleanup();
    defer replay_cleanup();

    const products = [_]struct { id: u128, name: []const u8, price: u32 }{
        .{ .id = 1, .name = "Widget", .price = 999 },
        .{ .id = 2, .name = "Gadget", .price = 1999 },
        .{ .id = 3, .name = "Sprocket", .price = 499 },
    };

    // Phase 1: Run operations through an in-memory state machine + WAL.
    // The WAL captures the operations; we don't need a persistent DB here.
    {
        var wal = Wal.init(replay_wal_path);
        defer wal.deinit();

        var mem_storage = try state_machine.MemoryStorage.init(std.heap.page_allocator);
        defer mem_storage.deinit(std.heap.page_allocator);

        const MemSM = state_machine.StateMachineType(state_machine.MemoryStorage);
        var sm = MemSM.init(&mem_storage, false, 0);

        var timestamp: i64 = 1_700_000_000;
        for (products) |prod| {
            const product = make_product(prod.id, prod.name, prod.price);
            const msg = message.Message.init(.create_product, prod.id, 42, product);

            sm.set_time(timestamp);
            const ok = sm.prefetch(msg);
            try testing.expect(ok);
            const resp = sm.commit(msg);
            try testing.expectEqual(resp.status, .ok);

            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            timestamp += 1;
        }
    }

    // Phase 2: Create an empty snapshot and replay the WAL against it.
    {
        var snap_storage = try SqliteStorage.init(replay_snap_path);
        snap_storage.deinit();
    }

    const replayed = replay(ReplayArgs{
        .@"stop-at" = null,
        .trace = false,
        .@"--" = {},
        .path = replay_wal_path,
        .snapshot = replay_snap_path,
    });
    try testing.expectEqual(replayed, 3);

    // Phase 3: Verify the replayed database has the correct state.
    var verify_storage = try SqliteStorage.init(replay_work_path);
    defer verify_storage.deinit();
    var verify_sm = StateMachine.init(&verify_storage, false, 0);

    // Read back each product.
    for (products) |prod| {
        verify_sm.set_time(1_700_000_000);
        const get_msg = message.Message.init(.get_product, prod.id, 0, std.mem.zeroes(message.Product));
        verify_sm.begin_batch();
        const ok = verify_sm.prefetch(get_msg);
        try testing.expect(ok);
        const resp = verify_sm.commit(get_msg);
        verify_sm.commit_batch();
        try testing.expectEqual(resp.status, .ok);
        const got = resp.result.product;
        try testing.expectEqual(got.id, prod.id);
        try testing.expectEqual(got.price_cents, prod.price);
    }
}

test "replay: stop-at limits entries" {
    const StateMachine = state_machine.StateMachineType(SqliteStorage);

    replay_cleanup();
    defer replay_cleanup();

    // Create WAL with 3 products using in-memory state machine.
    {
        var wal = Wal.init(replay_wal_path);
        defer wal.deinit();

        var mem_storage = try state_machine.MemoryStorage.init(std.heap.page_allocator);
        defer mem_storage.deinit(std.heap.page_allocator);

        const MemSM = state_machine.StateMachineType(state_machine.MemoryStorage);
        var sm = MemSM.init(&mem_storage, false, 0);

        var timestamp: i64 = 1_700_000_000;
        for (1..4) |i| {
            const id: u128 = @intCast(i);
            var name_buf: [8]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "Item {d}", .{i}) catch unreachable;
            const product = make_product(id, name, 100);
            const msg = message.Message.init(.create_product, id, 42, product);

            sm.set_time(timestamp);
            _ = sm.prefetch(msg);
            _ = sm.commit(msg);

            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            timestamp += 1;
        }
    }

    // Create empty snapshot and replay only first 2 ops.
    {
        var snap_storage = try SqliteStorage.init(replay_snap_path);
        snap_storage.deinit();
    }

    const replayed = replay(ReplayArgs{
        .@"stop-at" = 2,
        .trace = false,
        .@"--" = {},
        .path = replay_wal_path,
        .snapshot = replay_snap_path,
    });
    try testing.expectEqual(replayed, 2);

    // Verify: products 1 and 2 exist, product 3 does not.
    var verify_storage = try SqliteStorage.init(replay_work_path);
    defer verify_storage.deinit();
    var verify_sm = StateMachine.init(&verify_storage, false, 0);

    for ([_]u128{ 1, 2 }) |id| {
        verify_sm.set_time(1_700_000_000);
        const msg = message.Message.init(.get_product, id, 0, std.mem.zeroes(message.Product));
        verify_sm.begin_batch();
        _ = verify_sm.prefetch(msg);
        const resp = verify_sm.commit(msg);
        verify_sm.commit_batch();
        try testing.expectEqual(resp.status, .ok);
    }

    // Product 3 should not exist.
    verify_sm.set_time(1_700_000_000);
    const msg3 = message.Message.init(.get_product, 3, 0, std.mem.zeroes(message.Product));
    verify_sm.begin_batch();
    _ = verify_sm.prefetch(msg3);
    const resp3 = verify_sm.commit(msg3);
    verify_sm.commit_batch();
    try testing.expectEqual(resp3.status, .not_found);
}

test "replay: updates and deletes round-trip" {
    const StateMachine = state_machine.StateMachineType(SqliteStorage);

    replay_cleanup();
    defer replay_cleanup();

    // Phase 1: create, update, then delete — exercises all product mutation
    // paths through the WAL serialization boundary.
    {
        var wal = Wal.init(replay_wal_path);
        defer wal.deinit();

        var mem_storage = try state_machine.MemoryStorage.init(std.heap.page_allocator);
        defer mem_storage.deinit(std.heap.page_allocator);

        const MemSM = state_machine.StateMachineType(state_machine.MemoryStorage);
        var sm = MemSM.init(&mem_storage, false, 0);

        var timestamp: i64 = 1_700_000_000;

        // Create two products.
        for ([_]u128{ 1, 2 }) |id| {
            const product = make_product(id, "Original", 100);
            const msg = message.Message.init(.create_product, id, 42, product);
            sm.set_time(timestamp);
            try testing.expect(sm.prefetch(msg));
            try testing.expectEqual(sm.commit(msg).status, .ok);
            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            timestamp += 1;
        }

        // Update product 1: change price and name.
        {
            var updated = make_product(1, "Updated", 999);
            updated.version = 1; // Must match current version.
            const msg = message.Message.init(.update_product, 1, 42, updated);
            sm.set_time(timestamp);
            try testing.expect(sm.prefetch(msg));
            try testing.expectEqual(sm.commit(msg).status, .ok);
            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            timestamp += 1;
        }

        // Soft-delete product 2.
        {
            const msg = message.Message.init(.delete_product, 2, 42, {});
            sm.set_time(timestamp);
            try testing.expect(sm.prefetch(msg));
            try testing.expectEqual(sm.commit(msg).status, .ok);
            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            timestamp += 1;
        }
    }

    // Phase 2: Replay.
    {
        var snap_storage = try SqliteStorage.init(replay_snap_path);
        snap_storage.deinit();
    }

    const replayed = replay(ReplayArgs{
        .@"stop-at" = null,
        .trace = false,
        .@"--" = {},
        .path = replay_wal_path,
        .snapshot = replay_snap_path,
    });
    try testing.expectEqual(replayed, 4); // 2 creates + 1 update + 1 delete

    // Phase 3: Verify state.
    var verify_storage = try SqliteStorage.init(replay_work_path);
    defer verify_storage.deinit();
    var verify_sm = StateMachine.init(&verify_storage, false, 0);

    // Product 1: updated price and name.
    {
        verify_sm.set_time(1_700_000_000);
        const msg = message.Message.init(.get_product, 1, 0, std.mem.zeroes(message.Product));
        verify_sm.begin_batch();
        try testing.expect(verify_sm.prefetch(msg));
        const resp = verify_sm.commit(msg);
        verify_sm.commit_batch();
        try testing.expectEqual(resp.status, .ok);
        const got = resp.result.product;
        try testing.expectEqual(got.id, 1);
        try testing.expectEqual(got.price_cents, 999);
        try testing.expectEqual(got.version, 2); // Bumped by update.
        try testing.expectEqualSlices(u8, "Updated", got.name[0..got.name_len]);
    }

    // Product 2: soft-deleted — get_product returns not_found for
    // inactive products, but the row still exists in storage.
    {
        verify_sm.set_time(1_700_000_000);
        const msg = message.Message.init(.get_product, 2, 0, std.mem.zeroes(message.Product));
        verify_sm.begin_batch();
        try testing.expect(verify_sm.prefetch(msg));
        const resp = verify_sm.commit(msg);
        verify_sm.commit_batch();
        try testing.expectEqual(resp.status, .not_found);

        // Verify the row IS still in storage (soft delete, not hard delete).
        var raw_product: message.Product = undefined;
        try testing.expectEqual(verify_storage.get(2, &raw_product), .ok);
        try testing.expectEqual(raw_product.flags.active, false);
        try testing.expectEqual(raw_product.version, 2); // Bumped by soft delete.
    }
}

test "verify: detects broken hash chain" {
    defer cleanup();

    // Create a valid WAL with 3 entries.
    _ = create_test_wal(3);

    // Corrupt entry 2's parent field (offset 16 in the Message struct is
    // the parent field — after checksum). We overwrite the parent but leave
    // the checksum_body and checksum intact so it passes body/header checks
    // independently. The chain break is the only error.
    {
        const write_fd = std.posix.open(
            test_path(),
            .{ .ACCMODE = .RDWR },
            0,
        ) catch unreachable;
        defer std.posix.close(write_fd);

        // Read entry at slot 2, corrupt parent, recompute header checksum
        // so the entry passes valid_checksum_header independently.
        const slot: u64 = 2;
        var entry = Wal.read_entry(write_fd, slot * @sizeOf(Message)).?;
        try testing.expect(entry.valid_checksum());

        // Corrupt parent — set to a value that breaks the chain.
        entry.parent = 0xDEADBEEF;
        // Recompute checksums so checksum validation passes — the chain
        // break is the only error.
        entry.set_checksum();
        try testing.expect(entry.valid_checksum());

        // Write back.
        const bytes = std.mem.asBytes(&entry);
        const n = std.posix.pwrite(write_fd, bytes, slot * @sizeOf(Message)) catch unreachable;
        try testing.expectEqual(n, @sizeOf(Message));
    }

    // Read back and verify: header/body checksums pass, but chain is broken.
    const read_fd = std.posix.open(
        test_path(),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch unreachable;
    defer std.posix.close(read_fd);

    const entry1 = Wal.read_entry(read_fd, 1 * @sizeOf(Message)).?;
    const entry2 = Wal.read_entry(read_fd, 2 * @sizeOf(Message)).?;

    // Both entries pass checksum independently.
    try testing.expect(entry1.valid_checksum());
    try testing.expect(entry2.valid_checksum());

    // But the chain is broken: entry2.parent != entry1.checksum.
    try testing.expect(entry2.parent != entry1.checksum);
    try testing.expectEqual(entry2.parent, 0xDEADBEEF);
}
