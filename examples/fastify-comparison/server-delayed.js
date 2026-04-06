// Fastify with artificial per-request delay to simulate sidecar frame overhead.
// Used to validate throughput projections for direct-SQLite sidecar model.

import Fastify from "fastify";
import Database from "better-sqlite3";

const port = 9878;
const DELAY_US = parseInt(process.argv[2] || "8");

const db = new Database(":memory:");
db.pragma("journal_mode = WAL");
db.exec(`
  CREATE TABLE IF NOT EXISTS products (id BLOB(16) PRIMARY KEY NOT NULL, name TEXT NOT NULL DEFAULT '', description TEXT NOT NULL DEFAULT '', price_cents INTEGER NOT NULL DEFAULT 0, inventory INTEGER NOT NULL DEFAULT 0, version INTEGER NOT NULL DEFAULT 1, active INTEGER NOT NULL DEFAULT 1);
  CREATE TABLE IF NOT EXISTS collections (id BLOB(16) PRIMARY KEY NOT NULL, name TEXT NOT NULL DEFAULT '', active INTEGER NOT NULL DEFAULT 1);
  CREATE TABLE IF NOT EXISTS orders (id BLOB(16) PRIMARY KEY NOT NULL, total_cents INTEGER NOT NULL DEFAULT 0, items_len INTEGER NOT NULL DEFAULT 0, status INTEGER NOT NULL DEFAULT 0, timeout_at INTEGER NOT NULL DEFAULT 0, payment_ref INTEGER NOT NULL DEFAULT 0);
  CREATE TABLE IF NOT EXISTS order_items (order_id BLOB(16) NOT NULL, product_id BLOB(16) NOT NULL, name TEXT NOT NULL DEFAULT '', quantity INTEGER NOT NULL DEFAULT 0, price_cents INTEGER NOT NULL DEFAULT 0, line_total_cents INTEGER NOT NULL DEFAULT 0);
`);

const stmts = {
  insertProduct: db.prepare("INSERT OR IGNORE INTO products (id, name, description, price_cents, inventory, version, active) VALUES (?, ?, ?, ?, ?, 1, 1)"),
  getProduct: db.prepare("SELECT * FROM products WHERE id = ?"),
  listProducts: db.prepare("SELECT * FROM products ORDER BY id LIMIT 18"),
  insertCollection: db.prepare("INSERT OR IGNORE INTO collections (id, name, active) VALUES (?, ?, 1)"),
  getCollection: db.prepare("SELECT * FROM collections WHERE id = ?"),
  listCollections: db.prepare("SELECT * FROM collections WHERE active = 1 ORDER BY id LIMIT 18"),
  insertOrder: db.prepare("INSERT OR IGNORE INTO orders (id, total_cents, items_len, status, timeout_at, payment_ref) VALUES (?, ?, ?, 0, 0, 0)"),
  insertOrderItem: db.prepare("INSERT INTO order_items (order_id, product_id, name, quantity, price_cents, line_total_cents) VALUES (?, ?, ?, ?, ?, ?)"),
  getOrder: db.prepare("SELECT * FROM orders WHERE id = ?"),
  listOrders: db.prepare("SELECT * FROM orders ORDER BY id LIMIT 18"),
  getProductForOrder: db.prepare("SELECT id, name, price_cents, inventory FROM products WHERE id = ?"),
};

function busyWait(us) {
  const end = process.hrtime.bigint() + BigInt(us) * 1000n;
  while (process.hrtime.bigint() < end) {}
}

function esc(s) { return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;"); }
function price(c) { return "$" + (c/100).toFixed(2); }
function render(r) { return `<div class="card"><strong>${esc(r.name)}</strong> — ${price(r.price_cents)} — inv: ${r.inventory} — v${r.version}</div>`; }
function uuidToBlob(h) { return Buffer.from(h,"hex"); }
function blobToHex(b) { return Buffer.from(b).toString("hex"); }

const app = Fastify({ logger: false });

app.post("/products", (req, reply) => { busyWait(DELAY_US); const {id,name,description,price_cents,inventory}=req.body; try{stmts.insertProduct.run(uuidToBlob(id),name||"",description||"",price_cents||0,inventory||0)}catch{} reply.header("Content-Type","text/html").send("ok"); });
app.get("/products/:id", (req, reply) => { busyWait(DELAY_US); const r=stmts.getProduct.get(uuidToBlob(req.params.id)); reply.header("Content-Type","text/html").send(r?render(r):"not found"); });
app.get("/products", (req, reply) => { busyWait(DELAY_US); reply.header("Content-Type","text/html").send(stmts.listProducts.all().filter(r=>r.active).map(render).join("")||"No products"); });
app.post("/collections", (req, reply) => { busyWait(DELAY_US); try{stmts.insertCollection.run(uuidToBlob(req.body.id),req.body.name||"")}catch{} reply.header("Content-Type","text/html").send("ok"); });
app.get("/collections/:id", (req, reply) => { busyWait(DELAY_US); const r=stmts.getCollection.get(uuidToBlob(req.params.id)); reply.header("Content-Type","text/html").send(r?`<div>${esc(r.name)}</div>`:"not found"); });
app.get("/collections", (req, reply) => { busyWait(DELAY_US); reply.header("Content-Type","text/html").send(stmts.listCollections.all().map(r=>`<div>${esc(r.name)}</div>`).join("")||"No collections"); });
app.post("/orders", (req, reply) => { busyWait(DELAY_US); const {id,items}=req.body; const blob=uuidToBlob(id); let total=0; const ri=[]; for(const i of items||[]){const p=stmts.getProductForOrder.get(uuidToBlob(i.product_id));if(!p)continue;const q=i.quantity||1;const lt=p.price_cents*q;total+=lt;ri.push({ob:blob,pb:p.id,n:p.name,q,pr:p.price_cents,lt})} const tx=db.transaction(()=>{try{stmts.insertOrder.run(blob,total,ri.length)}catch{return} for(const r of ri)stmts.insertOrderItem.run(r.ob,r.pb,r.n,r.q,r.pr,r.lt)}); tx(); reply.header("Content-Type","text/html").send("ok"); });
app.get("/orders/:id", (req, reply) => { busyWait(DELAY_US); const r=stmts.getOrder.get(uuidToBlob(req.params.id)); reply.header("Content-Type","text/html").send(r?`<div>Order ${blobToHex(r.id)} — ${price(r.total_cents)}</div>`:"not found"); });
app.get("/orders", (req, reply) => { busyWait(DELAY_US); reply.header("Content-Type","text/html").send(stmts.listOrders.all().map(r=>`<div>Order ${blobToHex(r.id)} — ${price(r.total_cents)}</div>`).join("")||"No orders"); });
app.get("/", (req, reply) => { reply.header("Content-Type","text/html").send("ok"); });

const address = await app.listen({ port, host: "127.0.0.1" });
process.stdout.write(port + "\n");
process.stderr.write(`Fastify-delayed (${DELAY_US}µs) on port ${port}\n`);
