//! Replay round-trip fuzzer — exercises all mutation types through the WAL
//! serialization boundary and verifies the replayed state matches.
//!
//! Phase 1: Run random mutations against MemoryStorage, recording each
//!          committed mutation to a WAL file.
//! Phase 2: Replay the WAL into a fresh SqliteStorage.
//! Phase 3: Read back every entity from both backends and assert agreement.
//!
//! This catches body layout mismatches between WAL encoding and SqliteStorage
//! consumption, operations where body_as(T) reads different bytes than
//! Message.init wrote, and ordering dependencies.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const auth = @import("framework/auth.zig");
const MemoryStorage = state_machine.MemoryStorage;
const SqliteStorage = @import("storage.zig").SqliteStorage;
const Wal = @import("wal.zig").Wal;
const replay_mod = @import("replay.zig");
const Auditor = @import("auditor.zig").Auditor;
const fuzz_lib = @import("fuzz_lib.zig");
const FuzzArgs = fuzz_lib.FuzzArgs;
const PRNG = @import("framework/prng.zig");
const gen = @import("fuzz.zig");
const stdx = @import("framework/stdx.zig");

const replay_fuzz_test_key: *const [auth.key_length]u8 = "tiger-web-test-key-0123456789ab!";

const log = std.log.scoped(.fuzz);

const MemSM = state_machine.StateMachineType(MemoryStorage);
const SqlSM = state_machine.StateMachineType(SqliteStorage);

pub fn main(allocator: std.mem.Allocator, args: FuzzArgs) !void {
    const seed = args.seed;
    const events_max = args.events_max orelse 10_000;
    var prng = PRNG.from_seed(seed);

    // Phase 1: Run mutations through MemoryStorage + WAL.
    var mem_storage = try MemoryStorage.init(std.heap.page_allocator);
    defer mem_storage.deinit(std.heap.page_allocator);

    var mem_sm = MemSM.init(&mem_storage, false, seed, replay_fuzz_test_key);
    mem_sm.now = 1_700_000_000;

    var auditor = try Auditor.init(allocator);
    defer auditor.deinit(allocator);

    // Only mutations enter the WAL — filter to mutation operations only.
    var op_weights = fuzz_lib.random_enum_weights(&prng, message.Operation);
    op_weights.root = 0;
    // Zero out read-only operations — they don't enter the WAL and
    // can't be replayed. The point of this fuzzer is WAL round-trip.
    inline for (comptime std.enums.values(message.Operation)) |op| {
        if (!op.is_mutation()) {
            @field(op_weights, @tagName(op)) = 0;
        }
    }

    const wal_path: [:0]const u8 = "/tmp/tiger_replay_fuzz.wal";
    const snap_path: [:0]const u8 = "/tmp/tiger_replay_fuzz_snapshot.db";
    const work_path: [:0]const u8 = "/tmp/tiger_replay_fuzz.wal.replay.db";

    // Clean up any leftover files from a previous run.
    cleanup(wal_path, snap_path, work_path);

    var coverage = gen.OperationCoverage{};

    const committed = phase1: {
        var wal = Wal.init(wal_path);
        defer wal.deinit();

        var count: u64 = 0;
        var timestamp: i64 = 1_700_000_000;

        for (0..events_max) |_| {
            timestamp += @intCast(prng.range_inclusive(u32, 1, 5));
            mem_sm.now = timestamp;

            const operation = prng.enum_weighted(message.Operation, op_weights);

            if (auditor.at_capacity(operation)) continue;

            const msg = gen.gen_message(&prng, operation, auditor.id_pools()) orelse continue;

            if (!MemSM.input_valid(msg)) continue;

            // No faults configured — prefetch must never return busy.
            if (!mem_sm.prefetch(msg)) @panic("prefetch returned busy with no faults");

            const resp = mem_sm.commit(msg);
            auditor.on_commit(msg, resp);

            // All operations reaching here are mutations (non-mutation weights
            // are zeroed) with no fault injection (MemoryStorage has no prng).
            assert(msg.operation.is_mutation());
            assert(resp.status != .storage_error);

            const entry = wal.prepare(msg, timestamp);
            wal.append(&entry);
            coverage.record(operation);
            count += 1;
        }

        break :phase1 count;
    }; // WAL closed here via defer.

    coverage.assert_full_coverage(op_weights);

    log.info("phase 1: {d} mutations committed to WAL", .{committed});

    if (committed == 0) {
        cleanup(wal_path, snap_path, work_path);
        return;
    }

    // Phase 2: Replay WAL into fresh SqliteStorage using the production
    // replay_entries function — exercises the real code path including
    // hash chain verification and all entry validation.
    {
        var snap_storage = try SqliteStorage.init(snap_path);
        snap_storage.deinit();
    }

    copy_file(snap_path, work_path);

    var sql_storage = try SqliteStorage.init(work_path);
    defer sql_storage.deinit();

    var sql_sm = SqlSM.init(&sql_storage, false, seed, replay_fuzz_test_key);

    const read_fd = std.posix.open(
        wal_path,
        .{ .ACCMODE = .RDONLY },
        0,
    ) catch @panic("failed to open WAL for replay");
    defer std.posix.close(read_fd);

    const file_size: u64 = @intCast((std.posix.fstat(read_fd) catch
        @panic("fstat failed")).size);
    const entry_count = file_size / @sizeOf(message.Message);
    assert(file_size % @sizeOf(message.Message) == 0);
    assert(entry_count > 0); // At least the root.

    const root_checksum = (Wal.read_entry(read_fd, 0) orelse
        @panic("failed to read root")).checksum;

    const replayed = replay_mod.replay_entries(
        read_fd,
        &sql_sm,
        entry_count,
        root_checksum,
        std.math.maxInt(u64),
    );

    assert(replayed == committed);
    log.info("phase 2: {d} entries replayed", .{replayed});

    // Phase 3: Verify — read every known entity from both backends,
    // assert they agree.
    verify_products(&mem_storage, &sql_storage);
    verify_collections(&mem_storage, &sql_storage);
    verify_orders(&mem_storage, &sql_storage);
    verify_login_state(&mem_storage, &sql_storage);

    log.info("phase 3: all entities verified", .{});

    cleanup(wal_path, snap_path, work_path);
}

// =====================================================================
// Verification — compare MemoryStorage vs replayed SqliteStorage
// =====================================================================

fn verify_products(mem: *MemoryStorage, sql: *SqliteStorage) void {
    // List ALL products from both backends (cursor=0, no filters).
    var mem_list: [message.list_max]message.Product = undefined;
    var sql_list: [message.list_max]message.Product = undefined;
    var mem_len: u32 = 0;
    var sql_len: u32 = 0;

    var cursor: u128 = 0;
    var total_mem: u32 = 0;
    var total_sql: u32 = 0;

    // Page through all products using cursor-based pagination.
    while (true) {
        var params = std.mem.zeroes(message.ListParams);
        params.cursor = cursor;
        // Include inactive products so soft-deletes are verified.
        params.active_filter = .any;

        assert(mem.list(&mem_list, &mem_len, params) == .ok);
        assert(sql.list(&sql_list, &sql_len, params) == .ok);

        if (mem_len != sql_len) {
            std.debug.panic("product list len mismatch: mem={d} sql={d} (cursor={d})", .{ mem_len, sql_len, cursor });
        }

        if (mem_len == 0) break;

        for (mem_list[0..mem_len], sql_list[0..sql_len]) |*mp, *sp| {
            if (!stdx.equal_bytes(message.Product, mp, sp)) {
                std.debug.panic("product mismatch: id={d}", .{mp.id});
            }
        }

        total_mem += mem_len;
        total_sql += sql_len;
        cursor = mem_list[mem_len - 1].id;
    }

    assert(total_mem == total_sql);
    log.debug("verified {d} products", .{total_mem});
}

fn verify_collections(mem: *MemoryStorage, sql: *SqliteStorage) void {
    var mem_list: [message.list_max]message.ProductCollection = undefined;
    var sql_list: [message.list_max]message.ProductCollection = undefined;
    var mem_len: u32 = 0;
    var sql_len: u32 = 0;

    var cursor: u128 = 0;
    var total: u32 = 0;
    var total_members: u32 = 0;

    while (true) {
        assert(mem.list_collections(&mem_list, &mem_len, cursor) == .ok);
        assert(sql.list_collections(&sql_list, &sql_len, cursor) == .ok);

        if (mem_len != sql_len) {
            std.debug.panic("collection list len mismatch: mem={d} sql={d}", .{ mem_len, sql_len });
        }

        if (mem_len == 0) break;

        for (mem_list[0..mem_len], sql_list[0..sql_len]) |*mc, *sc| {
            if (!stdx.equal_bytes(message.ProductCollection, mc, sc)) {
                std.debug.panic("collection mismatch: id={d}", .{mc.id});
            }

            // Verify membership data for each collection.
            var mem_members: [message.list_max]message.Product = undefined;
            var sql_members: [message.list_max]message.Product = undefined;
            var mem_member_len: u32 = 0;
            var sql_member_len: u32 = 0;

            assert(mem.list_products_in_collection(mc.id, &mem_members, &mem_member_len) == .ok);
            assert(sql.list_products_in_collection(mc.id, &sql_members, &sql_member_len) == .ok);

            if (mem_member_len != sql_member_len) {
                std.debug.panic("collection {d} member count mismatch: mem={d} sql={d}", .{ mc.id, mem_member_len, sql_member_len });
            }
            for (mem_members[0..mem_member_len], sql_members[0..sql_member_len]) |*mp, *sp| {
                if (!stdx.equal_bytes(message.Product, mp, sp)) {
                    std.debug.panic("collection {d} member product mismatch: id={d}", .{ mc.id, mp.id });
                }
            }
            total_members += mem_member_len;
        }

        total += mem_len;
        cursor = mem_list[mem_len - 1].id;
    }

    log.debug("verified {d} collections, {d} memberships", .{ total, total_members });
}

fn verify_orders(mem: *MemoryStorage, sql: *SqliteStorage) void {
    var mem_list: [message.list_max]message.OrderSummary = undefined;
    var sql_list: [message.list_max]message.OrderSummary = undefined;
    var mem_len: u32 = 0;
    var sql_len: u32 = 0;

    var cursor: u128 = 0;
    var total: u32 = 0;

    while (true) {
        assert(mem.list_orders(&mem_list, &mem_len, cursor) == .ok);
        assert(sql.list_orders(&sql_list, &sql_len, cursor) == .ok);

        if (mem_len != sql_len) {
            std.debug.panic("order list len mismatch: mem={d} sql={d}", .{ mem_len, sql_len });
        }

        if (mem_len == 0) break;

        for (mem_list[0..mem_len], sql_list[0..sql_len]) |*mo, *so| {
            if (!stdx.equal_bytes(message.OrderSummary, mo, so)) {
                std.debug.panic("order summary mismatch: id={d}", .{mo.id});
            }

            // Verify full order including line items.
            var mem_order: message.OrderResult = undefined;
            var sql_order: message.OrderResult = undefined;

            assert(mem.get_order(mo.id, &mem_order) == .ok);
            assert(sql.get_order(mo.id, &sql_order) == .ok);

            if (mem_order.items_len != sql_order.items_len) {
                std.debug.panic("order {d} items_len mismatch: mem={d} sql={d}", .{ mo.id, mem_order.items_len, sql_order.items_len });
            }
            for (
                mem_order.items[0..mem_order.items_len],
                sql_order.items[0..sql_order.items_len],
            ) |*mi, *si| {
                if (!stdx.equal_bytes(message.OrderResultItem, mi, si)) {
                    std.debug.panic("order {d} item mismatch: product_id={d}", .{ mo.id, mi.product_id });
                }
            }
        }

        total += mem_len;
        cursor = mem_list[mem_len - 1].id;
    }

    log.debug("verified {d} orders (with items)", .{total});
}

fn verify_login_state(mem: *MemoryStorage, sql: *SqliteStorage) void {
    var login_codes: u32 = 0;
    var users: u32 = 0;

    // Iterate MemoryStorage's login_codes array — no list API exists.
    for (&mem.login_codes) |*entry| {
        if (!entry.occupied) continue;
        const email = entry.email[0..entry.email_len];

        var sql_entry: SqliteStorage.LoginCodeEntry = undefined;
        const result = sql.get_login_code(email, &sql_entry);
        if (result != .ok) {
            std.debug.panic("login code missing in sql for email len={d}", .{entry.email_len});
        }
        assert(sql_entry.occupied);
        assert(sql_entry.email_len == entry.email_len);
        assert(std.mem.eql(u8, &sql_entry.code, &entry.code));
        assert(sql_entry.expires_at == entry.expires_at);
        login_codes += 1;
    }

    // Iterate MemoryStorage's users array.
    for (&mem.users) |*entry| {
        if (!entry.occupied) continue;
        const email = entry.email[0..entry.email_len];

        var sql_user_id: u128 = undefined;
        const result = sql.get_user_by_email(email, &sql_user_id);
        if (result != .ok) {
            std.debug.panic("user missing in sql for email len={d}", .{entry.email_len});
        }
        assert(sql_user_id == entry.user_id);
        users += 1;
    }

    log.debug("verified {d} login codes, {d} users", .{ login_codes, users });
}

// =====================================================================
// Helpers
// =====================================================================

fn cleanup(wal_path: [:0]const u8, snap_path: [:0]const u8, work_path: [:0]const u8) void {
    const paths = [_][:0]const u8{ wal_path, snap_path, work_path };
    for (paths) |path| {
        std.posix.unlink(path) catch {};
        inline for (.{ "-wal", "-shm" }) |suffix| {
            var buf: [4096]u8 = undefined;
            @memcpy(buf[0..path.len], path);
            @memcpy(buf[path.len..][0..suffix.len], suffix);
            buf[path.len + suffix.len] = 0;
            std.posix.unlink(buf[0 .. path.len + suffix.len :0]) catch {};
        }
    }
}

fn copy_file(src: [:0]const u8, dst: [:0]const u8) void {
    const src_fd = std.posix.open(src, .{ .ACCMODE = .RDONLY }, 0) catch
        @panic("cannot open snapshot for copy");
    defer std.posix.close(src_fd);

    const dst_fd = std.posix.open(dst, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch
        @panic("cannot create work file");
    defer std.posix.close(dst_fd);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.posix.read(src_fd, &buf) catch @panic("read snapshot failed");
        if (n == 0) break;
        var remaining = buf[0..n];
        while (remaining.len > 0) {
            const written = std.posix.write(dst_fd, remaining) catch @panic("write work file failed");
            if (written == 0) @panic("write returned 0");
            remaining = remaining[written..];
        }
    }
}
