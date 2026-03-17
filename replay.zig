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
            replay(r);
        },
    }
}

// =====================================================================
// Verify
// =====================================================================

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

    var prev_checksum = root_entry.checksum;
    var prev_op: u64 = 0;
    var first_timestamp: i64 = 0;
    var last_timestamp: i64 = 0;
    var errors: u64 = 0;

    // Verify chain.
    var slot: u64 = 1;
    while (slot < entry_count) : (slot += 1) {
        const entry = read_entry_or_fatal(fd, slot * @sizeOf(Message));

        // Header checksum.
        if (!entry.valid_checksum_header()) {
            write_stderr("error: header checksum failed at slot {d}\n", .{slot});
            errors += 1;
            continue;
        }

        // Body checksum.
        if (!entry.valid_checksum_body()) {
            write_stderr("error: body checksum failed at op {d} (slot {d})\n", .{ entry.op, slot });
            errors += 1;
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

    var slot: u64 = 1; // skip root
    while (slot < entry_count) : (slot += 1) {
        const entry = read_entry_or_fatal(fd, slot * @sizeOf(Message));

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
            if (entity_id(&entry) != i) continue;
        }

        var id_buf: [36]u8 = undefined;
        var user_buf: [36]u8 = undefined;
        format_uuid(&id_buf, entity_id(&entry));
        format_uuid(&user_buf, entry.user_id);

        stdout.print("op={d:<6} t={d}  {s:<24} id={s}  user={s}", .{
            entry.op,
            entry.timestamp,
            @tagName(entry.operation),
            &id_buf,
            &user_buf,
        }) catch return;

        if (args.verbose) {
            write_body_summary(stdout, &entry);
        }

        stdout.print("\n", .{}) catch return;
    }
}

/// Print key body fields for the entry's operation type.
fn write_body_summary(w: anytype, entry: *const Message) void {
    switch (entry.operation) {
        .create_product => {
            const p = entry.body_as(message.Product);
            w.print("  name=\"{s}\" price={d} stock={d} ver={d}", .{
                p.name_slice(), p.price_cents, p.inventory, p.version,
            }) catch return;
        },
        .update_product => {
            const p = entry.body_as(message.Product);
            w.print("  name=\"{s}\" price={d} ver={d}", .{
                p.name_slice(), p.price_cents, p.version,
            }) catch return;
        },
        .delete_product, .get_product => {
            // Header-only operations — id is already shown.
        },
        .create_collection => {
            const c = entry.body_as(message.ProductCollection);
            w.print("  name=\"{s}\"", .{c.name_slice()}) catch return;
        },
        .delete_collection, .get_collection => {},
        .add_collection_member, .remove_collection_member => {
            const product_id = entry.body_as(u128).*;
            var buf: [36]u8 = undefined;
            format_uuid(&buf, product_id);
            w.print("  product={s}", .{&buf}) catch return;
        },
        .create_order => {
            const o = entry.body_as(message.OrderRequest);
            w.print("  items={d}", .{o.items_len}) catch return;
        },
        .complete_order, .cancel_order, .get_order => {},
        .transfer_inventory => {
            const t = entry.body_as(message.InventoryTransfer);
            var buf: [36]u8 = undefined;
            format_uuid(&buf, t.target_id);
            w.print("  target={s} qty={d}", .{ &buf, t.quantity }) catch return;
        },
        .list_products, .list_collections, .list_orders,
        .get_product_inventory, .search_products,
        .page_load_dashboard,
        => {},
        .root => {},
    }
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

    // Create the entries table.
    const create_sql =
        \\CREATE TABLE entries (
        \\  op INTEGER PRIMARY KEY,
        \\  timestamp INTEGER,
        \\  operation TEXT,
        \\  id TEXT,
        \\  user_id TEXT,
        \\  name TEXT,
        \\  price_cents INTEGER,
        \\  inventory INTEGER,
        \\  version INTEGER,
        \\  items_len INTEGER,
        \\  quantity INTEGER,
        \\  target_id TEXT
        \\)
    ;
    if (sqlite.sqlite3_exec(db, create_sql, null, null, null) != sqlite.SQLITE_OK) {
        fatal("failed to create entries table");
    }

    // Prepare insert statement.
    const insert_sql =
        \\INSERT INTO entries (op, timestamp, operation, id, user_id,
        \\  name, price_cents, inventory, version, items_len, quantity, target_id)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ;
    var insert_stmt: ?*sqlite.sqlite3_stmt = null;
    if (sqlite.sqlite3_prepare_v2(db, insert_sql, -1, &insert_stmt, null) != sqlite.SQLITE_OK) {
        fatal("failed to prepare insert statement");
    }
    defer _ = sqlite.sqlite3_finalize(insert_stmt);

    // Load WAL entries into the table.
    _ = sqlite.sqlite3_exec(db, "BEGIN", null, null, null);

    var slot: u64 = 1;
    while (slot < entry_count) : (slot += 1) {
        const entry = read_entry_or_fatal(fd, slot * @sizeOf(Message));
        if (!entry.valid_checksum_header()) continue;

        _ = sqlite.sqlite3_reset(insert_stmt);

        // op, timestamp, operation
        _ = sqlite.sqlite3_bind_int64(insert_stmt, 1, @intCast(entry.op));
        _ = sqlite.sqlite3_bind_int64(insert_stmt, 2, entry.timestamp);
        const op_name = @tagName(entry.operation);
        _ = sqlite.sqlite3_bind_text(insert_stmt, 3, op_name.ptr, @intCast(op_name.len), sqlite.SQLITE_STATIC);

        // id, user_id as hex strings
        var id_buf: [32]u8 = undefined;
        var user_buf: [32]u8 = undefined;
        format_uuid_compact(&id_buf, entity_id(&entry));
        format_uuid_compact(&user_buf, entry.user_id);
        _ = sqlite.sqlite3_bind_text(insert_stmt, 4, &id_buf, 32, sqlite.SQLITE_STATIC);
        _ = sqlite.sqlite3_bind_text(insert_stmt, 5, &user_buf, 32, sqlite.SQLITE_STATIC);

        // Body fields — NULL for operations that don't have them.
        switch (entry.operation) {
            .create_product, .update_product => {
                const p = entry.body_as(message.Product);
                _ = sqlite.sqlite3_bind_text(insert_stmt, 6, &p.name, p.name_len, sqlite.SQLITE_STATIC);
                _ = sqlite.sqlite3_bind_int64(insert_stmt, 7, p.price_cents);
                _ = sqlite.sqlite3_bind_int64(insert_stmt, 8, p.inventory);
                _ = sqlite.sqlite3_bind_int64(insert_stmt, 9, p.version);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 10);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 11);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 12);
            },
            .create_collection => {
                const col = entry.body_as(message.ProductCollection);
                _ = sqlite.sqlite3_bind_text(insert_stmt, 6, &col.name, col.name_len, sqlite.SQLITE_STATIC);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 7);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 8);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 9);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 10);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 11);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 12);
            },
            .create_order => {
                const o = entry.body_as(message.OrderRequest);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 6);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 7);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 8);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 9);
                _ = sqlite.sqlite3_bind_int64(insert_stmt, 10, o.items_len);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 11);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 12);
            },
            .transfer_inventory => {
                const t = entry.body_as(message.InventoryTransfer);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 6);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 7);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 8);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 9);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 10);
                _ = sqlite.sqlite3_bind_int64(insert_stmt, 11, t.quantity);
                var target_buf: [32]u8 = undefined;
                format_uuid_compact(&target_buf, t.target_id);
                _ = sqlite.sqlite3_bind_text(insert_stmt, 12, &target_buf, 32, sqlite.SQLITE_STATIC);
            },
            else => {
                _ = sqlite.sqlite3_bind_null(insert_stmt, 6);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 7);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 8);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 9);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 10);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 11);
                _ = sqlite.sqlite3_bind_null(insert_stmt, 12);
            },
        }

        _ = sqlite.sqlite3_step(insert_stmt);
    }

    _ = sqlite.sqlite3_exec(db, "COMMIT", null, null, null);

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

/// Format a u128 as 32 lowercase hex chars (no dashes).
fn format_uuid_compact(buf: *[32]u8, value: u128) void {
    const bytes: [16]u8 = @bitCast(value);
    const hex_chars = "0123456789abcdef";
    // Big-endian: most significant byte first.
    var pos: usize = 0;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[pos] = hex_chars[bytes[i] >> 4];
        buf[pos + 1] = hex_chars[bytes[i] & 0xf];
        pos += 2;
    }
}

// =====================================================================
// Replay
// =====================================================================

fn replay(args: ReplayArgs) void {
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

    var sm = StateMachine.init(&storage, args.trace);

    // Open WAL and verify root.
    const fd = open_wal(args.path);
    defer std.posix.close(fd);

    const file_size = get_file_size(fd);
    if (file_size == 0) fatal("empty WAL file");

    const entry_count = file_size / @sizeOf(Message);
    if (entry_count == 0) fatal("WAL too small for root entry");

    const root_entry = read_entry_or_fatal(fd, 0);
    const expected_root = Wal.root();
    if (root_entry.checksum != expected_root.checksum) {
        fatal("root checksum mismatch — WAL written by incompatible version");
    }

    const stop_at = args.@"stop-at" orelse std.math.maxInt(u64);

    // Replay entries forward.
    var replayed: u64 = 0;
    var slot: u64 = 1;
    while (slot < entry_count) : (slot += 1) {
        const entry = read_entry_or_fatal(fd, slot * @sizeOf(Message));

        if (!entry.valid_checksum()) {
            fatal_fmt("checksum failed at op {d} (slot {d})", .{ entry.op, slot });
        }

        if (!entry.operation.is_mutation()) {
            fatal_fmt("non-mutation operation '{s}' at op {d}", .{ @tagName(entry.operation), entry.op });
        }

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

        // Storage errors during replay indicate infrastructure failure
        // (disk full, corruption) — not a normal application result.
        if (resp.status == .storage_error) {
            write_stderr("replay: storage error at op {d}: {s}\n", .{
                entry.op,
                @tagName(entry.operation),
            });
            @panic("replay: storage error — cannot continue");
        }

        replayed += 1;
    }

    const stdout = std.io.getStdOut().writer();
    stdout.print("replay complete: {d} entries\n", .{replayed}) catch {};
}

/// Derive a work database path from the WAL path: "<wal-path>.replay.db\0".
fn derive_work_path(buf: *[4096]u8, wal_path: []const u8) [:0]const u8 {
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

/// Extract the primary entity ID for display. Operations that carry
/// their entity ID in the body (create_product, create_collection, etc.)
/// need body-aware extraction; the rest use msg.id from the header.
fn entity_id(entry: *const Message) u128 {
    return switch (entry.operation) {
        .create_product => entry.body_as(message.Product).id,
        .create_collection => entry.body_as(message.ProductCollection).id,
        .create_order => entry.body_as(message.OrderRequest).id,
        else => entry.id,
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

// =====================================================================
// Replay tests
// =====================================================================

const replay_wal_path: [:0]const u8 = "/tmp/tiger_replay_replay_test.wal";
const replay_snap_path: [:0]const u8 = "/tmp/tiger_replay_snapshot.db";
const replay_work_path: [:0]const u8 = "/tmp/tiger_replay_replay_test.wal.replay.db";

fn replay_cleanup() void {
    std.posix.unlink(replay_wal_path) catch {};
    std.posix.unlink(replay_snap_path) catch {};
    std.posix.unlink(replay_work_path) catch {};
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
        var sm = MemSM.init(&mem_storage, false);

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

    replay(ReplayArgs{
        .@"stop-at" = null,
        .trace = false,
        .@"--" = {},
        .path = replay_wal_path,
        .snapshot = replay_snap_path,
    });

    // Phase 3: Verify the replayed database has the correct state.
    var verify_storage = try SqliteStorage.init(replay_work_path);
    defer verify_storage.deinit();
    var verify_sm = StateMachine.init(&verify_storage, false);

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
        var sm = MemSM.init(&mem_storage, false);

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

    replay(ReplayArgs{
        .@"stop-at" = 2,
        .trace = false,
        .@"--" = {},
        .path = replay_wal_path,
        .snapshot = replay_snap_path,
    });

    // Verify: products 1 and 2 exist, product 3 does not.
    var verify_storage = try SqliteStorage.init(replay_work_path);
    defer verify_storage.deinit();
    var verify_sm = StateMachine.init(&verify_storage, false);

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
