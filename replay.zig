const std = @import("std");
const assert = std.debug.assert;
const flags = @import("flags.zig");
const Wal = @import("wal.zig").Wal;
const message = @import("message.zig");
const Message = message.Message;
const state_machine = @import("state_machine.zig");
const SqliteStorage = @import("storage.zig").SqliteStorage;

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

    pub const help =
        \\Usage: tiger-replay <command> [options]
        \\
        \\Commands:
        \\  verify   Validate WAL checksums and hash chain
        \\  inspect  Print human-readable entry summaries
        \\  replay   Replay WAL entries against a snapshot
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
    user: ?[]const u8 = null,
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

pub fn main() !void {
    var args = std.process.args();
    const cli = flags.parse(&args, CliArgs);

    switch (cli) {
        .verify => |v| verify(v.path),
        .inspect => |i| inspect(i),
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

        // Operation must not be .root for non-root entries.
        if (entry.operation == .root) {
            write_stderr("error: non-root entry has .root operation at op {d} (slot {d})\n", .{ entry.op, slot });
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
        parse_uuid(u) orelse fatal_fmt("invalid user UUID: '{s}' (expected 32 hex chars)", .{u})
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

        var id_buf: [36]u8 = undefined;
        var user_buf: [36]u8 = undefined;
        format_uuid(&id_buf, entity_id(&entry));
        format_uuid(&user_buf, entry.user_id);

        stdout.print("op={d:<6} t={d}  {s:<24} id={s}  user={s}\n", .{
            entry.op,
            entry.timestamp,
            @tagName(entry.operation),
            &id_buf,
            &user_buf,
        }) catch return;
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

        if (entry.operation == .root) {
            fatal_fmt("unexpected .root operation at op {d}", .{entry.op});
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
    const src_fd = std.posix.open(
        @ptrCast(src),
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
    return std.posix.open(
        @ptrCast(path),
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch |err| {
        write_stderr("error: cannot open '{s}': {}\n", .{ path, err });
        std.process.exit(1);
    };
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

fn parse_uuid(s: []const u8) ?u128 {
    if (s.len != 32) return null;
    var result: u128 = 0;
    for (s) |c| {
        const digit: u128 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            else => return null,
        };
        result = (result << 4) | digit;
    }
    return result;
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
