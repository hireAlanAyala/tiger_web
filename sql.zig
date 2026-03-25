//! Shared SQL constants — single source of truth for write statements.
//!
//! Handlers reference these instead of inlining SQL strings. If a column
//! is added or renamed, one change here updates every handler that uses it.
//! Read queries stay in handlers — they're shaped by the handler's needs.
//! Write SQL is shaped by the table schema, which is shared.

pub const products = struct {
    pub const insert: [*:0]const u8 =
        "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7);";
    pub const update: [*:0]const u8 =
        "UPDATE products SET name = ?2, description = ?3, price_cents = ?4, inventory = ?5, version = ?6, active = ?7 WHERE id = ?1;";
};

pub const collections = struct {
    pub const insert: [*:0]const u8 =
        "INSERT INTO collections (id, name, active) VALUES (?1, ?2, ?3);";
    pub const update: [*:0]const u8 =
        "UPDATE collections SET name = ?2, active = ?3 WHERE id = ?1;";
};

pub const collection_members = struct {
    pub const upsert: [*:0]const u8 =
        "INSERT INTO collection_members (collection_id, product_id, removed) VALUES (?1, ?2, 0)" ++
        " ON CONFLICT(collection_id, product_id) DO UPDATE SET removed = 0;";
    pub const remove: [*:0]const u8 =
        "UPDATE collection_members SET removed = 1 WHERE collection_id = ?1 AND product_id = ?2 AND removed = 0;";
};

pub const orders = struct {
    pub const insert: [*:0]const u8 =
        "INSERT INTO orders (id, total_cents, items_len, status, timeout_at) VALUES (?1, ?2, ?3, ?4, ?5);";
    pub const insert_item: [*:0]const u8 =
        "INSERT INTO order_items (order_id, product_id, name, quantity, price_cents, line_total_cents) VALUES (?1, ?2, ?3, ?4, ?5, ?6);";
    pub const update_status: [*:0]const u8 =
        "UPDATE orders SET status = ?2 WHERE id = ?1;";
};
