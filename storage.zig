const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const StorageResult = state_machine.StorageResult;
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.storage));

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// SQLite-backed persistent storage. Uses prepared statements for all
/// operations. WAL mode for concurrent reads. IDs stored as 16-byte BLOBs.
pub const SqliteStorage = struct {
    db: *c.sqlite3,
    stmt_get: *c.sqlite3_stmt,
    stmt_put: *c.sqlite3_stmt,
    stmt_update: *c.sqlite3_stmt,
    stmt_delete: *c.sqlite3_stmt,
    stmt_list: *c.sqlite3_stmt,
    stmt_get_collection: *c.sqlite3_stmt,
    stmt_put_collection: *c.sqlite3_stmt,
    stmt_delete_collection: *c.sqlite3_stmt,
    stmt_list_collections: *c.sqlite3_stmt,
    stmt_add_member: *c.sqlite3_stmt,
    stmt_remove_member: *c.sqlite3_stmt,
    stmt_delete_memberships: *c.sqlite3_stmt,
    stmt_list_members: *c.sqlite3_stmt,

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
        // Busy timeout: 1 second.
        _ = c.sqlite3_busy_timeout(real_db, 1000);

        // Create tables.
        exec(real_db, "CREATE TABLE IF NOT EXISTS products (" ++
            "id BLOB(16) PRIMARY KEY," ++
            "name TEXT NOT NULL," ++
            "description TEXT NOT NULL DEFAULT ''," ++
            "price_cents INTEGER NOT NULL DEFAULT 0," ++
            "inventory INTEGER NOT NULL DEFAULT 0," ++
            "active INTEGER NOT NULL DEFAULT 1" ++
            ");");

        exec(real_db, "CREATE TABLE IF NOT EXISTS collections (" ++
            "id BLOB(16) PRIMARY KEY," ++
            "name TEXT NOT NULL" ++
            ");");

        exec(real_db, "CREATE TABLE IF NOT EXISTS collection_members (" ++
            "collection_id BLOB(16) NOT NULL," ++
            "product_id BLOB(16) NOT NULL," ++
            "PRIMARY KEY (collection_id, product_id)" ++
            ");");

        // Prepare product statements.
        const stmt_get = prepare(real_db,
            "SELECT id, name, description, price_cents, inventory, active FROM products WHERE id = ?1;",
        );
        const stmt_put = prepare(real_db,
            "INSERT INTO products (id, name, description, price_cents, inventory, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
        );
        const stmt_update = prepare(real_db,
            "UPDATE products SET name = ?2, description = ?3, price_cents = ?4, inventory = ?5, active = ?6 WHERE id = ?1;",
        );
        const stmt_delete = prepare(real_db,
            "DELETE FROM products WHERE id = ?1;",
        );
        const stmt_list = prepare(real_db,
            "SELECT id, name, description, price_cents, inventory, active FROM products LIMIT ?1;",
        );

        // Prepare collection statements.
        const stmt_get_collection = prepare(real_db,
            "SELECT id, name FROM collections WHERE id = ?1;",
        );
        const stmt_put_collection = prepare(real_db,
            "INSERT INTO collections (id, name) VALUES (?1, ?2);",
        );
        const stmt_delete_collection = prepare(real_db,
            "DELETE FROM collections WHERE id = ?1;",
        );
        const stmt_list_collections = prepare(real_db,
            "SELECT id, name FROM collections LIMIT ?1;",
        );
        const stmt_add_member = prepare(real_db,
            "INSERT OR IGNORE INTO collection_members (collection_id, product_id) VALUES (?1, ?2);",
        );
        const stmt_remove_member = prepare(real_db,
            "DELETE FROM collection_members WHERE collection_id = ?1 AND product_id = ?2;",
        );
        const stmt_delete_memberships = prepare(real_db,
            "DELETE FROM collection_members WHERE collection_id = ?1;",
        );
        const stmt_list_members = prepare(real_db,
            "SELECT p.id, p.name, p.description, p.price_cents, p.inventory, p.active " ++
            "FROM collection_members cm JOIN products p ON cm.product_id = p.id WHERE cm.collection_id = ?1 LIMIT ?2;",
        );

        log.info("storage initialized: {s}", .{path});

        return .{
            .db = real_db,
            .stmt_get = stmt_get,
            .stmt_put = stmt_put,
            .stmt_update = stmt_update,
            .stmt_delete = stmt_delete,
            .stmt_list = stmt_list,
            .stmt_get_collection = stmt_get_collection,
            .stmt_put_collection = stmt_put_collection,
            .stmt_delete_collection = stmt_delete_collection,
            .stmt_list_collections = stmt_list_collections,
            .stmt_add_member = stmt_add_member,
            .stmt_remove_member = stmt_remove_member,
            .stmt_delete_memberships = stmt_delete_memberships,
            .stmt_list_members = stmt_list_members,
        };
    }

    pub fn deinit(self: *SqliteStorage) void {
        _ = c.sqlite3_finalize(self.stmt_get);
        _ = c.sqlite3_finalize(self.stmt_put);
        _ = c.sqlite3_finalize(self.stmt_update);
        _ = c.sqlite3_finalize(self.stmt_delete);
        _ = c.sqlite3_finalize(self.stmt_list);
        _ = c.sqlite3_finalize(self.stmt_get_collection);
        _ = c.sqlite3_finalize(self.stmt_put_collection);
        _ = c.sqlite3_finalize(self.stmt_delete_collection);
        _ = c.sqlite3_finalize(self.stmt_list_collections);
        _ = c.sqlite3_finalize(self.stmt_add_member);
        _ = c.sqlite3_finalize(self.stmt_remove_member);
        _ = c.sqlite3_finalize(self.stmt_delete_memberships);
        _ = c.sqlite3_finalize(self.stmt_list_members);
        _ = c.sqlite3_close(self.db);
    }

    pub fn get(self: *SqliteStorage, id: u128, out: *message.Product) StorageResult {
        const stmt = self.stmt_get;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, id);
        return switch (step_result(stmt)) {
            .row => {
                read_product(stmt, out);
                return .ok;
            },
            .done => .not_found,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn put(self: *SqliteStorage, product: *const message.Product) StorageResult {
        const stmt = self.stmt_put;
        defer reset_stmt(stmt);

        bind_product(stmt, product);
        return switch (step_result(stmt)) {
            .done => .ok,
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn update(self: *SqliteStorage, _: u128, product: *const message.Product) StorageResult {
        const stmt = self.stmt_update;
        defer reset_stmt(stmt);

        bind_product(stmt, product);
        return switch (step_result(stmt)) {
            .done => {
                if (c.sqlite3_changes(self.db) == 0) return .not_found;
                return .ok;
            },
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn delete(self: *SqliteStorage, id: u128) StorageResult {
        const stmt = self.stmt_delete;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, id);
        return switch (step_result(stmt)) {
            .done => {
                if (c.sqlite3_changes(self.db) == 0) return .not_found;
                return .ok;
            },
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn list(self: *SqliteStorage, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        const stmt = self.stmt_list;
        defer reset_stmt(stmt);

        _ = c.sqlite3_bind_int(stmt, 1, message.list_max);
        out_len.* = 0;

        while (true) {
            switch (step_result(stmt)) {
                .row => {
                    assert(out_len.* < message.list_max);
                    read_product(stmt, &out[out_len.*]);
                    out_len.* += 1;
                },
                .done => return .ok,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
    }

    // --- Collection operations ---

    pub fn get_collection(self: *SqliteStorage, id: u128, out: *message.ProductCollection) StorageResult {
        const stmt = self.stmt_get_collection;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, id);
        return switch (step_result(stmt)) {
            .row => {
                read_collection(stmt, out);
                return .ok;
            },
            .done => .not_found,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn put_collection(self: *SqliteStorage, col: *const message.ProductCollection) StorageResult {
        const stmt = self.stmt_put_collection;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, col.id);
        _ = c.sqlite3_bind_text(stmt, 2, col.name[0..col.name_len].ptr, @intCast(col.name_len), c.SQLITE_TRANSIENT);
        return switch (step_result(stmt)) {
            .done => .ok,
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn delete_collection(self: *SqliteStorage, id: u128) StorageResult {
        // Delete memberships first.
        {
            const stmt = self.stmt_delete_memberships;
            defer reset_stmt(stmt);
            bind_uuid(stmt, 1, id);
            _ = c.sqlite3_step(stmt);
        }

        const stmt = self.stmt_delete_collection;
        defer reset_stmt(stmt);
        bind_uuid(stmt, 1, id);
        return switch (step_result(stmt)) {
            .done => {
                if (c.sqlite3_changes(self.db) == 0) return .not_found;
                return .ok;
            },
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn list_collections(self: *SqliteStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32) StorageResult {
        const stmt = self.stmt_list_collections;
        defer reset_stmt(stmt);

        _ = c.sqlite3_bind_int(stmt, 1, message.list_max);
        out_len.* = 0;

        while (true) {
            switch (step_result(stmt)) {
                .row => {
                    assert(out_len.* < message.list_max);
                    read_collection(stmt, &out[out_len.*]);
                    out_len.* += 1;
                },
                .done => return .ok,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
    }

    pub fn add_to_collection(self: *SqliteStorage, collection_id: u128, product_id: u128) StorageResult {
        const stmt = self.stmt_add_member;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, collection_id);
        bind_uuid(stmt, 2, product_id);
        return switch (step_result(stmt)) {
            .done => .ok,
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn remove_from_collection(self: *SqliteStorage, collection_id: u128, product_id: u128) StorageResult {
        const stmt = self.stmt_remove_member;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, collection_id);
        bind_uuid(stmt, 2, product_id);
        return switch (step_result(stmt)) {
            .done => {
                if (c.sqlite3_changes(self.db) == 0) return .not_found;
                return .ok;
            },
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn list_products_in_collection(self: *SqliteStorage, collection_id: u128, out: *[message.list_max]message.Product, out_len: *u32) StorageResult {
        const stmt = self.stmt_list_members;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, collection_id);
        _ = c.sqlite3_bind_int(stmt, 2, message.list_max);
        out_len.* = 0;

        while (true) {
            switch (step_result(stmt)) {
                .row => {
                    assert(out_len.* < message.list_max);
                    read_product(stmt, &out[out_len.*]);
                    out_len.* += 1;
                },
                .done => return .ok,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
    }

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

    fn reset_stmt(stmt: *c.sqlite3_stmt) void {
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
    }

    fn bind_uuid(stmt: *c.sqlite3_stmt, col: c_int, id: u128) void {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u128, &buf, id, .big);
        _ = c.sqlite3_bind_blob(stmt, col, &buf, 16, c.SQLITE_TRANSIENT);
    }

    fn bind_product(stmt: *c.sqlite3_stmt, product: *const message.Product) void {
        bind_uuid(stmt, 1, product.id);
        _ = c.sqlite3_bind_text(stmt, 2, product.name[0..product.name_len].ptr, @intCast(product.name_len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 3, product.description[0..product.description_len].ptr, @intCast(product.description_len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int(stmt, 4, @intCast(product.price_cents));
        _ = c.sqlite3_bind_int(stmt, 5, @intCast(product.inventory));
        _ = c.sqlite3_bind_int(stmt, 6, if (product.active) @as(c_int, 1) else @as(c_int, 0));
    }

    fn read_product(stmt: *c.sqlite3_stmt, out: *message.Product) void {
        // ID (BLOB 16 bytes → u128 big-endian).
        const id_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        out.id = std.mem.readInt(u128, id_blob[0..16], .big);

        // Name.
        const name_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 1));
        const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        assert(name_len <= message.product_name_max);
        @memcpy(out.name[0..name_len], name_ptr[0..name_len]);
        out.name_len = @intCast(name_len);

        // Description.
        const desc_ptr_raw = c.sqlite3_column_text(stmt, 2);
        const desc_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 2));
        if (desc_ptr_raw) |ptr| {
            const desc_ptr: [*]const u8 = @ptrCast(ptr);
            assert(desc_len <= message.product_description_max);
            @memcpy(out.description[0..desc_len], desc_ptr[0..desc_len]);
            out.description_len = @intCast(desc_len);
        } else {
            out.description_len = 0;
        }

        // Numeric fields.
        out.price_cents = @intCast(c.sqlite3_column_int(stmt, 3));
        out.inventory = @intCast(c.sqlite3_column_int(stmt, 4));
        out.active = c.sqlite3_column_int(stmt, 5) != 0;
    }

    fn read_collection(stmt: *c.sqlite3_stmt, out: *message.ProductCollection) void {
        const id_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        out.id = std.mem.readInt(u128, id_blob[0..16], .big);

        const name_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 1));
        const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        assert(name_len <= message.collection_name_max);
        @memcpy(out.name[0..name_len], name_ptr[0..name_len]);
        out.name_len = @intCast(name_len);
    }

    fn prepare(db: *c.sqlite3, sql: [*:0]const u8) *c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            @panic("sqlite3_prepare_v2 failed");
        }
        return stmt.?;
    }

    fn exec(db: *c.sqlite3, sql: [*:0]const u8) void {
        const rc = c.sqlite3_exec(db, sql, null, null, null);
        if (rc != c.SQLITE_OK) {
            @panic("sqlite3_exec failed");
        }
    }
};
