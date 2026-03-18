CREATE TABLE products (
    id BLOB(16) PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    price_cents INTEGER NOT NULL DEFAULT 0,
    inventory INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1,
    active INTEGER NOT NULL DEFAULT 1,
    weight_grams INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE collections (
    id BLOB(16) PRIMARY KEY,
    name TEXT NOT NULL
);

CREATE TABLE collection_members (
    collection_id BLOB(16) NOT NULL,
    product_id BLOB(16) NOT NULL,
    PRIMARY KEY (collection_id, product_id)
);

CREATE TABLE orders (
    id BLOB(16) PRIMARY KEY,
    total_cents INTEGER NOT NULL,
    items_len INTEGER NOT NULL,
    status INTEGER NOT NULL DEFAULT 1,
    timeout_at INTEGER NOT NULL DEFAULT 0,
    payment_ref TEXT NOT NULL DEFAULT ''
);

CREATE TABLE order_items (
    order_id BLOB(16) NOT NULL,
    product_id BLOB(16) NOT NULL,
    name TEXT NOT NULL,
    quantity INTEGER NOT NULL,
    price_cents INTEGER NOT NULL,
    line_total_cents INTEGER NOT NULL,
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE login_codes (
    email TEXT NOT NULL PRIMARY KEY,
    code TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);

CREATE TABLE users (
    user_id BLOB(16) PRIMARY KEY,
    email TEXT NOT NULL UNIQUE
);
