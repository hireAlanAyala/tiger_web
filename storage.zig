const std = @import("std");
const assert = std.debug.assert;
const message = @import("message.zig");
const state_machine = @import("state_machine.zig");
const StorageResult = state_machine.StorageResult;
const marks = @import("tiger_framework").marks;
const log = marks.wrap_log(std.log.scoped(.storage));

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// SQLite-backed persistent storage. Uses prepared statements for all
/// operations. WAL mode for concurrent reads. IDs stored as 16-byte BLOBs.
pub const SqliteStorage = struct {
    pub const LoginCodeEntry = message.LoginCodeEntry;

    db: *c.sqlite3,
    stmt_get: *c.sqlite3_stmt,
    stmt_put: *c.sqlite3_stmt,
    stmt_update: *c.sqlite3_stmt,
    stmt_delete: *c.sqlite3_stmt,
    stmt_list: *c.sqlite3_stmt,
    stmt_get_collection: *c.sqlite3_stmt,
    stmt_put_collection: *c.sqlite3_stmt,
    stmt_update_collection: *c.sqlite3_stmt,
    stmt_list_collections: *c.sqlite3_stmt,
    stmt_add_member: *c.sqlite3_stmt,
    stmt_remove_member: *c.sqlite3_stmt,
    stmt_list_members: *c.sqlite3_stmt,
    stmt_put_order: *c.sqlite3_stmt,
    stmt_put_order_item: *c.sqlite3_stmt,
    stmt_get_order: *c.sqlite3_stmt,
    stmt_get_order_items: *c.sqlite3_stmt,
    stmt_list_orders: *c.sqlite3_stmt,
    stmt_update_order_completion: *c.sqlite3_stmt,
    stmt_search_products: *c.sqlite3_stmt,
    stmt_get_login_code: *c.sqlite3_stmt,
    stmt_put_login_code: *c.sqlite3_stmt,
    stmt_consume_login_code: *c.sqlite3_stmt,
    stmt_get_user_by_email: *c.sqlite3_stmt,
    stmt_put_user: *c.sqlite3_stmt,

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

        ensure_schema(real_db);

        // Prepare product statements.
        const stmt_get = prepare(real_db,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products WHERE id = ?1;",
        );
        const stmt_put = prepare(real_db,
            "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);",
        );
        const stmt_update = prepare(real_db,
            "UPDATE products SET name = ?2, description = ?3, price_cents = ?4, inventory = ?5, version = ?6, active = ?7 WHERE id = ?1;",
        );
        const stmt_delete = prepare(real_db,
            "DELETE FROM products WHERE id = ?1;",
        );
        const stmt_list = prepare(real_db,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products" ++
            " WHERE id > ?1" ++
            " AND (?3 < 0 OR active = ?3)" ++
            " AND price_cents >= ?4" ++
            " AND (?5 = 0 OR price_cents <= ?5)" ++
            " AND (?6 = '' OR substr(name, 1, length(?6)) = ?6)" ++
            " ORDER BY id LIMIT ?2;",
        );

        // Prepare collection statements.
        const stmt_get_collection = prepare(real_db,
            "SELECT id, name, active FROM collections WHERE id = ?1;",
        );
        const stmt_put_collection = prepare(real_db,
            "INSERT INTO collections (id, name, active) VALUES (?1, ?2, ?3);",
        );
        const stmt_update_collection = prepare(real_db,
            "UPDATE collections SET name = ?2, active = ?3 WHERE id = ?1;",
        );
        const stmt_list_collections = prepare(real_db,
            "SELECT id, name, active FROM collections WHERE id > ?1 AND active = 1 ORDER BY id LIMIT ?2;",
        );
        const stmt_add_member = prepare(real_db,
            "INSERT INTO collection_members (collection_id, product_id, removed) VALUES (?1, ?2, 0)" ++
            " ON CONFLICT(collection_id, product_id) DO UPDATE SET removed = 0;",
        );
        const stmt_remove_member = prepare(real_db,
            "UPDATE collection_members SET removed = 1 WHERE collection_id = ?1 AND product_id = ?2 AND removed = 0;",
        );
        const stmt_list_members = prepare(real_db,
            "SELECT p.id, p.name, p.description, p.price_cents, p.inventory, p.version, p.active " ++
            "FROM collection_members cm JOIN products p ON cm.product_id = p.id WHERE cm.collection_id = ?1 AND cm.removed = 0 ORDER BY p.id LIMIT ?2;",
        );

        // Prepare order statements.
        const stmt_put_order = prepare(real_db,
            "INSERT INTO orders (id, total_cents, items_len, status, timeout_at) VALUES (?1, ?2, ?3, ?4, ?5);",
        );
        const stmt_put_order_item = prepare(real_db,
            "INSERT INTO order_items (order_id, product_id, name, quantity, price_cents, line_total_cents) VALUES (?1, ?2, ?3, ?4, ?5, ?6);",
        );
        const stmt_get_order = prepare(real_db,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id = ?1;",
        );
        const stmt_get_order_items = prepare(real_db,
            "SELECT product_id, name, quantity, price_cents, line_total_cents FROM order_items WHERE order_id = ?1 ORDER BY rowid;",
        );
        const stmt_list_orders = prepare(real_db,
            "SELECT id, total_cents, items_len, status, timeout_at, payment_ref FROM orders WHERE id > ?1 ORDER BY id LIMIT ?2;",
        );
        const stmt_update_order_completion = prepare(real_db,
            "UPDATE orders SET status = ?2, payment_ref = ?3 WHERE id = ?1;",
        );
        const stmt_search_products = prepare(real_db,
            "SELECT id, name, description, price_cents, inventory, version, active FROM products" ++
            " WHERE active = 1" ++
            " ORDER BY id;",
        );

        // Prepare login/auth statements.
        const stmt_get_login_code = prepare(real_db,
            "SELECT email, code, expires_at FROM login_codes WHERE email = ?1;",
        );
        const stmt_put_login_code = prepare(real_db,
            "INSERT OR REPLACE INTO login_codes (email, code, expires_at) VALUES (?1, ?2, ?3);",
        );
        const stmt_consume_login_code = prepare(real_db,
            "UPDATE login_codes SET expires_at = 0 WHERE email = ?1;",
        );
        const stmt_get_user_by_email = prepare(real_db,
            "SELECT user_id FROM users WHERE email = ?1;",
        );
        const stmt_put_user = prepare(real_db,
            "INSERT INTO users (user_id, email) VALUES (?1, ?2);",
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
            .stmt_update_collection = stmt_update_collection,
            .stmt_list_collections = stmt_list_collections,
            .stmt_add_member = stmt_add_member,
            .stmt_remove_member = stmt_remove_member,
            .stmt_list_members = stmt_list_members,
            .stmt_put_order = stmt_put_order,
            .stmt_put_order_item = stmt_put_order_item,
            .stmt_get_order = stmt_get_order,
            .stmt_get_order_items = stmt_get_order_items,
            .stmt_list_orders = stmt_list_orders,
            .stmt_update_order_completion = stmt_update_order_completion,
            .stmt_search_products = stmt_search_products,
            .stmt_get_login_code = stmt_get_login_code,
            .stmt_put_login_code = stmt_put_login_code,
            .stmt_consume_login_code = stmt_consume_login_code,
            .stmt_get_user_by_email = stmt_get_user_by_email,
            .stmt_put_user = stmt_put_user,
        };
    }

    pub fn begin(self: *SqliteStorage) void {
        exec(self.db, "BEGIN;");
    }

    pub fn commit(self: *SqliteStorage) void {
        exec(self.db, "COMMIT;");
    }

    pub fn deinit(self: *SqliteStorage) void {
        _ = c.sqlite3_finalize(self.stmt_get);
        _ = c.sqlite3_finalize(self.stmt_put);
        _ = c.sqlite3_finalize(self.stmt_update);
        _ = c.sqlite3_finalize(self.stmt_delete);
        _ = c.sqlite3_finalize(self.stmt_list);
        _ = c.sqlite3_finalize(self.stmt_get_collection);
        _ = c.sqlite3_finalize(self.stmt_put_collection);
        _ = c.sqlite3_finalize(self.stmt_update_collection);
        _ = c.sqlite3_finalize(self.stmt_list_collections);
        _ = c.sqlite3_finalize(self.stmt_add_member);
        _ = c.sqlite3_finalize(self.stmt_remove_member);
        _ = c.sqlite3_finalize(self.stmt_list_members);
        _ = c.sqlite3_finalize(self.stmt_put_order);
        _ = c.sqlite3_finalize(self.stmt_put_order_item);
        _ = c.sqlite3_finalize(self.stmt_get_order);
        _ = c.sqlite3_finalize(self.stmt_get_order_items);
        _ = c.sqlite3_finalize(self.stmt_list_orders);
        _ = c.sqlite3_finalize(self.stmt_update_order_completion);
        _ = c.sqlite3_finalize(self.stmt_search_products);
        _ = c.sqlite3_finalize(self.stmt_get_login_code);
        _ = c.sqlite3_finalize(self.stmt_put_login_code);
        _ = c.sqlite3_finalize(self.stmt_consume_login_code);
        _ = c.sqlite3_finalize(self.stmt_get_user_by_email);
        _ = c.sqlite3_finalize(self.stmt_put_user);
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

    pub fn list(self: *SqliteStorage, out: *[message.list_max]message.Product, out_len: *u32, params: message.ListParams) StorageResult {
        const stmt = self.stmt_list;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, params.cursor);
        _ = c.sqlite3_bind_int(stmt, 2, message.list_max);

        // Active filter: -1 = any, 1 = active only, 0 = inactive only.
        const active_val: c_int = switch (params.active_filter) {
            .any => -1,
            .active_only => 1,
            .inactive_only => 0,
        };
        _ = c.sqlite3_bind_int(stmt, 3, active_val);
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(params.price_min));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(params.price_max));

        // Name prefix: empty string = no filter, otherwise exact prefix
        // match via substr. No LIKE — avoids wildcard divergence (% and _
        // are literals in MemoryStorage's startsWith but wildcards in LIKE).
        if (params.name_prefix_len > 0) {
            // Pair assertion: input_valid rejects NUL bytes at the boundary;
            // assert here at consumption — NUL in text causes SQLite's
            // length() to return a truncated count.
            for (params.name_prefix[0..params.name_prefix_len]) |b| assert(b != 0);

            _ = c.sqlite3_bind_text(stmt, 6, params.name_prefix[0..params.name_prefix_len].ptr, @intCast(params.name_prefix_len), c.SQLITE_TRANSIENT);
        } else {
            _ = c.sqlite3_bind_text(stmt, 6, "", 0, c.SQLITE_TRANSIENT);
        }
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

    pub fn search(self: *SqliteStorage, out: *[message.list_max]message.Product, out_len: *u32, query: message.SearchQuery) StorageResult {
        const stmt = self.stmt_search_products;
        defer reset_stmt(stmt);
        out_len.* = 0;

        while (true) {
            switch (step_result(stmt)) {
                .row => {
                    var product: message.Product = undefined;
                    read_product(stmt, &product);
                    if (query.matches(&product) and out_len.* < message.list_max) {
                        out[out_len.*] = product;
                        out_len.* += 1;
                    }
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
        _ = c.sqlite3_bind_int(stmt, 3, if (col.flags.active) @as(c_int, 1) else @as(c_int, 0));
        return switch (step_result(stmt)) {
            .done => .ok,
            .row => unreachable,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn update_collection(self: *SqliteStorage, id: u128, col: *const message.ProductCollection) StorageResult {
        const stmt = self.stmt_update_collection;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, id);
        _ = c.sqlite3_bind_text(stmt, 2, col.name[0..col.name_len].ptr, @intCast(col.name_len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int(stmt, 3, if (col.flags.active) @as(c_int, 1) else @as(c_int, 0));
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

    pub fn list_collections(self: *SqliteStorage, out: *[message.list_max]message.ProductCollection, out_len: *u32, cursor: u128) StorageResult {
        const stmt = self.stmt_list_collections;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, cursor);
        _ = c.sqlite3_bind_int(stmt, 2, message.list_max);
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

    // --- Order operations ---

    pub fn put_order(self: *SqliteStorage, order: *const message.OrderResult) StorageResult {
        // Insert order header.
        {
            const stmt = self.stmt_put_order;
            defer reset_stmt(stmt);
            bind_uuid(stmt, 1, order.id);
            _ = c.sqlite3_bind_int64(stmt, 2, @intCast(order.total_cents));
            _ = c.sqlite3_bind_int(stmt, 3, @intCast(order.items_len));
            _ = c.sqlite3_bind_int(stmt, 4, @intFromEnum(order.status));
            _ = c.sqlite3_bind_int64(stmt, 5, @intCast(order.timeout_at));
            switch (step_result(stmt)) {
                .done => {},
                .row => unreachable,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
        // Insert line items.
        for (order.items[0..order.items_len]) |*item| {
            const stmt = self.stmt_put_order_item;
            defer reset_stmt(stmt);
            bind_uuid(stmt, 1, order.id);
            bind_uuid(stmt, 2, item.product_id);
            _ = c.sqlite3_bind_text(stmt, 3, item.name[0..item.name_len].ptr, @intCast(item.name_len), c.SQLITE_TRANSIENT);
            _ = c.sqlite3_bind_int64(stmt, 4, @intCast(item.quantity));
            _ = c.sqlite3_bind_int64(stmt, 5, @intCast(item.price_cents));
            _ = c.sqlite3_bind_int64(stmt, 6, @intCast(item.line_total_cents));
            switch (step_result(stmt)) {
                .done => {},
                .row => unreachable,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
        return .ok;
    }

    pub fn get_order(self: *SqliteStorage, id: u128, out: *message.OrderResult) StorageResult {
        out.* = std.mem.zeroes(message.OrderResult);

        // Read order header.
        {
            const stmt = self.stmt_get_order;
            defer reset_stmt(stmt);
            bind_uuid(stmt, 1, id);
            switch (step_result(stmt)) {
                .row => {
                    const id_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
                    out.id = std.mem.readInt(u128, id_blob[0..16], .big);
                    out.total_cents = @intCast(c.sqlite3_column_int64(stmt, 1));
                    out.items_len = @intCast(c.sqlite3_column_int(stmt, 2));
                    out.status = @enumFromInt(c.sqlite3_column_int(stmt, 3));
                    out.timeout_at = @intCast(c.sqlite3_column_int64(stmt, 4));
                    const ref_ptr = c.sqlite3_column_text(stmt, 5);
                    const ref_len: u8 = @intCast(c.sqlite3_column_bytes(stmt, 5));
                    if (ref_len > 0 and ref_len <= message.payment_ref_max) {
                        @memcpy(out.payment_ref[0..ref_len], ref_ptr[0..ref_len]);
                        out.payment_ref_len = ref_len;
                    }
                },
                .done => return .not_found,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
        // Read line items.
        {
            const stmt = self.stmt_get_order_items;
            defer reset_stmt(stmt);
            bind_uuid(stmt, 1, id);
            var i: u8 = 0;
            while (true) {
                switch (step_result(stmt)) {
                    .row => {
                        assert(i < message.order_items_max);
                        read_order_item(stmt, &out.items[i]);
                        i += 1;
                    },
                    .done => break,
                    .busy => return .busy,
                    .err => return .err,
                    .corruption => return .corruption,
                }
            }
            assert(i == out.items_len);
        }
        return .ok;
    }

    pub fn update_order_completion(self: *SqliteStorage, order: *const message.OrderResult) StorageResult {
        const stmt = self.stmt_update_order_completion;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, order.id);
        _ = c.sqlite3_bind_int(stmt, 2, @intFromEnum(order.status));
        _ = c.sqlite3_bind_text(stmt, 3, @ptrCast(order.payment_ref[0..order.payment_ref_len]), @intCast(order.payment_ref_len), null);
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

    pub fn list_orders(self: *SqliteStorage, out: *[message.list_max]message.OrderSummary, out_len: *u32, cursor: u128) StorageResult {
        const stmt = self.stmt_list_orders;
        defer reset_stmt(stmt);

        bind_uuid(stmt, 1, cursor);
        _ = c.sqlite3_bind_int(stmt, 2, message.list_max);
        out_len.* = 0;

        while (true) {
            switch (step_result(stmt)) {
                .row => {
                    assert(out_len.* < message.list_max);
                    out[out_len.*] = std.mem.zeroes(message.OrderSummary);
                    const id_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
                    out[out_len.*].id = std.mem.readInt(u128, id_blob[0..16], .big);
                    out[out_len.*].total_cents = @intCast(c.sqlite3_column_int64(stmt, 1));
                    out[out_len.*].items_len = @intCast(c.sqlite3_column_int(stmt, 2));
                    out[out_len.*].status = @enumFromInt(c.sqlite3_column_int(stmt, 3));
                    out[out_len.*].timeout_at = @intCast(c.sqlite3_column_int64(stmt, 4));
                    const ref_ptr = c.sqlite3_column_text(stmt, 5);
                    const ref_len: u8 = @intCast(c.sqlite3_column_bytes(stmt, 5));
                    if (ref_len > 0 and ref_len <= message.payment_ref_max) {
                        @memcpy(out[out_len.*].payment_ref[0..ref_len], ref_ptr[0..ref_len]);
                        out[out_len.*].payment_ref_len = ref_len;
                    }
                    out_len.* += 1;
                },
                .done => return .ok,
                .busy => return .busy,
                .err => return .err,
                .corruption => return .corruption,
            }
        }
    }

    fn read_order_item(stmt: *c.sqlite3_stmt, out: *message.OrderResultItem) void {
        out.* = std.mem.zeroes(message.OrderResultItem);

        const pid_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        out.product_id = std.mem.readInt(u128, pid_blob[0..16], .big);

        const name_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 1));
        const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        assert(name_len <= message.product_name_max);
        @memcpy(out.name[0..name_len], name_ptr[0..name_len]);
        out.name_len = @intCast(name_len);

        out.quantity = @intCast(c.sqlite3_column_int64(stmt, 2));
        out.price_cents = @intCast(c.sqlite3_column_int64(stmt, 3));
        out.line_total_cents = @intCast(c.sqlite3_column_int64(stmt, 4));
    }

    // --- Login/auth operations ---

    pub fn get_login_code(self: *SqliteStorage, email: []const u8, out: *LoginCodeEntry) StorageResult {
        const stmt = self.stmt_get_login_code;
        defer reset_stmt(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, email.ptr, @intCast(email.len), c.SQLITE_TRANSIENT);
        return switch (step_result(stmt)) {
            .row => {
                out.occupied = 1;
                out.email_len = @intCast(email.len);
                @memset(&out.email, 0);
                @memcpy(out.email[0..email.len], email);
                // Read code (TEXT).
                const code_ptr = c.sqlite3_column_text(stmt, 1);
                const code_len = c.sqlite3_column_bytes(stmt, 1);
                if (code_len != message.code_length) return .err;
                @memcpy(&out.code, code_ptr[0..message.code_length]);
                out.expires_at = c.sqlite3_column_int64(stmt, 2);
                return .ok;
            },
            .done => .not_found,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn put_login_code(self: *SqliteStorage, email: []const u8, code: *const [message.code_length]u8, expires_at: i64) StorageResult {
        const stmt = self.stmt_put_login_code;
        defer reset_stmt(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, email.ptr, @intCast(email.len), c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, code, message.code_length, c.SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(stmt, 3, expires_at);
        return switch (step_result(stmt)) {
            .done => .ok,
            .busy => .busy,
            .row, .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn consume_login_code(self: *SqliteStorage, email: []const u8) StorageResult {
        const stmt = self.stmt_consume_login_code;
        defer reset_stmt(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, email.ptr, @intCast(email.len), c.SQLITE_TRANSIENT);
        return switch (step_result(stmt)) {
            .done => .ok,
            .busy => .busy,
            .row, .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn get_user_by_email(self: *SqliteStorage, email: []const u8, out: *u128) StorageResult {
        const stmt = self.stmt_get_user_by_email;
        defer reset_stmt(stmt);
        _ = c.sqlite3_bind_text(stmt, 1, email.ptr, @intCast(email.len), c.SQLITE_TRANSIENT);
        return switch (step_result(stmt)) {
            .row => {
                out.* = read_uuid(stmt, 0);
                return .ok;
            },
            .done => .not_found,
            .busy => .busy,
            .err => .err,
            .corruption => .corruption,
        };
    }

    pub fn put_user(self: *SqliteStorage, user_id: u128, email: []const u8) StorageResult {
        const stmt = self.stmt_put_user;
        defer reset_stmt(stmt);
        bind_uuid(stmt, 1, user_id);
        _ = c.sqlite3_bind_text(stmt, 2, email.ptr, @intCast(email.len), c.SQLITE_TRANSIENT);
        return switch (step_result(stmt)) {
            .done => .ok,
            .busy => .busy,
            .row, .err => .err,
            .corruption => .corruption,
        };
    }

    // --- Raw SQL interface ---
    //
    // Handlers call db.sql() to query the database with raw SQL.
    // Parameters are bound (never interpolated) — no SQL injection.
    // Statements are prepared per-call (not cached). Caching can be
    // added later as an optimization without changing the interface.

    /// Execute a SQL query with typed parameters. Returns a QueryResult
    /// for iterating rows, or null if the database is busy.
    pub fn sql(self: *SqliteStorage, comptime query: [*:0]const u8, args: anytype) ?QueryResult {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, query, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            log.warn("sql: prepare failed: {s}", .{c.sqlite3_errmsg(self.db)});
            return null;
        }
        const real_stmt = stmt.?;

        // Bind parameters from tuple.
        bind_params(real_stmt, args);

        return .{ .stmt = real_stmt };
    }

    /// Result handle from sql(). Call next() to iterate rows, finish() when done.
    pub const QueryResult = struct {
        stmt: *c.sqlite3_stmt,

        /// Advance to the next row. Returns .row, .done, .busy, .err, or .corruption.
        pub fn next(self: *QueryResult) StepResult {
            return step_result(self.stmt);
        }

        /// Read a column as u128 (stored as 16-byte BLOB big-endian).
        pub fn col_uuid(self: *QueryResult, col: c_int) u128 {
            return read_uuid(self.stmt, col);
        }

        /// Read a column as text. Returns a slice valid until next()/finish().
        pub fn col_text(self: *QueryResult, col: c_int) []const u8 {
            const ptr_raw = c.sqlite3_column_text(self.stmt, col);
            const len: usize = @intCast(c.sqlite3_column_bytes(self.stmt, col));
            if (ptr_raw) |ptr| {
                const p: [*]const u8 = @ptrCast(ptr);
                return p[0..len];
            }
            return "";
        }

        /// Read a column as i64.
        pub fn col_i64(self: *QueryResult, col: c_int) i64 {
            return c.sqlite3_column_int64(self.stmt, col);
        }

        /// Read a column as u32.
        pub fn col_u32(self: *QueryResult, col: c_int) u32 {
            return @intCast(c.sqlite3_column_int64(self.stmt, col));
        }

        /// Read a column as bool (0 = false, non-zero = true).
        pub fn col_bool(self: *QueryResult, col: c_int) bool {
            return c.sqlite3_column_int(self.stmt, col) != 0;
        }

        /// Finalize the statement. Must be called when done reading rows.
        pub fn finish(self: *QueryResult) void {
            _ = c.sqlite3_finalize(self.stmt);
        }
    };

    /// Bind a tuple of parameters to a prepared statement.
    /// Supports u128 (as BLOB), []const u8 (as text), integers (as i64), bool (as int).
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
        if (T == u128) {
            var buf: [16]u8 = undefined;
            std.mem.writeInt(u128, &buf, val, .big);
            _ = c.sqlite3_bind_blob(stmt, col, &buf, 16, c.SQLITE_TRANSIENT);
        } else if (T == []const u8) {
            _ = c.sqlite3_bind_text(stmt, col, val.ptr, @intCast(val.len), c.SQLITE_TRANSIENT);
        } else if (T == bool) {
            _ = c.sqlite3_bind_int(stmt, col, if (val) @as(c_int, 1) else @as(c_int, 0));
        } else if (T == i64) {
            _ = c.sqlite3_bind_int64(stmt, col, val);
        } else if (@typeInfo(T) == .int or @typeInfo(T) == .comptime_int) {
            _ = c.sqlite3_bind_int64(stmt, col, @intCast(val));
        } else {
            @compileError("unsupported parameter type: " ++ @typeName(T));
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

    fn read_uuid(stmt: *c.sqlite3_stmt, col: c_int) u128 {
        const blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, col));
        return std.mem.readInt(u128, blob[0..16], .big);
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
        _ = c.sqlite3_bind_int64(stmt, 4, @intCast(product.price_cents));
        _ = c.sqlite3_bind_int64(stmt, 5, @intCast(product.inventory));
        _ = c.sqlite3_bind_int64(stmt, 6, @intCast(product.version));
        _ = c.sqlite3_bind_int(stmt, 7, if (product.flags.active) @as(c_int, 1) else @as(c_int, 0));
    }

    fn read_product(stmt: *c.sqlite3_stmt, out: *message.Product) void {
        out.* = std.mem.zeroes(message.Product);

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
        out.price_cents = @intCast(c.sqlite3_column_int64(stmt, 3));
        out.inventory = @intCast(c.sqlite3_column_int64(stmt, 4));
        out.version = @intCast(c.sqlite3_column_int64(stmt, 5));
        out.flags = .{ .active = c.sqlite3_column_int64(stmt, 6) != 0 };
    }

    fn read_collection(stmt: *c.sqlite3_stmt, out: *message.ProductCollection) void {
        out.* = std.mem.zeroes(message.ProductCollection);

        const id_blob: [*]const u8 = @ptrCast(c.sqlite3_column_blob(stmt, 0));
        out.id = std.mem.readInt(u128, id_blob[0..16], .big);

        const name_ptr: [*]const u8 = @ptrCast(c.sqlite3_column_text(stmt, 1));
        const name_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        assert(name_len <= message.collection_name_max);
        @memcpy(out.name[0..name_len], name_ptr[0..name_len]);
        out.name_len = @intCast(name_len);
        out.flags = .{ .active = c.sqlite3_column_int64(stmt, 2) != 0 };
    }

    fn prepare(db: *c.sqlite3, query: [*:0]const u8) *c.sqlite3_stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, query, -1, &stmt, null);
        if (rc != c.SQLITE_OK) {
            @panic("sqlite3_prepare_v2 failed");
        }
        return stmt.?;
    }

    fn exec(db: *c.sqlite3, query: [*:0]const u8) void {
        const rc = c.sqlite3_exec(db, query, null, null, null);
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
    /// See decisions/database.md.
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

test "roundtrip product with max u32 fields" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    const max = std.math.maxInt(u32);
    var p = make_test_product(1, "Expensive", max);
    p.inventory = max;
    p.version = max;
    assert(s.put(&p) == .ok);

    var out: message.Product = undefined;
    assert(s.get(1, &out) == .ok);
    try std.testing.expectEqual(out.price_cents, max);
    try std.testing.expectEqual(out.inventory, max);
    try std.testing.expectEqual(out.version, max);
}

test "list with max u32 price filters" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    var p = make_test_product(1, "Widget", std.math.maxInt(u32));
    assert(s.put(&p) == .ok);

    // price_min = maxInt(u32) should match.
    var out: [message.list_max]message.Product = undefined;
    var out_len: u32 = 0;
    var lp1 = std.mem.zeroes(message.ListParams);
    lp1.price_min = std.math.maxInt(u32);
    assert(s.list(&out, &out_len, lp1) == .ok);
    try std.testing.expectEqual(out_len, 1);

    // price_max = maxInt(u32) - 1 should exclude it.
    out_len = 0;
    var lp2 = std.mem.zeroes(message.ListParams);
    lp2.price_max = std.math.maxInt(u32) - 1;
    assert(s.list(&out, &out_len, lp2) == .ok);
    try std.testing.expectEqual(out_len, 0);
}

test "order items preserve insertion order" {
    var s = try SqliteStorage.init(":memory:");
    defer s.deinit();

    // Create an order with items whose product IDs are in descending order.
    var order = std.mem.zeroes(message.OrderResult);
    order.id = 1;
    order.items_len = 3;
    order.total_cents = 600;
    order.status = .pending;
    order.timeout_at = 1_700_000_060;
    const ids = [3]u128{ 0xff, 0x80, 0x01 };
    for (ids, 0..) |pid, i| {
        order.items[i] = std.mem.zeroes(message.OrderResultItem);
        order.items[i].product_id = pid;
        order.items[i].name_len = 1;
        order.items[i].quantity = 1;
        order.items[i].price_cents = 200;
        order.items[i].line_total_cents = 200;
        order.items[i].name[0] = 'A' + @as(u8, @intCast(i));
    }
    assert(s.put_order(&order) == .ok);

    var out: message.OrderResult = undefined;
    assert(s.get_order(1, &out) == .ok);
    try std.testing.expectEqual(out.items_len, 3);
    // Items must come back in insertion order (ORDER BY rowid), not by product_id.
    try std.testing.expectEqual(out.items[0].product_id, 0xff);
    try std.testing.expectEqual(out.items[1].product_id, 0x80);
    try std.testing.expectEqual(out.items[2].product_id, 0x01);
}
