// Fastify comparison server — same schema, same routes, same workload
// as tiger-web's ecommerce example. Used by tiger-load for apples-to-apples
// benchmarking (same load gen, same operations, same SQLite database).
//
// Usage:
//   node server.js                  # port 3000
//   node server.js --port=0         # random port, prints to stdout
//   node server.js --port=8080      # specific port
//   node server.js --db=:memory:    # in-memory SQLite

import Fastify from "fastify";
import Database from "better-sqlite3";

// --- CLI args ---

const args = Object.fromEntries(
  process.argv.slice(2)
    .filter(a => a.startsWith("--"))
    .map(a => { const [k, v] = a.slice(2).split("="); return [k, v ?? "true"]; })
);

const port = args.port !== undefined ? parseInt(args.port) : 3000;
const dbPath = args.db || "fastify_bench.db";

// --- Database ---

const db = new Database(dbPath);
db.pragma("journal_mode = WAL");

db.exec(`
  CREATE TABLE IF NOT EXISTS products (
    id BLOB(16) PRIMARY KEY NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    price_cents INTEGER NOT NULL DEFAULT 0,
    inventory INTEGER NOT NULL DEFAULT 0,
    version INTEGER NOT NULL DEFAULT 1,
    active INTEGER NOT NULL DEFAULT 1
  );
  CREATE TABLE IF NOT EXISTS collections (
    id BLOB(16) PRIMARY KEY NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    active INTEGER NOT NULL DEFAULT 1
  );
  CREATE TABLE IF NOT EXISTS orders (
    id BLOB(16) PRIMARY KEY NOT NULL,
    total_cents INTEGER NOT NULL DEFAULT 0,
    items_len INTEGER NOT NULL DEFAULT 0,
    status INTEGER NOT NULL DEFAULT 0,
    timeout_at INTEGER NOT NULL DEFAULT 0,
    payment_ref INTEGER NOT NULL DEFAULT 0
  );
  CREATE TABLE IF NOT EXISTS order_items (
    order_id BLOB(16) NOT NULL,
    product_id BLOB(16) NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    quantity INTEGER NOT NULL DEFAULT 0,
    price_cents INTEGER NOT NULL DEFAULT 0,
    line_total_cents INTEGER NOT NULL DEFAULT 0
  );
`);

// --- UUID helpers ---
// Tiger-web uses 128-bit UUIDs as 32-char lowercase hex strings in JSON,
// stored as 16-byte BLOBs in SQLite.

function uuidToBlob(hex) {
  return Buffer.from(hex, "hex");
}

function blobToHex(buf) {
  return Buffer.from(buf).toString("hex");
}

// --- Prepared statements ---

const stmts = {
  insertProduct: db.prepare(
    "INSERT INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?, ?, ?, ?, ?, 1, 1)"
  ),
  getProduct: db.prepare("SELECT * FROM products WHERE id = ?"),
  listProducts: db.prepare("SELECT * FROM products ORDER BY id LIMIT 18"),
  insertCollection: db.prepare(
    "INSERT INTO collections (id, name, active) VALUES (?, ?, 1)"
  ),
  getCollection: db.prepare("SELECT * FROM collections WHERE id = ?"),
  listCollections: db.prepare("SELECT * FROM collections WHERE active = 1 ORDER BY id LIMIT 18"),
  insertOrder: db.prepare(
    "INSERT INTO orders (id, total_cents, items_len, status, timeout_at, payment_ref) VALUES (?, ?, ?, 0, 0, 0)"
  ),
  insertOrderItem: db.prepare(
    "INSERT INTO order_items (order_id, product_id, name, quantity, price_cents, line_total_cents) VALUES (?, ?, ?, ?, ?, ?)"
  ),
  getOrder: db.prepare("SELECT * FROM orders WHERE id = ?"),
  listOrders: db.prepare("SELECT * FROM orders ORDER BY id LIMIT 18"),
  getProductForOrder: db.prepare("SELECT id, name, price_cents, inventory FROM products WHERE id = ?"),
};

// --- Fastify app ---

const app = Fastify({ logger: false });

// Products

app.post("/products", (req, reply) => {
  const { id, name, description, price_cents, inventory } = req.body;
  const blob = uuidToBlob(id);
  try {
    stmts.insertProduct.run(blob, name || "", description || "", price_cents || 0, inventory || 0);
  } catch {
    // Duplicate — return 200 anyway (tiger-web always returns 200)
  }
  reply.header("Content-Type", "text/html").send("ok");
});

app.get("/products/:id", (req, reply) => {
  const row = stmts.getProduct.get(uuidToBlob(req.params.id));
  if (!row) return reply.header("Content-Type", "text/html").send("not found");
  reply.header("Content-Type", "text/html").send(renderProduct(row));
});

app.get("/products", (req, reply) => {
  const rows = stmts.listProducts.all();
  const html = rows.filter(r => r.active).map(renderProduct).join("");
  reply.header("Content-Type", "text/html").send(html || "No products");
});

// Collections

app.post("/collections", (req, reply) => {
  const { id, name } = req.body;
  try {
    stmts.insertCollection.run(uuidToBlob(id), name || "");
  } catch {}
  reply.header("Content-Type", "text/html").send("ok");
});

app.get("/collections/:id", (req, reply) => {
  const row = stmts.getCollection.get(uuidToBlob(req.params.id));
  if (!row) return reply.header("Content-Type", "text/html").send("not found");
  reply.header("Content-Type", "text/html").send(
    `<div class="card"><strong>${esc(row.name)}</strong></div>`
  );
});

app.get("/collections", (req, reply) => {
  const rows = stmts.listCollections.all();
  const html = rows.map(r =>
    `<div class="card"><strong>${esc(r.name)}</strong><div class="meta">${blobToHex(r.id)}</div></div>`
  ).join("");
  reply.header("Content-Type", "text/html").send(html || "No collections");
});

// Orders

app.post("/orders", (req, reply) => {
  const { id, items } = req.body;
  const blob = uuidToBlob(id);
  let total = 0;
  const resolvedItems = [];

  for (const item of items || []) {
    const product = stmts.getProductForOrder.get(uuidToBlob(item.product_id));
    if (!product) continue;
    const qty = item.quantity || 1;
    const lineTotal = product.price_cents * qty;
    total += lineTotal;
    resolvedItems.push({ orderBlob: blob, productBlob: product.id, name: product.name, qty, price: product.price_cents, lineTotal });
  }

  const insertAll = db.transaction(() => {
    try {
      stmts.insertOrder.run(blob, total, resolvedItems.length);
    } catch { return; }
    for (const ri of resolvedItems) {
      stmts.insertOrderItem.run(ri.orderBlob, ri.productBlob, ri.name, ri.qty, ri.price, ri.lineTotal);
    }
  });
  insertAll();

  reply.header("Content-Type", "text/html").send("ok");
});

app.get("/orders/:id", (req, reply) => {
  const row = stmts.getOrder.get(uuidToBlob(req.params.id));
  if (!row) return reply.header("Content-Type", "text/html").send("not found");
  reply.header("Content-Type", "text/html").send(
    `<div class="card">Order <strong>${blobToHex(row.id)}</strong> &mdash; ${formatPrice(row.total_cents)}</div>`
  );
});

app.get("/orders", (req, reply) => {
  const rows = stmts.listOrders.all();
  const html = rows.map(r =>
    `<div class="card">Order <strong>${blobToHex(r.id)}</strong> &mdash; ${formatPrice(r.total_cents)}</div>`
  ).join("");
  reply.header("Content-Type", "text/html").send(html || "No orders");
});

// Dashboard
app.get("/", (req, reply) => {
  reply.header("Content-Type", "text/html").send("<h1>Fastify Comparison</h1>");
});

// --- Helpers ---

function esc(s) {
  return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

function formatPrice(cents) {
  return "$" + (cents / 100).toFixed(2);
}

function renderProduct(row) {
  return `<div class="card"><strong>${esc(row.name)}</strong> &mdash; ${formatPrice(row.price_cents)} &mdash; inv: ${row.inventory} &mdash; v${row.version}</div>`;
}

// --- Start ---

const address = await app.listen({ port, host: "127.0.0.1" });
const actualPort = app.server.address().port;

// tiger-load reads a bare port number from stdout for --port=0 coordination.
if (port === 0) {
  process.stdout.write(String(actualPort) + "\n");
}
process.stderr.write(`Fastify listening on port ${actualPort}\n`);
