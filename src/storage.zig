//! SqliteStorage — production storage backend backed by SQLite.
//!
//! Responsibilities:
//!   1. Translate domain operations into SQL. Prepared statements, parameter
//!      binding (never interpolation), WAL mode for concurrent reads.
//!   2. Map SQL results back to Zig structs. Column-to-field mapping by
//!      declaration order, with assert_column_count as a boundary check.
//!   3. Report availability honestly. Returns busy/err/corruption so the
//!      framework can retry or degrade — never panics on transient failures.
//!
//! NOT responsibilities:
//!   - Verifying SQL correctness against a reference model. We trust SQLite
//!     to execute SQL correctly. See docs/internal/decision-storage-ownership.md.
//!   - Domain logic. This file knows table schemas, not business rules.
//!     Whether an inventory transfer preserves totals is the handler's
//!     concern, not storage's.
//!
//! The typed SQL interface (query/execute/query_all) is the forward path —
//! new handlers use it exclusively. The legacy prepared-statement methods
//! (get/put/list/etc.) exist for the old state_machine dispatch and will
//! be removed as handlers migrate to the new API.

const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const StorageResult = state_machine.StorageResult;
const stdx = @import("stdx");
const proto = @import("protocol.zig");
const marks = @import("framework/marks.zig");
const log = marks.wrap_log(std.log.scoped(.storage));

const c = @cImport({
    @cInclude("sqlite3.h");
    // Zig shim: wraps SQLITE_TRANSIENT calls in C inline functions.
    // Zig's c_translation can't cast -1 to a function pointer on macOS
    // (alignment enforced). See vendor/sqlite3/sqlite3_zig.h.
    @cInclude("sqlite3_zig.h");
});

/// Statement cache size — must be large enough to avoid FNV-1a
/// collisions across all SQL strings. 256 slots for ~35 strings.
const stmt_cache_size = 256;
const raw_stmt_cache_size = 32;

/// Comptime slot assignment for prepared statement caching.
/// FNV-1a hash of the SQL string content, masked to cache size.
fn stmt_cache_slot(comptime sql: [*:0]const u8) comptime_int {
    comptime {
        var hash: u64 = 0xcbf29ce484222325;
        var i: usize = 0;
        while (sql[i] != 0) : (i += 1) {
            hash ^= sql[i];
            hash *%= 0x100000001b3;
        }
        return @intCast(hash & (stmt_cache_size - 1));
    }
}

pub const SqliteStorage = struct {
    pub const LoginCodeEntry = message.LoginCodeEntry;
    pub const QueryMode = proto.QueryMode;

    // No query result cache. Benchmarked (2026-04-04) and found no benefit:
    //
    // SQLite's page cache already serves in-memory reads in microseconds.
    // Adding a cache in front of it (keyed by sql_slot + param_hash,
    // invalidated on any write) added hash+compare+memcpy overhead that
    // matched or exceeded the SQLite query cost:
    //
    //   1KB cache (point reads):  ~0% change — list queries skip cache at
    //                             comptime, point reads too fast to benefit
    //   32KB cache (list results): -7% to -16% SLOWER — memcpy of 32KB
    //                             cached result exceeded SQLite's ~10µs
    //                             in-memory query for 10 products
    //
    // Disk-backed SQLite showed identical read performance (OS page cache).
    // The cache would only help with a storage backend where reads are
    // significantly slower than memcpy (network database, >100µs per query).
    // For SQLite, the database IS the cache.

    /// Read-only view of SqliteStorage for the prefetch phase.
    /// Exposes query/query_all.
    /// Write methods (execute, put, update, delete, begin, commit) are absent.
    /// The framework uses this type — handlers receive it as `storage: anytype`.
    pub const ReadView = struct {
        storage: *SqliteStorage,

        pub fn init(storage: *SqliteStorage) ReadView {
            return .{ .storage = storage };
        }

        // Typed SQL reads
        pub fn query(self: ReadView, comptime T: type, comptime sql_str: [*:0]const u8, args: anytype) ?T {
            return self.storage.query(T, sql_str, args);
        }

        pub fn query_all(self: ReadView, comptime T: type, comptime max: usize, comptime sql_str: [*:0]const u8, args: anytype) ?BoundedList(T, max) {
            return self.storage.query_all(T, max, sql_str, args);
        }

        // Raw SQL read — sidecar path. Runtime SQL, binary row format.
        pub fn query_raw(self: ReadView, sql: []const u8, params_buf: []const u8, params_count: u8, mode: proto.QueryMode, out_buf: []u8) ?[]const u8 {
            return self.storage.query_raw(sql, params_buf, params_count, mode, out_buf);
        }

    };

    /// Write-only view of SqliteStorage for the handle phase.
    /// Exposes execute() only — no reads. Handle writes SQL, the
    /// framework wraps handle in begin_batch/commit_batch.
    /// The `storage` field is structurally public (Zig has no private
    /// fields), but handlers receive this as `db: anytype` — only the
    /// methods on WriteView are part of the contract.
    pub const WriteView = struct {
        storage: *SqliteStorage,
        // WAL recording: if set, each execute() also records the SQL + params.
        record_buf: ?[]u8 = null,
        record_pos: usize = 0,
        record_count: u8 = 0,

        pub fn init(storage: *SqliteStorage) WriteView {
            return .{ .storage = storage };
        }

        pub fn init_recording(storage: *SqliteStorage, buf: []u8) WriteView {
            return .{ .storage = storage, .record_buf = buf };
        }

        /// Execute a write statement. Asserts success — if prefetch
        /// validated the data, the write must succeed. A failure here
        /// means the handler's precondition check was wrong.
        /// If recording is enabled, also records SQL + params for the WAL.
        pub fn execute(self: *WriteView, comptime sql_str: [*:0]const u8, args: anytype) void {
            const ok = self.storage.execute(sql_str, args);
            assert(ok);

            // Record for WAL if buffer is set.
            if (self.record_buf) |buf| {
                const sql_slice = std.mem.sliceTo(sql_str, 0);
                var pos = self.record_pos;

                // sql: [u16 BE sql_len][sql_bytes]
                if (pos + 2 + sql_slice.len > buf.len) return; // overflow — skip recording
                std.mem.writeInt(u16, buf[pos..][0..2], @intCast(sql_slice.len), .big);
                pos += 2;
                @memcpy(buf[pos..][0..sql_slice.len], sql_slice);
                pos += sql_slice.len;

                // params: [u8 param_count][params...]
                const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
                if (pos >= buf.len) return;
                buf[pos] = @intCast(fields.len);
                pos += 1;

                // Serialize each param using the binary protocol format.
                inline for (fields) |field| {
                    const val = @field(args, field.name);
                    pos = record_param(buf, pos, val);
                }

                self.record_pos = pos;
                self.record_count += 1;
            }
        }

        /// Execute a write statement from raw binary wire format (sidecar writes).
        /// Same as execute() but takes runtime SQL + binary params instead of
        /// comptime SQL + typed args. WAL recording is a memcpy — the wire
        /// format IS the recording format.
        pub fn execute_raw(self: *WriteView, sql: []const u8, params_buf: []const u8, param_count: u8) bool {
            if (!self.storage.execute_raw(sql, params_buf, param_count)) {
                return false;
            }

            // Record for WAL if buffer is set. The sidecar's binary format
            // matches the WAL recording format exactly — just memcpy.
            if (self.record_buf) |buf| {
                var pos = self.record_pos;

                // sql: [u16 BE sql_len][sql_bytes]
                const entry_len = 2 + sql.len + 1 + params_buf.len;
                if (pos + entry_len > buf.len) return true; // overflow — skip recording
                std.mem.writeInt(u16, buf[pos..][0..2], @intCast(sql.len), .big);
                pos += 2;
                @memcpy(buf[pos..][0..sql.len], sql);
                pos += sql.len;

                // params: [u8 param_count][params...]
                buf[pos] = param_count;
                pos += 1;
                @memcpy(buf[pos..][0..params_buf.len], params_buf);
                pos += params_buf.len;

                self.record_pos = pos;
                self.record_count += 1;
            }

            return true;
        }
    };

    /// Serialize a single param value into the WAL recording buffer.
    /// Same binary format as the sidecar protocol (protocol.zig TypeTag).
    fn record_param(buf: []u8, pos_in: usize, val: anytype) usize {
        const T = @TypeOf(val);
        var pos = pos_in;
        if (pos >= buf.len) return pos;

        if (T == u128) {
            buf[pos] = 0x04; // blob
            pos += 1;
            if (pos + 2 + 16 > buf.len) return pos;
            std.mem.writeInt(u16, buf[pos..][0..2], 16, .big);
            pos += 2;
            std.mem.writeInt(u128, buf[pos..][0..16], val, .big);
            pos += 16;
        } else if (T == bool) {
            buf[pos] = 0x01; // integer
            pos += 1;
            if (pos + 8 > buf.len) return pos;
            std.mem.writeInt(i64, buf[pos..][0..8], if (val) 1 else 0, .little);
            pos += 8;
        } else if (comptime is_byte_slice(T)) {
            buf[pos] = 0x03; // text
            pos += 1;
            const slice: []const u8 = val;
            if (pos + 2 + slice.len > buf.len) return pos;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(slice.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..slice.len], slice);
            pos += slice.len;
        } else if (comptime is_string_literal(T)) {
            buf[pos] = 0x03; // text
            pos += 1;
            const slice: []const u8 = val;
            if (pos + 2 + slice.len > buf.len) return pos;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(slice.len), .big);
            pos += 2;
            @memcpy(buf[pos..][0..slice.len], slice);
            pos += slice.len;
        } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            buf[pos] = 0x01; // integer
            pos += 1;
            if (pos + 8 > buf.len) return pos;
            std.mem.writeInt(i64, buf[pos..][0..8], @intCast(val), .little);
            pos += 8;
        } else {
            // Unknown type — skip.
            buf[pos] = 0x05; // null
            pos += 1;
        }
        return pos;
    }

    db: *c.sqlite3,

    /// Prepared statement cache for the typed SQL API (query/execute).
    /// Indexed by comptime slot — each unique SQL string gets a unique
    /// index resolved at compile time. Eliminates sqlite3_prepare_v2
    /// on the hot path (was 22% of CPU before caching).
    stmt_cache: [stmt_cache_size]?*c.sqlite3_stmt,

    /// Runtime prepared statement cache for query_raw / execute_raw.
    /// Keyed by SQL string pointer identity (prefetch.generated.zig
    /// strings are comptime — same pointer every call).
    raw_cache_keys: [raw_stmt_cache_size]?[]const u8 = .{null} ** raw_stmt_cache_size,
    raw_cache_stmts: [raw_stmt_cache_size]?*c.sqlite3_stmt = .{null} ** raw_stmt_cache_size,

    pub fn init(path: [*:0]const u8) !SqliteStorage {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &db);
        if (rc != c.SQLITE_OK) {
            if (db) |d| _ = c.sqlite3_close(d);
            return error.SqliteOpenFailed;
        }

        const real_db = db.?;

        // Enable WAL mode.
        exec(real_db, "PRAGMA journal_mode=WAL;");

        // Skip fsync on regular commits — safe against process crash,
        // not bare-metal power loss. SQLite's WAL journal survives process
        // crashes regardless. On cloud VPS (AWS EBS, GCP, Hetzner), the
        // storage backend provides power-loss durability, making NORMAL
        // effectively equivalent to FULL.
        //
        // Measured impact: 30,574 → 37,099 req/s (+21%) at 128 connections.
        // The fsync per tick (~10-50μs on NVMe) was the hidden floor.
        exec(real_db, "PRAGMA synchronous=NORMAL;");

        // Busy timeout: 1 second.
        _ = c.sqlite3_busy_timeout(real_db, 1000);

        ensure_schema(real_db);

        log.info("storage initialized: {s}", .{path});

        return .{
            .db = real_db,
            .stmt_cache = .{null} ** stmt_cache_size,
        };
    }

    pub fn begin(self: *SqliteStorage) void {
        exec(self.db, "BEGIN;");
    }

    pub fn commit(self: *SqliteStorage) void {
        exec(self.db, "COMMIT;");
    }

    pub fn rollback(self: *SqliteStorage) void {
        exec(self.db, "ROLLBACK;");
    }

    pub fn deinit(self: *SqliteStorage) void {
        // Finalize cached statements from the typed API.
        for (&self.stmt_cache) |*slot| {
            if (slot.*) |cached| {
                _ = c.sqlite3_finalize(cached);
                slot.* = null;
            }
        }

        _ = c.sqlite3_close(self.db);
    }

    // --- Typed SQL interface ---
    //
    // The production-path API. Handlers call db.query() / db.execute()
    // with raw SQL and typed params. This is the boundary we own and test:
    //
    // 1. Params are bound, never interpolated (injection is structurally
    //    impossible — there is no string concatenation path).
    // 2. Zig types map correctly to SQLite bind/column calls.
    // 3. Column count matches struct field count (assert_column_count).
    // 4. Statement lifecycle is correct (prepare, bind, step, finalize).
    //
    // We do NOT test that SQLite executes SQL correctly — it has its own
    // fuzz suite (billions of test cases, 100% branch coverage). Our
    // round-trip tests verify the translation boundary, not the database.
    //
    // Statements are prepared per-call (not cached). Caching can be added
    // later as an optimization without changing the interface.

    /// Query a single row, mapped to struct T. Returns null if not found
    /// or on step error (busy/locked). Prepare failure is an assert — the
    /// SQL is comptime, so if it doesn't prepare, the schema and code disagree.
    pub fn query(self: *SqliteStorage, comptime T: type, comptime sql_str: [*:0]const u8, args: anytype) ?T {
        const stmt = self.prepare_and_bind(sql_str, args);
        assert(c.sqlite3_stmt_readonly(stmt) != 0);

        if (step_result(stmt) != .row) return null;
        const mapping = build_column_mapping(T, stmt);
        return read_row_mapped(T, stmt, mapping);
    }

    /// Query multiple rows into a bounded array. Returns null on step error.
    /// Column→field name mapping is built once on the first row, then reused
    /// for all subsequent rows — no per-row string comparisons.
    pub fn query_all(self: *SqliteStorage, comptime T: type, comptime max: usize, comptime sql_str: [*:0]const u8, args: anytype) ?BoundedList(T, max) {
        comptime {
            const sql: []const u8 = std.mem.span(sql_str);
            var upper: [sql.len]u8 = undefined;
            for (sql, 0..) |ch, i| {
                upper[i] = std.ascii.toUpper(ch);
            }
            if (std.mem.indexOf(u8, &upper, "LIMIT") == null) {
                @compileError("query_all requires LIMIT in SQL — unbounded SELECT is not allowed: " ++ sql);
            }
        }
        const stmt = self.prepare_and_bind(sql_str, args);
        assert(c.sqlite3_stmt_readonly(stmt) != 0);

        var result = BoundedList(T, max){};
        var mapping_built = false;
        var mapping: ColumnMapping(T) = undefined;
        while (step_result(stmt) == .row) {
            if (!mapping_built) {
                mapping = build_column_mapping(T, stmt);
                mapping_built = true;
            }
            assert(result.len < max);
            result.items[result.len] = read_row_mapped(T, stmt, mapping);
            result.len += 1;
        }
        return result;
    }

    /// Execute a SQL statement (INSERT, UPDATE, DELETE). Returns false on
    /// step error (busy/constraint). Prepare failure is an assert.
    pub fn execute(self: *SqliteStorage, comptime sql_str: [*:0]const u8, args: anytype) bool {
        const stmt = self.prepare_and_bind(sql_str, args);
        assert(c.sqlite3_stmt_readonly(stmt) == 0);
        return step_result(stmt) == .done;
    }

    // =================================================================
    // Raw query — sidecar path. Reads SQLite results into binary row
    // format without knowing domain types. Runtime SQL (validated by
    // scanner at build time, but untrusted at the wire level).
    //
    // Error paths use log.mark.warn, not log.mark.err. These are err-
    // severity conditions in production (sidecar bug or corruption),
    // but Zig's test runner fails on any err-level log output. The
    // marks system can't override the test runner. Using warn lets
    // tests assert the error path fires via mark.expect_hit() without
    // the test runner treating the log as a failure. Production
    // severity is sacrificed for testability — the mark fires either way.
    // =================================================================

    /// Execute a runtime SQL query and write results into the binary
    /// row format. Returns the used portion of buf, or null on error
    /// (bad SQL, prepare failure, step error).
    ///
    /// SQL is `[]const u8` (length-prefixed from wire), not null-terminated.
    /// `mode`: .query = at most 1 row, .query_all = up to list_max rows.
    /// `params_buf`: binary params from the sidecar wire format.
    /// `params_count`: number of params in params_buf.
    ///
    /// Column types in the header: set from the first row's actual types.
    /// For empty results (0 rows), types are `.null` — a SQLite limitation
    /// (column_type is per-row, not per-schema). The TS reader handles
    /// this: 0 rows means no values to interpret, so types don't matter.
    pub fn query_raw(
        self: *SqliteStorage,
        sql: []const u8,
        params_buf: []const u8,
        params_count: u8,
        mode: proto.QueryMode,
        out_buf: []u8,
    ) ?[]const u8 {
        // Try cached prepared statement (keyed by pointer identity).
        const cached = self.raw_cache_get(sql);
        const real_stmt = if (cached) |stmt| blk: {
            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);
            break :blk stmt;
        } else blk: {
            const stmt = self.prepare_raw(sql) orelse return null;
            self.raw_cache_put(sql, stmt);
            break :blk stmt;
        };
        // Don't finalize — cached for reuse.

        // Belt-and-suspenders: scanner validates SELECT at build time,
        // runtime validates here. Catches sidecar bugs.
        if (c.sqlite3_stmt_readonly(real_stmt) == 0) {
            log.mark.warn("query_raw: statement is not read-only", .{});
            return null;
        }

        if (!bind_raw_params(real_stmt, params_buf, params_count)) return null;

        // Read column metadata.
        const col_count_raw = c.sqlite3_column_count(real_stmt);
        if (col_count_raw <= 0 or col_count_raw > proto.columns_max) return null;
        const col_count: u16 = @intCast(col_count_raw);

        var columns: [proto.columns_max]proto.Column = undefined;
        for (0..col_count) |i| {
            const ci: c_int = @intCast(i);
            const name_ptr = c.sqlite3_column_name(real_stmt, ci);
            if (name_ptr == null) return null;
            const name = std.mem.sliceTo(name_ptr, 0);
            columns[i] = .{ .type_tag = .null, .name = name };
        }

        // Write header + placeholder row count.
        var pos = proto.write_row_set_header(out_buf, columns[0..col_count]) orelse return null;
        const row_count_pos = pos;
        pos = proto.write_row_count(out_buf, pos, 0) orelse return null;

        var row_count: u32 = 0;
        const max_rows: u32 = switch (mode) {
            .query => 1,
            .query_all => message.list_max,
        };

        while (step_result(real_stmt) == .row and row_count < max_rows) {
            // First row: backfill column types from actual SQLite types.
            if (row_count == 0) {
                var header_pos: usize = 2; // skip col_count u16
                for (0..col_count) |i| {
                    const ci: c_int = @intCast(i);
                    const sqlite_type = c.sqlite3_column_type(real_stmt, ci);
                    out_buf[header_pos] = @intFromEnum(sqlite_type_to_tag(sqlite_type));
                    const name_len = std.mem.readInt(u16, out_buf[header_pos + 1 ..][0..2], .big);
                    header_pos += 1 + 2 + name_len;
                }
            }

            for (0..col_count) |i| {
                const ci: c_int = @intCast(i);
                const sqlite_type = c.sqlite3_column_type(real_stmt, ci);
                pos = proto.write_value(out_buf, pos, read_sqlite_value(real_stmt, ci, sqlite_type)) orelse return null;
            }
            row_count += 1;
        }

        // Backfill row count.
        std.mem.writeInt(u32, out_buf[row_count_pos..][0..4], row_count, .big);
        return out_buf[0..pos];
    }

    /// Execute a runtime SQL write statement with binary params.
    /// Returns true on success, false on error.
    pub fn execute_raw(
        self: *SqliteStorage,
        sql: []const u8,
        params_buf: []const u8,
        params_count: u8,
    ) bool {
        const real_stmt = self.prepare_raw(sql) orelse return false;
        defer _ = c.sqlite3_finalize(real_stmt);

        // Belt-and-suspenders: scanner validates write-only at build time.
        if (c.sqlite3_stmt_readonly(real_stmt) != 0) {
            log.mark.warn("execute_raw: statement is read-only", .{});
            return false;
        }

        if (!bind_raw_params(real_stmt, params_buf, params_count)) return false;
        return step_result(real_stmt) == .done;
    }

    /// Prepare a runtime SQL statement. Returns null on failure.
    /// SQL is []const u8 (length-prefixed from wire), not null-terminated.
    fn prepare_raw(self: *SqliteStorage, sql: []const u8) ?*c.sqlite3_stmt {
        assert(sql.len > 0); // empty SQL is never valid — sidecar bug
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) {
            if (stmt) |s| _ = c.sqlite3_finalize(s);
            log.mark.warn("prepare_raw: failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return null;
        }
        return stmt.?;
    }

    /// Hash SQL content for cache slot selection.
    /// FNV-1a: fast, good distribution, no allocation.
    fn sql_hash(sql: []const u8) usize {
        var h: u64 = 0xcbf29ce484222325;
        for (sql) |b| {
            h ^= b;
            h *%= 0x100000001b3;
        }
        return @intCast(h % raw_stmt_cache_size);
    }

    /// Look up a cached prepared statement by SQL content hash.
    /// Content comparison avoids stale hits when different SQL
    /// reuses the same buffer address (2-RT dispatch entries).
    fn raw_cache_get(self: *SqliteStorage, sql: []const u8) ?*c.sqlite3_stmt {
        const slot = sql_hash(sql);
        if (self.raw_cache_keys[slot]) |cached_key| {
            if (cached_key.len == sql.len and std.mem.eql(u8, cached_key, sql)) return self.raw_cache_stmts[slot];
        }
        return null;
    }

    fn raw_cache_put(self: *SqliteStorage, sql: []const u8, stmt: *c.sqlite3_stmt) void {
        const slot = sql_hash(sql);
        if (self.raw_cache_stmts[slot]) |old| {
            _ = c.sqlite3_finalize(old);
        }
        self.raw_cache_keys[slot] = sql;
        self.raw_cache_stmts[slot] = stmt;
    }

    /// Bind parameters from the binary wire format to a prepared statement.
    /// Validates param count against SQL placeholder count (pair assertion).
    fn bind_raw_params(stmt: *c.sqlite3_stmt, params_buf: []const u8, params_count: u8) bool {
        // Pair: param count from wire must match SQL placeholder count.
        const sql_param_count: u8 = @intCast(c.sqlite3_bind_parameter_count(stmt));
        if (params_count != sql_param_count) {
            log.mark.warn("bind_raw_params: count mismatch: wire={d} sql={d}", .{ params_count, sql_param_count });
            return false;
        }

        var buf_pos: usize = 0;
        for (0..params_count) |i| {
            const col: c_int = @intCast(i + 1);
            if (buf_pos >= params_buf.len) return false;
            const tag_byte = params_buf[buf_pos];
            buf_pos += 1;
            const tag = std.meta.intToEnum(proto.TypeTag, tag_byte) catch return false;

            switch (tag) {
                .integer => {
                    if (buf_pos + 8 > params_buf.len) return false;
                    const val = std.mem.readInt(i64, params_buf[buf_pos..][0..8], .little);
                    buf_pos += 8;
                    bind_ok(c.sqlite3_bind_int64(stmt, col, val));
                },
                .float => {
                    if (buf_pos + 8 > params_buf.len) return false;
                    const val: f64 = @bitCast(std.mem.readInt(u64, params_buf[buf_pos..][0..8], .little));
                    buf_pos += 8;
                    bind_ok(c.sqlite3_bind_double(stmt, col, val));
                },
                .text => {
                    if (buf_pos + 2 > params_buf.len) return false;
                    const len = std.mem.readInt(u16, params_buf[buf_pos..][0..2], .big);
                    buf_pos += 2;
                    if (buf_pos + len > params_buf.len) return false;
                    const val = params_buf[buf_pos..][0..len];
                    buf_pos += len;
                    bind_ok(c.sqlite3_bind_text_transient(stmt, col, val.ptr, @intCast(len)));
                },
                .blob => {
                    if (buf_pos + 2 > params_buf.len) return false;
                    const len = std.mem.readInt(u16, params_buf[buf_pos..][0..2], .big);
                    buf_pos += 2;
                    if (buf_pos + len > params_buf.len) return false;
                    const val = params_buf[buf_pos..][0..len];
                    buf_pos += len;
                    bind_ok(c.sqlite3_bind_blob_transient(stmt, col, val.ptr, @intCast(len)));
                },
                .null => {
                    bind_ok(c.sqlite3_bind_null(stmt, col));
                },
            }
        }
        return true;
    }

    /// Map SQLite column type constant to protocol TypeTag.
    fn sqlite_type_to_tag(sqlite_type: c_int) proto.TypeTag {
        return switch (sqlite_type) {
            c.SQLITE_INTEGER => .integer,
            c.SQLITE_FLOAT => .float,
            c.SQLITE_TEXT => .text,
            c.SQLITE_BLOB => .blob,
            c.SQLITE_NULL => .null,
            else => .null,
        };
    }

    /// Read a single SQLite column value as a protocol Value.
    fn read_sqlite_value(stmt: *c.sqlite3_stmt, col: c_int, sqlite_type: c_int) proto.Value {
        return switch (sqlite_type) {
            c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(stmt, col) },
            c.SQLITE_FLOAT => .{ .float = c.sqlite3_column_double(stmt, col) },
            c.SQLITE_TEXT => blk: {
                const ptr = c.sqlite3_column_text(stmt, col);
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
                if (ptr == null) break :blk .{ .null = {} };
                break :blk .{ .text = ptr[0..len] };
            },
            c.SQLITE_BLOB => blk: {
                const ptr = c.sqlite3_column_blob(stmt, col);
                const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
                if (ptr == null) break :blk .{ .null = {} };
                const byte_ptr: [*]const u8 = @ptrCast(ptr);
                break :blk .{ .blob = byte_ptr[0..len] };
            },
            c.SQLITE_NULL => .{ .null = {} },
            else => .{ .null = {} },
        };
    }

    /// Re-export framework's BoundedList so existing callers of
    /// SqliteStorage.BoundedList continue to work during migration.
    pub const BoundedList = stdx.BoundedList;

    /// Prepare, cache, and bind a SQL statement. The SQL string is comptime —
    /// each unique string gets prepared once and cached for the lifetime of
    /// the database connection. Subsequent calls reset and rebind.
    ///
    /// Measured impact: 37,099 → 54,960 req/s (+48%) at 128 connections.
    /// sqlite3_prepare_v2 was 22% of CPU (parsing the same SQL on every
    /// request). Caching eliminates this — reset+bind is ~100x cheaper.
    fn prepare_and_bind(self: *SqliteStorage, comptime sql_str: [*:0]const u8, args: anytype) *c.sqlite3_stmt {
        const slot = comptime stmt_cache_slot(sql_str);
        const real_stmt = if (self.stmt_cache[slot]) |cached| blk: {
            // Cache hit — verify identity via sqlite3_sql(), then reset.
            // Pair assertion: prepare stores the SQL, cache hit verifies it
            // matches. Catches hash collisions — two different SQL strings
            // mapping to the same slot would fail this comparison.
            const cached_sql: [*:0]const u8 = @ptrCast(c.sqlite3_sql(cached));
            assert(std.mem.orderZ(u8, cached_sql, sql_str) == .eq);
            // Pair assertion: param count still matches (same SQL, same params).
            const sql_param_count: usize = @intCast(c.sqlite3_bind_parameter_count(cached));
            const args_count = @typeInfo(@TypeOf(args)).@"struct".fields.len;
            assert(sql_param_count == args_count);
            assert(c.sqlite3_reset(cached) == c.SQLITE_OK);
            // No sqlite3_clear_bindings — bind_params overwrites every
            // parameter (param count assertion guarantees it). Clearing
            // first would be redundant work.
            break :blk cached;
        } else blk: {
            // First call — prepare and cache.
            var stmt: ?*c.sqlite3_stmt = null;
            const rc = c.sqlite3_prepare_v2(self.db, sql_str, -1, &stmt, null);
            assert(rc == c.SQLITE_OK); // prepare failed — schema/code mismatch
            const s = stmt.?;
            // Pair assertion: SQL placeholder count must match args tuple length.
            const sql_param_count: usize = @intCast(c.sqlite3_bind_parameter_count(s));
            const args_count = @typeInfo(@TypeOf(args)).@"struct".fields.len;
            assert(sql_param_count == args_count);
            self.stmt_cache[slot] = s;
            break :blk s;
        };

        bind_params(real_stmt, args);
        return real_stmt;
    }

    /// Column-to-field mapping array. Built once per query from column
    /// names, then reused for every row. Avoids O(rows × fields) string
    /// comparisons in query_all.
    fn ColumnMapping(comptime T: type) type {
        return [max_fields(T)]usize;
    }

    fn max_fields(comptime T: type) usize {
        return @typeInfo(T).@"struct".fields.len;
    }

    /// Build the column→field name mapping on the first row of a query.
    /// Asserts column count matches field count, and every column name
    /// matches exactly one struct field name. Called once per query, not
    /// per row.
    ///
    /// Column order in the SELECT does not need to match field declaration
    /// order. Use AS aliases when the column name differs from the field
    /// name (e.g., "SELECT active AS active FROM ...").
    ///
    /// This design exists because:
    /// - Position-based mapping silently corrupts data when columns are
    ///   reordered. Name-based matching crashes immediately.
    /// - Handlers define flat row types shaped by their query (not by the
    ///   wire format). The SQL and the struct are the contract — the
    ///   framework matches them. See docs/internal/decision-storage-ownership.md.
    /// - This is sidecar-language-agnostic: every language maps query
    ///   results to structs by column name. The Zig framework does the same.
    fn build_column_mapping(comptime T: type, stmt: *c.sqlite3_stmt) ColumnMapping(T) {
        const fields = @typeInfo(T).@"struct".fields;
        const col_count: usize = @intCast(c.sqlite3_column_count(stmt));
        assert(col_count == fields.len); // SELECT column count != struct field count

        var mapping: ColumnMapping(T) = undefined;
        for (0..col_count) |col_idx| {
            const col: c_int = @intCast(col_idx);
            const sql_name_ptr: [*c]const u8 = c.sqlite3_column_name(stmt, col);
            assert(sql_name_ptr != null);
            const sql_name = sql_name_ptr[0..std.mem.len(sql_name_ptr)];

            var matched = false;
            inline for (fields, 0..) |field, field_idx| {
                if (std.mem.eql(u8, sql_name, field.name)) {
                    mapping[col_idx] = field_idx;
                    matched = true;
                }
            }
            assert(matched); // SQL column has no matching struct field
        }

        // Pigeonhole: col_count == fields.len + every column matched a
        // unique field → every field is covered. No separate check needed.
        return mapping;
    }

    /// Read a single row using a precomputed column→field mapping.
    fn read_row_mapped(comptime T: type, stmt: *c.sqlite3_stmt, mapping: ColumnMapping(T)) T {
        // Use undefined, not zeroes — enum fields may not have a zero value.
        // Every field is overwritten by the column mapping (guaranteed by
        // build_column_mapping's pigeonhole check).
        var result: T = undefined;
        const fields = @typeInfo(T).@"struct".fields;

        for (0..fields.len) |col_idx| {
            const col: c_int = @intCast(col_idx);
            const field_idx = mapping[col_idx];
            inline for (fields, 0..) |_, fi| {
                if (fi == field_idx) {
                    @field(result, fields[fi].name) = read_column(fields[fi].type, stmt, col);
                }
            }
        }

        return result;
    }

    /// Read a single column value, dispatching on Zig type.
    ///
    /// Pair assertions: each branch asserts the SQLite column type matches
    /// what bind_param would have written. bind_param writes u128 as BLOB,
    /// integers as INTEGER, text as TEXT. read_column asserts the storage
    /// type agrees — catches schema changes, wrong column order, or a
    /// bind_param/read_column type mismatch introduced by a code change.
    fn read_column(comptime T: type, stmt: *c.sqlite3_stmt, col: c_int) T {
        if (T == u128) {
            // Pair: bind_param writes u128 as 16-byte BLOB (big-endian).
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_BLOB);
            const blob_ptr = c.sqlite3_column_blob(stmt, col);
            assert(blob_ptr != null); // NULL UUID — query or schema bug
            assert(c.sqlite3_column_bytes(stmt, col) == 16);
            const blob: [*]const u8 = @ptrCast(blob_ptr);
            return std.mem.readInt(u128, blob[0..16], .big);
        } else if (T == []const u8) {
            @compileError("cannot read []const u8 — slice lifetime unclear. Use a fixed [N]u8 field.");
        } else if (T == bool) {
            // Pair: bind_param writes bool as INTEGER (0 or 1).
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_INTEGER);
            return c.sqlite3_column_int(stmt, col) != 0;
        } else if (T == i64) {
            // Pair: bind_param writes i64 as INTEGER.
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_INTEGER);
            return c.sqlite3_column_int64(stmt, col);
        } else if (@typeInfo(T) == .int) {
            // Pair: bind_param writes unsigned ints as INTEGER via int64.
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_INTEGER);
            const val = c.sqlite3_column_int64(stmt, col);
            assert(val >= 0); // bind_param sent unsigned; negative means corruption or schema mismatch
            assert(val <= std.math.maxInt(T));
            return @intCast(val);
        } else if (@typeInfo(T) == .array and @typeInfo(T).array.child == u8) {
            // Pair: bind_param writes []const u8 / string literals as TEXT.
            // SQLite returns SQLITE_NULL for empty strings in some contexts,
            // so allow both TEXT and NULL here.
            const col_type = c.sqlite3_column_type(stmt, col);
            assert(col_type == c.SQLITE_TEXT or col_type == c.SQLITE_NULL);
            const ptr_raw = c.sqlite3_column_text(stmt, col);
            const raw_len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
            const field_max = @typeInfo(T).array.len;
            var arr: T = .{0} ** field_max;
            if (ptr_raw) |ptr| {
                const p: [*]const u8 = @ptrCast(ptr);
                if (raw_len > field_max) {
                    // Data exceeds field size — database was modified directly
                    // (sqlite3 CLI, migration script) bypassing domain validation.
                    // Truncate and warn instead of crashing the server.
                    // The handler's INSERT/UPDATE path validates lengths — this
                    // path only fires for externally corrupted data.
                    log.warn("column {d}: text length {d} exceeds field max {d}, truncating", .{
                        col, raw_len, field_max,
                    });
                    @memcpy(arr[0..field_max], p[0..field_max]);
                } else {
                    @memcpy(arr[0..raw_len], p[0..raw_len]);
                }
            }
            return arr;
        } else if (@typeInfo(T) == .@"enum") {
            // Pair: bind_param writes enums as INTEGER via their tag value.
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_INTEGER);
            const val = c.sqlite3_column_int64(stmt, col);
            assert(val >= 0);
            return @enumFromInt(@as(@typeInfo(T).@"enum".tag_type, @intCast(val)));
        } else if (@typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".backing_integer != null) {
            // Pair: bind_param writes the backing integer as INTEGER.
            assert(c.sqlite3_column_type(stmt, col) == c.SQLITE_INTEGER);
            const BackingInt = @typeInfo(T).@"struct".backing_integer.?;
            const val = c.sqlite3_column_int64(stmt, col);
            assert(val >= 0);
            assert(val <= std.math.maxInt(BackingInt));
            return @bitCast(@as(BackingInt, @intCast(val)));
        } else {
            @compileError("unsupported column type: " ++ @typeName(T));
        }
    }

    /// Bind a tuple of parameters to a prepared statement.
    fn bind_params(stmt: *c.sqlite3_stmt, args: anytype) void {
        const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
        inline for (fields, 0..) |field, i| {
            const col: c_int = @intCast(i + 1); // SQLite params are 1-indexed
            const val = @field(args, field.name);
            bind_param(stmt, col, val);
        }
    }

    fn bind_param(stmt: *c.sqlite3_stmt, col: c_int, val: anytype) void {
        const T = @TypeOf(val);

        // Coerce aligned slices to []const u8 — extern struct fields
        // produce slices like []align(16) const u8 which don't match
        // []const u8. The alignment is irrelevant for SQLite binding.
        if (comptime is_byte_slice(T)) {
            const slice: []const u8 = val;
            const rc = c.sqlite3_bind_text_transient(stmt, col, slice.ptr, @intCast(slice.len));
            assert(rc == c.SQLITE_OK);
            return;
        }

        // Note: []const u8 (unaligned) is handled by is_byte_slice above.
        // Only u128, string literals, and integer/bool types reach here.
        const rc = rc: {
            if (T == u128) {
                var buf: [16]u8 = undefined;
                std.mem.writeInt(u128, &buf, val, .big);
                break :rc c.sqlite3_bind_blob_transient(stmt, col, &buf, 16);
            } else if (comptime is_string_literal(T)) {
                const slice: []const u8 = val;
                break :rc c.sqlite3_bind_text_transient(stmt, col, slice.ptr, @intCast(slice.len));
            } else if (T == bool) {
                break :rc c.sqlite3_bind_int(stmt, col, if (val) @as(c_int, 1) else @as(c_int, 0));
            } else if (T == i64) {
                break :rc c.sqlite3_bind_int64(stmt, col, val);
            } else if (@typeInfo(T) == .comptime_int) {
                break :rc c.sqlite3_bind_int64(stmt, col, @intCast(val));
            } else if (@typeInfo(T) == .int) {
                assert(@bitSizeOf(T) <= 64);
                break :rc c.sqlite3_bind_int64(stmt, col, @intCast(val));
            } else {
                @compileError("unsupported parameter type: " ++ @typeName(T));
            }
        };
        assert(rc == c.SQLITE_OK); // bind failed — type mismatch or invalid column index
    }

    fn is_string_literal(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .pointer) return false;
        const child = info.pointer.child;
        const child_info = @typeInfo(child);
        if (child_info != .array) return false;
        return child_info.array.child == u8;
    }

    /// Matches any slice of u8 regardless of alignment or constness.
    /// Extern struct fields produce []align(N) const u8 when sliced —
    /// these are semantically []const u8 for binding purposes.
    fn is_byte_slice(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .pointer) return false;
        if (info.pointer.size != .slice) return false;
        return info.pointer.child == u8;
    }

    // Type universe note: read_column's @compileError catch-all already
    // guarantees that any unsupported field type in a query(T, ...) result
    // struct fails at the call site. No separate comptime type list needed.

    // --- Internal helpers ---

    const StepResult = enum { row, done, busy, err, corruption };

    fn step_result(stmt: *c.sqlite3_stmt) StepResult {
        const rc = c.sqlite3_step(stmt);
        return switch (rc) {
            c.SQLITE_ROW => .row,
            c.SQLITE_DONE => .done,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => .busy,
            c.SQLITE_CORRUPT, c.SQLITE_NOTADB => .corruption,
            c.SQLITE_CONSTRAINT => .err,
            c.SQLITE_FULL, c.SQLITE_IOERR => .err,
            else => .err,
        };
    }


    fn bind_ok(rc: c_int) void {
        assert(rc == c.SQLITE_OK);
    }

    fn prepare(db: *c.sqlite3, stmt_sql: [*:0]const u8) *c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, stmt_sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            @panic("sqlite3_prepare_v2 failed");
        }
        return stmt.?;
    }

    fn exec(db: *c.sqlite3, stmt_sql: [*:0]const u8) void {
        const rc = c.sqlite3_exec(db, stmt_sql, null, null, null);
        if (rc != c.SQLITE_OK) {
            @panic("sqlite3_exec failed");
        }
    }

    // =================================================================
    // Schema versioning
    // =================================================================

    /// Set to a migration function when the next deploy needs a schema change.
    /// After deploying, clear it back to null and update storage/schema.sql from prod.
    /// Additive only — no drops, no renames, no type changes.
    /// See docs/internal/decision-database.md.
    const next_migration: ?*const fn (*c.sqlite3) void = migrate_v3_collection_active;

    fn ensure_schema(db: *c.sqlite3) void {
        if (get_schema_version(db) == 0) {
            exec(db, @embedFile("storage/schema.sql"));
            set_schema_version(db, 3);
        }
        if (next_migration) |migrate| {
            migrate(db);
        }
    }

    fn migrate_v3_collection_active(db: *c.sqlite3) void {
        if (get_schema_version(db) >= 3) return;
        exec(db, "ALTER TABLE collections ADD COLUMN active INTEGER NOT NULL DEFAULT 1;");
        exec(db, "ALTER TABLE collection_members ADD COLUMN removed INTEGER NOT NULL DEFAULT 0;");
        set_schema_version(db, 3);
    }

    fn get_schema_version(db: *c.sqlite3) u32 {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, null);
        if (rc != c.SQLITE_OK) @panic("PRAGMA user_version failed");
        defer _ = c.sqlite3_finalize(stmt.?);
        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) @panic("PRAGMA user_version returned no row");
        return @intCast(c.sqlite3_column_int(stmt.?, 0));
    }

    fn set_schema_version(db: *c.sqlite3, version: u32) void {
        var buf: [64]u8 = undefined;
        const pragma = std.fmt.bufPrint(&buf, "PRAGMA user_version = {d};\x00", .{version}) catch unreachable;
        exec(db, @ptrCast(pragma.ptr));
    }

    fn migrate_v2_login(db: *c.sqlite3) void {
        if (get_schema_version(db) >= 2) return;
        exec(db,
            "CREATE TABLE IF NOT EXISTS login_codes (" ++
            "  email TEXT NOT NULL PRIMARY KEY," ++
            "  code TEXT NOT NULL," ++
            "  expires_at INTEGER NOT NULL" ++
            ");",
        );
        exec(db,
            "CREATE TABLE IF NOT EXISTS users (" ++
            "  user_id BLOB(16) PRIMARY KEY," ++
            "  email TEXT NOT NULL UNIQUE" ++
            ");",
        );
        set_schema_version(db, 2);
    }
};

// =====================================================================
// Tests
// =====================================================================

fn make_test_product(id: u128, name: []const u8, price: u32) message.Product {
    var p = std.mem.zeroes(message.Product);
    p.id = id;
    p.name_len = @intCast(name.len);
    p.price_cents = price;
    p.version = 1;
    p.flags = .{ .active = true };
    @memcpy(p.name[0..name.len], name);
    return p;
}


const ProductRow = struct {
    id: u128,
    name: [128]u8,
    price_cents: u32,
    inventory: u32,
    version: u32,
    active: bool,
};

test "query: round-trip insert and select" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    const id: u128 = 0xaabbccdd11223344aabbccdd11223344;
    try std.testing.expect(s.execute(
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
        .{ id, @as([]const u8, "Test Widget"), @as([]const u8, ""), @as(u32, 999), @as(u32, 42), @as(u32, 1), true },
    ));

    const row = s.query(ProductRow,
        "SELECT id, name, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{id},
    ) orelse unreachable;

    try std.testing.expectEqual(id, row.id);
    try std.testing.expect(std.mem.startsWith(u8, &row.name, "Test Widget"));
    try std.testing.expectEqual(@as(u32, 999), row.price_cents);
    try std.testing.expectEqual(@as(u32, 42), row.inventory);
    try std.testing.expectEqual(@as(u32, 1), row.version);
    try std.testing.expect(row.active);
}

test "query: not found returns null" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    const row = s.query(ProductRow,
        "SELECT id, name, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        .{@as(u128, 0xdead)},
    );
    try std.testing.expect(row == null);
}

test "query_all: multiple rows" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);", .{ @as(u128, 1), @as([]const u8, "A"), @as([]const u8, ""), @as(u32, 100), @as(u32, 0), @as(u32, 1), true }));
    try std.testing.expect(s.execute("INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);", .{ @as(u128, 2), @as([]const u8, "B"), @as([]const u8, ""), @as(u32, 200), @as(u32, 0), @as(u32, 1), true }));
    try std.testing.expect(s.execute("INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);", .{ @as(u128, 3), @as([]const u8, "C"), @as([]const u8, ""), @as(u32, 300), @as(u32, 0), @as(u32, 1), true }));

    const PriceRow = struct { price_cents: u32 };
    const result = s.query_all(PriceRow, 10,
        "SELECT price_cents FROM products ORDER BY price_cents LIMIT 10;",
        .{},
    ) orelse unreachable;

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u32, 100), result.items[0].price_cents);
    try std.testing.expectEqual(@as(u32, 200), result.items[1].price_cents);
    try std.testing.expectEqual(@as(u32, 300), result.items[2].price_cents);
}

test "query_all: empty result" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    const PriceRow = struct { price_cents: u32 };
    const result = s.query_all(PriceRow, 10,
        "SELECT price_cents FROM products LIMIT 10;",
        .{},
    ) orelse unreachable;

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

// Note: invalid SQL now asserts (crashes) rather than returning false.
// Prepare failure means the schema and code disagree — that's a programming
// error, not a runtime condition. No test for it; the assert IS the test.

// --- Typed interface boundary tests ---
//
// These test the bind_param → SQLite → read_column translation for every
// supported type. The point is NOT to test SQLite — it's to verify that
// our type mapping round-trips correctly at the boundary.

test "typed: u128 round-trip edge values" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (id BLOB(16) NOT NULL);", .{}));

    const IdRow = struct { id: u128 };
    const edges = [_]u128{ 0, 1, std.math.maxInt(u128), 0x80000000000000000000000000000000, 0xaabbccdd11223344aabbccdd11223344 };
    for (edges) |id| {
        try std.testing.expect(s.execute("DELETE FROM t;", .{}));
        try std.testing.expect(s.execute("INSERT INTO t (id) VALUES (?1);", .{id}));
        const row = s.query(IdRow, "SELECT id FROM t;", .{}) orelse unreachable;
        try std.testing.expectEqual(id, row.id);
    }
}

test "typed: bool round-trip" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (flag INTEGER NOT NULL);", .{}));
    const FlagRow = struct { flag: bool };

    try std.testing.expect(s.execute("INSERT INTO t (flag) VALUES (?1);", .{true}));
    try std.testing.expect(s.execute("INSERT INTO t (flag) VALUES (?1);", .{false}));

    const rows = s.query_all(FlagRow, 10, "SELECT flag FROM t ORDER BY rowid LIMIT 10;", .{}) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(rows.items[0].flag == true);
    try std.testing.expect(rows.items[1].flag == false);
}

test "typed: packed struct round-trip" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (flags INTEGER NOT NULL);", .{}));
    const Flags = packed struct(u8) { active: bool, featured: bool, padding: u6 = 0 };
    const FlagsRow = struct { flags: Flags };

    const vals = [_]Flags{
        .{ .active = true, .featured = false },
        .{ .active = false, .featured = true },
        .{ .active = true, .featured = true },
        .{ .active = false, .featured = false },
    };
    for (vals) |f| {
        try std.testing.expect(s.execute("DELETE FROM t;", .{}));
        const backing: u8 = @bitCast(f);
        try std.testing.expect(s.execute("INSERT INTO t (flags) VALUES (?1);", .{backing}));
        const row = s.query(FlagsRow, "SELECT flags FROM t;", .{}) orelse unreachable;
        try std.testing.expectEqual(f, row.flags);
    }
}

test "typed: text field max length" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (name TEXT NOT NULL);", .{}));
    const NameRow = struct { name: [64]u8 };

    // Fill to exact capacity.
    var full_name: [64]u8 = undefined;
    for (&full_name, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
    const full_slice: []const u8 = &full_name;

    try std.testing.expect(s.execute("INSERT INTO t (name) VALUES (?1);", .{full_slice}));
    const row = s.query(NameRow, "SELECT name FROM t;", .{}) orelse unreachable;
    try std.testing.expectEqualSlices(u8, &full_name, &row.name);
}

test "typed: text field empty string" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (name TEXT NOT NULL);", .{}));
    const NameRow = struct { name: [64]u8 };

    try std.testing.expect(s.execute("INSERT INTO t (name) VALUES (?1);", .{@as([]const u8, "")}));
    const row = s.query(NameRow, "SELECT name FROM t;", .{}) orelse unreachable;
    // All bytes should be zero — empty text copied into zeroed array.
    const zeros: [64]u8 = .{0} ** 64;
    try std.testing.expectEqualSlices(u8, &zeros, &row.name);
}

test "typed: i64 round-trip" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t (val INTEGER NOT NULL);", .{}));
    const ValRow = struct { val: i64 };

    const edges = [_]i64{ 0, 1, -1, std.math.maxInt(i64), std.math.minInt(i64) };
    for (edges) |v| {
        try std.testing.expect(s.execute("DELETE FROM t;", .{}));
        try std.testing.expect(s.execute("INSERT INTO t (val) VALUES (?1);", .{v}));
        const row = s.query(ValRow, "SELECT val FROM t;", .{}) orelse unreachable;
        try std.testing.expectEqual(v, row.val);
    }
}

// --- Seeded round-trip fuzzer ---
//
// Generates random structs, inserts via execute(), reads back via query(),
// asserts field equality. Tests the bind_param ↔ read_column translation
// boundary with random data. Not testing SQLite — testing our type mapping.

const PRNG = @import("stdx").PRNG;

test "seeded: typed interface round-trip" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute(
        "CREATE TABLE fuzz_t (" ++
            "id BLOB(16) NOT NULL," ++
            "name TEXT NOT NULL," ++
            "price_cents INTEGER NOT NULL," ++
            "inventory INTEGER NOT NULL," ++
            "version INTEGER NOT NULL," ++
            "active INTEGER NOT NULL," ++
            "score INTEGER NOT NULL" ++
            ");",
        .{},
    ));

    const FuzzRow = struct {
        id: u128,
        name: [32]u8,
        price_cents: u32,
        inventory: u32,
        version: u32,
        active: bool,
        score: i64,
    };

    var prng = PRNG.from_seed(42);
    const iterations = 500;

    for (0..iterations) |_| {
        try std.testing.expect(s.execute("DELETE FROM fuzz_t;", .{}));

        // Generate random field values.
        const id = prng.int(u128) | 1;
        var name: [32]u8 = .{0} ** 32;
        const name_len = prng.range_inclusive(u8, 0, 32);
        for (name[0..name_len]) |*byte| byte.* = 'a' + @as(u8, @intCast(prng.int(u8) % 26));
        const name_slice: []const u8 = name[0..name_len];
        const price_cents = prng.int(u32);
        const inventory = prng.int(u32);
        const version = prng.int(u32);
        const active = prng.boolean();
        const score: i64 = @bitCast(prng.int(u64));

        try std.testing.expect(s.execute(
            "INSERT INTO fuzz_t (id, name, price_cents, inventory, version, active, score) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
            .{ id, name_slice, price_cents, inventory, version, active, score },
        ));

        const row = s.query(FuzzRow,
            "SELECT id, name, price_cents, inventory, version, active, score FROM fuzz_t WHERE id = ?1;",
            .{id},
        ) orelse {
            std.debug.panic("seeded round-trip: query returned null for id={}", .{id});
        };

        try std.testing.expectEqual(id, row.id);
        try std.testing.expectEqualSlices(u8, name_slice, row.name[0..name_len]);
        // Trailing bytes must be zero (zeroed struct + memcpy of name_len).
        for (row.name[name_len..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
        try std.testing.expectEqual(price_cents, row.price_cents);
        try std.testing.expectEqual(inventory, row.inventory);
        try std.testing.expectEqual(version, row.version);
        try std.testing.expectEqual(active, row.active);
        try std.testing.expectEqual(score, row.score);
    }
}

test "query_raw: single row round trip" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute(
        "CREATE TABLE raw_t (id INTEGER, name TEXT, price INTEGER);",
        .{},
    ));
    try std.testing.expect(s.execute(
        "INSERT INTO raw_t VALUES (?1, ?2, ?3);",
        .{ @as(i64, 42), "Widget", @as(i64, 999) },
    ));

    var out_buf: [4096]u8 = undefined;
    const result = s.query_raw(
        "SELECT id, name, price FROM raw_t WHERE id = ?1;",
        // Binary params: 1 param, type integer(0x01), value 42 as i64 LE.
        &[_]u8{ 0x01, 42, 0, 0, 0, 0, 0, 0, 0 },
        1,
        .query,
        &out_buf,
    );
    try std.testing.expect(result != null);

    const buf = result.?;

    // Parse header.
    const hdr = proto.read_row_set_header(buf, 0) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), hdr.count);
    try std.testing.expectEqualStrings("id", hdr.columns[0].name);
    try std.testing.expectEqualStrings("name", hdr.columns[1].name);
    try std.testing.expectEqualStrings("price", hdr.columns[2].name);

    // Parse row count.
    const rc = proto.read_row_count(buf, hdr.pos) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 1), rc.count);

    // Parse row values.
    var pos = rc.pos;
    const id_val = proto.read_value(buf, pos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 42), id_val.value.integer);
    pos = id_val.pos;

    const name_val = proto.read_value(buf, pos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("Widget", name_val.value.text);
    pos = name_val.pos;

    const price_val = proto.read_value(buf, pos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 999), price_val.value.integer);
}

test "query_raw: empty result returns 0 rows" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute(
        "CREATE TABLE raw_empty (id INTEGER);",
        .{},
    ));

    var out_buf: [4096]u8 = undefined;
    const result = s.query_raw(
        "SELECT id FROM raw_empty;",
        &[_]u8{},
        0,
        .query_all,
        &out_buf,
    );
    try std.testing.expect(result != null);

    const buf = result.?;
    const hdr = proto.read_row_set_header(buf, 0) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 1), hdr.count);
    const rc = proto.read_row_count(buf, hdr.pos) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 0), rc.count);
}

test "query_raw: bad SQL returns null" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    const mark = marks.check("prepare_raw: failed");
    var out_buf: [4096]u8 = undefined;
    const result = s.query_raw("NOT VALID SQL;", &[_]u8{}, 0, .query, &out_buf);
    try std.testing.expect(result == null);
    try mark.expect_hit();
}

test "query_raw: multiple rows (mode all)" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE raw_multi (id INTEGER, val TEXT);", .{}));
    try std.testing.expect(s.execute("INSERT INTO raw_multi VALUES (?1, ?2);", .{ @as(i64, 1), "alpha" }));
    try std.testing.expect(s.execute("INSERT INTO raw_multi VALUES (?1, ?2);", .{ @as(i64, 2), "beta" }));
    try std.testing.expect(s.execute("INSERT INTO raw_multi VALUES (?1, ?2);", .{ @as(i64, 3), "gamma" }));

    var out_buf: [4096]u8 = undefined;
    const result = s.query_raw("SELECT id, val FROM raw_multi ORDER BY id;", &[_]u8{}, 0, .query_all, &out_buf);
    try std.testing.expect(result != null);

    const buf = result.?;
    const hdr = proto.read_row_set_header(buf, 0) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 2), hdr.count);

    const rc = proto.read_row_count(buf, hdr.pos) orelse unreachable;
    try std.testing.expectEqual(@as(u32, 3), rc.count);

    // Row 1: id=1, val="alpha"
    var pos = rc.pos;
    const r1c1 = proto.read_value(buf, pos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 1), r1c1.value.integer);
    pos = r1c1.pos;
    const r1c2 = proto.read_value(buf, pos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("alpha", r1c2.value.text);
    pos = r1c2.pos;

    // Row 2: id=2, val="beta"
    const r2c1 = proto.read_value(buf, pos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 2), r2c1.value.integer);
    pos = r2c1.pos;
    const r2c2 = proto.read_value(buf, pos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("beta", r2c2.value.text);
    pos = r2c2.pos;

    // Row 3: id=3, val="gamma"
    const r3c1 = proto.read_value(buf, pos, .integer) orelse unreachable;
    try std.testing.expectEqual(@as(i64, 3), r3c1.value.integer);
    pos = r3c1.pos;
    const r3c2 = proto.read_value(buf, pos, .text) orelse unreachable;
    try std.testing.expectEqualStrings("gamma", r3c2.value.text);
}

test "query_raw: rejects write statement" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE raw_ro (id INTEGER);", .{}));

    const mark = marks.check("query_raw: statement is not read-only");
    var out_buf: [4096]u8 = undefined;
    const result = s.query_raw("INSERT INTO raw_ro VALUES (1);", &[_]u8{}, 0, .query, &out_buf);
    try std.testing.expect(result == null);
    try mark.expect_hit();
}

test "execute_raw: rejects read statement" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE raw_wo (id INTEGER);", .{}));

    const mark = marks.check("execute_raw: statement is read-only");
    const result = s.execute_raw("SELECT id FROM raw_wo;", &[_]u8{}, 0);
    try std.testing.expect(!result);
    try mark.expect_hit();
}

test "execute_raw: insert and verify" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute(
        "CREATE TABLE raw_w (id INTEGER, name TEXT);",
        .{},
    ));

    // Binary params: 2 params
    // Param 1: integer(0x01), value 7
    // Param 2: text(0x03), len=5, "Hello"
    const params = [_]u8{
        0x01, 7, 0, 0, 0, 0, 0, 0, 0, // integer 7
        0x03, 0, 5, 'H', 'e', 'l', 'l', 'o', // text "Hello"
    };
    try std.testing.expect(s.execute_raw(
        "INSERT INTO raw_w VALUES (?1, ?2);",
        &params,
        2,
    ));

    // Verify via typed query.
    const Row = struct { id: i64, name: [32]u8 };
    const row = s.query(Row, "SELECT id, name FROM raw_w;", .{});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 7), row.?.id);
    try std.testing.expectEqualStrings("Hello", std.mem.sliceTo(&row.?.name, 0));
}

test "query_raw: cache distinguishes different SQL at same buffer address" {
    // Regression: the 2-RT dispatch reuses SHM entry buffers. Two different
    // SQL strings at the same memory address must not return a stale cached
    // prepared statement. Before the fix, pointer-identity caching returned
    // the wrong statement, causing param count mismatches or wrong results.
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE t1 (id TEXT, name TEXT);", .{}));
    try std.testing.expect(s.execute("INSERT INTO t1 VALUES ('a', 'Alice');", .{}));

    // Two different SQL strings that we'll write to the SAME buffer.
    const sql_a = "SELECT id, name FROM t1 WHERE id = ?1";
    const sql_b = "SELECT id FROM t1 WHERE name = ?1";

    var buf: [128]u8 = undefined;

    // First query: SELECT id, name WHERE id = ?1
    @memcpy(buf[0..sql_a.len], sql_a);
    const sql_slice_a = buf[0..sql_a.len];
    const param_a = [_]u8{ 0x03, 0, 1, 'a' }; // text "a"
    var out_a: [4096]u8 = undefined;
    const result_a = s.query_raw(sql_slice_a, &param_a, 1, .query, &out_a);
    try std.testing.expect(result_a != null);

    // Second query: DIFFERENT SQL at the SAME buffer address.
    @memcpy(buf[0..sql_b.len], sql_b);
    const sql_slice_b = buf[0..sql_b.len];
    const param_b = [_]u8{ 0x03, 0, 5, 'A', 'l', 'i', 'c', 'e' }; // text "Alice"
    var out_b: [4096]u8 = undefined;
    const result_b = s.query_raw(sql_slice_b, &param_b, 1, .query, &out_b);
    // Must succeed — before the fix, the cache returned sql_a's statement
    // for sql_b, causing a wrong query or param mismatch.
    try std.testing.expect(result_b != null);
}

test "WriteView recording captures SQL and params" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE rec_t (id INTEGER, name TEXT);", .{}));

    var record_buf: [4096]u8 = undefined;
    var wv = SqliteStorage.WriteView.init_recording(&s, &record_buf);

    s.begin();
    wv.execute("INSERT INTO rec_t VALUES (?1, ?2);", .{ @as(i64, 99), "TestName" });
    s.commit();

    // Verify recording captured the write.
    try std.testing.expectEqual(@as(u8, 1), wv.record_count);
    try std.testing.expect(wv.record_pos > 0);

    // Parse the recorded data — same format as sidecar protocol.
    const data = record_buf[0..wv.record_pos];
    var pos: usize = 0;

    // sql: [u16 BE sql_len][sql_bytes]
    const sql_len = std.mem.readInt(u16, data[pos..][0..2], .big);
    pos += 2;
    const sql = data[pos..][0..sql_len];
    pos += sql_len;
    try std.testing.expectEqualStrings("INSERT INTO rec_t VALUES (?1, ?2);", sql);

    // params: [u8 param_count][params...]
    const param_count = data[pos];
    pos += 1;
    try std.testing.expectEqual(@as(u8, 2), param_count);

    // Param 1: integer 99
    try std.testing.expectEqual(@as(u8, 0x01), data[pos]); // integer tag
    pos += 1;
    const val = std.mem.readInt(i64, data[pos..][0..8], .little);
    try std.testing.expectEqual(@as(i64, 99), val);
    pos += 8;

    // Param 2: text "TestName"
    try std.testing.expectEqual(@as(u8, 0x03), data[pos]); // text tag
    pos += 1;
    const text_len = std.mem.readInt(u16, data[pos..][0..2], .big);
    pos += 2;
    try std.testing.expectEqualStrings("TestName", data[pos..][0..text_len]);
    pos += text_len;

    // Consumed all recorded bytes.
    try std.testing.expectEqual(wv.record_pos, pos);

    // Verify the write actually executed.
    const Row = struct { id: i64, name: [32]u8 };
    const row = s.query(Row, "SELECT id, name FROM rec_t;", .{});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 99), row.?.id);
    try std.testing.expectEqualStrings("TestName", std.mem.sliceTo(&row.?.name, 0));
}

test "WriteView recording multiple writes" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE rec2_t (id INTEGER);", .{}));

    var record_buf: [4096]u8 = undefined;
    var wv = SqliteStorage.WriteView.init_recording(&s, &record_buf);

    s.begin();
    wv.execute("INSERT INTO rec2_t VALUES (?1);", .{@as(i64, 1)});
    wv.execute("INSERT INTO rec2_t VALUES (?1);", .{@as(i64, 2)});
    wv.execute("INSERT INTO rec2_t VALUES (?1);", .{@as(i64, 3)});
    s.commit();

    try std.testing.expectEqual(@as(u8, 3), wv.record_count);
    try std.testing.expect(wv.record_pos > 0);
}

test "WriteView without recording works normally" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    try std.testing.expect(s.execute("CREATE TABLE norec_t (id INTEGER);", .{}));

    var wv = SqliteStorage.WriteView.init(&s);

    s.begin();
    wv.execute("INSERT INTO norec_t VALUES (?1);", .{@as(i64, 42)});
    s.commit();

    // No recording — record_buf is null, record_count is 0.
    try std.testing.expectEqual(@as(u8, 0), wv.record_count);
    try std.testing.expectEqual(@as(usize, 0), wv.record_pos);

    // Write still executed.
    const Row = struct { id: i64 };
    const row = s.query(Row, "SELECT id FROM norec_t;", .{});
    try std.testing.expect(row != null);
    try std.testing.expectEqual(@as(i64, 42), row.?.id);
}
