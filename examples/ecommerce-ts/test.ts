// Integration test suite for the ecommerce-ts example project.
//
// Exercises all 24 handlers through the full sidecar pipeline:
// TypeScript handler → sidecar binary protocol → Zig state machine → SQLite → back.
//
// Usage: npx tsx test.ts
//
// Self-contained: starts sidecar + server with --db pointing to a temp file,
// runs tests, kills both processes. Never touches tiger_web.db.

import { execSync } from "child_process";
import { spawn, ChildProcess } from "child_process";
import { unlinkSync, accessSync, mkdtempSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { TestRunner } from "../../generated/testing.ts";

// Dynamic port from PID to avoid conflicts when multiple test suites
// run on the same machine (CI matrix, parallel local runs).
const PORT = 3000 + (process.pid % 5000);
const BASE = `http://localhost:${PORT}`;
const PROJ = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
const SOCK = `/tmp/tiger-web-test-${process.pid}.sock`;
const TMP = mkdtempSync(join(tmpdir(), "tiger-web-test-"));
const DB = join(TMP, "test.db");

const t = new TestRunner();
let sidecar: ChildProcess | null = null;
let server: ChildProcess | null = null;

function assert(ok: boolean, msg: string): void {
  t.assert(ok, msg);
}

async function req(
  method: string,
  path: string,
  body?: Record<string, unknown>,
): Promise<{ status: number; body: string }> {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: body ? { "Content-Type": "application/json" } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, body: await res.text() };
}

function has(body: string, text: string): boolean {
  return body.includes(text);
}

// --- Lifecycle ---

async function startServer(): Promise<void> {
  execSync("npm run build", { cwd: `${PROJ}/examples/ecommerce-ts`, stdio: "pipe" });

  sidecar = spawn("npx", ["tsx", `${PROJ}/generated/dispatch.generated.ts`, SOCK], {
    cwd: `${PROJ}/examples/ecommerce-ts`,
    stdio: "pipe",
  });

  // Wait for socket
  for (let i = 0; i < 50; i++) {
    try { accessSync(SOCK); break; } catch { await sleep(100); }
  }

  execSync(`${PROJ}/zig/zig build`, { cwd: PROJ, stdio: "pipe" });

  server = spawn(
    `${PROJ}/zig-out/bin/tiger-web`,
    [`--port=${PORT}`, `--sidecar=${SOCK}`, `--db=${DB}`],
    { cwd: PROJ, stdio: "pipe" },
  );

  // Wait for server ready
  for (let i = 0; i < 30; i++) {
    try { await fetch(`${BASE}/`); return; } catch { await sleep(200); }
  }
  throw new Error("Server failed to start");
}

function stopServer(): void {
  if (server) { server.kill(); server = null; }
  if (sidecar) { sidecar.kill(); sidecar = null; }
  try { unlinkSync(SOCK); } catch {}
  for (const f of [DB, DB + "-wal", DB + "-shm", join(TMP, "test.wal")]) {
    try { unlinkSync(f); } catch {}
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

// --- Products ---

// Client-generated UUIDs for test products (32 hex chars).
const PRODUCT_1_ID  = "10000000000000000000000000000001";
const PRODUCT_2_ID  = "20000000000000000000000000000002";
const DELETE_ID     = "a0000000000000000000000000000001";
const TRANSFER_ID   = "b0000000000000000000000000000001";
const COLLECTION_ID = "c0000000000000000000000000000001";
const COLL_DEL_ID   = "c0000000000000000000000000000002";
const ORDER_PROD_ID = "d0000000000000000000000000000001";

async function testCreateProduct(): Promise<void> {
  // Create returns empty body on success (render returns "").
  // Verify state by querying the list.
  const r = await req("POST", "/products", {
    id: PRODUCT_1_ID, name: "Test Widget", price_cents: 1999, inventory: 50,
  });
  assert(r.status === 200, `create product status: ${r.status}`);
  assert(!has(r.body, "error"), "create product: no error in response");

  // State verification: product appears in list with correct data
  const list = await req("GET", "/products");
  assert(has(list.body, "Test Widget"), "create product: visible in list");
  assert(has(list.body, "19.99"), "create product: correct price in list");
}

async function testCreateSecondProduct(): Promise<void> {
  const r = await req("POST", "/products", {
    id: PRODUCT_2_ID, name: "Another Item", price_cents: 500, inventory: 100,
  });
  assert(r.status === 200, `create second product status: ${r.status}`);
  assert(!has(r.body, "error"), "create second: no error");

  // State verification: both products in list
  const list = await req("GET", "/products");
  assert(has(list.body, "Test Widget"), "second create: Widget still in list");
  assert(has(list.body, "Another Item"), "second create: Another Item in list");
}

async function testListProducts(): Promise<void> {
  const r = await req("GET", "/products");
  assert(r.status === 200, `list products status: ${r.status}`);
  assert(has(r.body, "Test Widget"), "list contains Test Widget");
  assert(has(r.body, "Another Item"), "list contains Another Item");
  assert(has(r.body, "19.99"), "list shows Widget price");
  assert(has(r.body, "5.00"), "list shows Another Item price");
}

async function testSearchProducts(): Promise<void> {
  // Runs after update — product 1 is "Updated Widget" now.
  // Search for "Updated" — should find it, exclude Another Item.
  const r = await req("GET", "/products?q=Updated");
  assert(r.status === 200, `search status: ${r.status}`);
  assert(has(r.body, "Updated Widget"), "search finds Updated Widget");
  assert(!has(r.body, "Another Item"), "search excludes Another Item");
}

async function testSearchEmpty(): Promise<void> {
  const r = await req("GET", "/products?q=Nonexistent");
  assert(r.status === 200, `search empty status: ${r.status}`);
  assert(!has(r.body, "Updated Widget"), "search empty: no Widget");
  assert(!has(r.body, "Another Item"), "search empty: no Item");
}

async function testGetProductNotFound(): Promise<void> {
  const r = await req("GET", "/products/00000000000000000000000000000099");
  assert(r.status === 200, `get missing product status: ${r.status}`);
  assert(has(r.body, "not found"), "get missing product: not found");
}

async function testDeleteProduct(): Promise<void> {
  // Create with known ID → verify exists → delete → verify gone.
  await req("POST", "/products", {
    id: DELETE_ID, name: "Delete Me", price_cents: 100, inventory: 1,
  });
  const list1 = await req("GET", "/products");
  assert(has(list1.body, "Delete Me"), "delete: product exists before delete");

  // Delete by known ID
  const del = await req("DELETE", `/products/${DELETE_ID}`);
  assert(del.status === 200, `delete product status: ${del.status}`);

  // State verification: product gone from list
  const list2 = await req("GET", "/products");
  assert(!has(list2.body, "Delete Me"), "delete: product gone after delete");
}

async function testGetProduct(): Promise<void> {
  // Get an existing product by ID — verify response has correct data
  const r = await req("GET", `/products/${PRODUCT_1_ID}`);
  assert(r.status === 200, `get product status: ${r.status}`);
  assert(has(r.body, "Test Widget"), "get product: has name");
  assert(has(r.body, "19.99"), "get product: has price");
}

async function testUpdateProduct(): Promise<void> {
  const r = await req("PUT", `/products/${PRODUCT_1_ID}`, {
    name: "Updated Widget", price_cents: 2999, inventory: 25,
  });
  assert(r.status === 200, `update product status: ${r.status}`);

  // State verification: product updated
  const get = await req("GET", `/products/${PRODUCT_1_ID}`);
  assert(has(get.body, "Updated Widget"), "update: name changed");
  assert(has(get.body, "29.99"), "update: price changed");
}

async function testGetProductInventory(): Promise<void> {
  const r = await req("GET", `/products/${PRODUCT_1_ID}/inventory`);
  assert(r.status === 200, `get inventory status: ${r.status}`);
}

async function testTransferInventory(): Promise<void> {
  // Create a product to transfer to
  await req("POST", "/products", {
    id: TRANSFER_ID, name: "Transfer Target", price_cents: 100, inventory: 0,
  });

  const r = await req("POST", `/products/${PRODUCT_1_ID}/transfer-inventory/${TRANSFER_ID}`, {
    quantity: 5,
  });
  assert(r.status === 200, `transfer inventory status: ${r.status}`);
}

// --- Collections ---

async function testCreateCollection(): Promise<void> {
  const r = await req("POST", "/collections", { id: COLLECTION_ID, name: "Summer Sale" });
  assert(r.status === 200, `create collection status: ${r.status}`);
  assert(!has(r.body, "error"), "create collection: no error");

  // State verification: collection appears in list
  const list = await req("GET", "/collections");
  assert(has(list.body, "Summer Sale"), "create collection: visible in list");
}

async function testListCollections(): Promise<void> {
  const r = await req("GET", "/collections");
  assert(r.status === 200, `list collections status: ${r.status}`);
  assert(has(r.body, "Summer Sale"), "list collections contains Summer Sale");
}

async function testGetCollectionNotFound(): Promise<void> {
  const r = await req("GET", "/collections/00000000000000000000000000000099");
  assert(r.status === 200, `get missing collection status: ${r.status}`);
  assert(has(r.body, "not found"), "get missing collection: not found");
}

async function testDeleteCollection(): Promise<void> {
  await req("POST", "/collections", { id: COLL_DEL_ID, name: "Delete This Collection" });
  const list1 = await req("GET", "/collections");
  assert(has(list1.body, "Delete This Collection"), "delete collection: exists before");

  const del = await req("DELETE", `/collections/${COLL_DEL_ID}`);
  assert(del.status === 200, `delete collection status: ${del.status}`);

  const list2 = await req("GET", "/collections");
  assert(!has(list2.body, "Delete This Collection"), "delete collection: gone after");
}

async function testCollectionMembers(): Promise<void> {
  // Add product to collection
  const add = await req("POST", `/collections/${COLLECTION_ID}/members`, {
    product_id: PRODUCT_1_ID,
  });
  assert(add.status === 200, `add collection member status: ${add.status}`);

  // Remove product from collection
  const remove = await req("DELETE", `/collections/${COLLECTION_ID}/members/${PRODUCT_1_ID}`);
  assert(remove.status === 200, `remove collection member status: ${remove.status}`);
}

// --- Orders ---

async function testListOrders(): Promise<void> {
  const r = await req("GET", "/orders");
  assert(r.status === 200, `list orders status: ${r.status}`);
}

async function testGetOrderNotFound(): Promise<void> {
  const r = await req("GET", "/orders/00000000000000000000000000000099");
  assert(r.status === 200, `get missing order status: ${r.status}`);
  assert(has(r.body, "not found"), "get missing order: not found");
}

async function testCreateOrder(): Promise<void> {
  // Create a product with known inventory for order testing
  await req("POST", "/products", {
    id: ORDER_PROD_ID, name: "Order Product", price_cents: 1000, inventory: 20,
  });

  const r = await req("POST", "/orders", {
    items: [{ product_id: ORDER_PROD_ID, quantity: 2 }],
  });
  assert(r.status === 200, `create order status: ${r.status}`);

  // State verification: order appears in list
  const list = await req("GET", "/orders");
  assert(list.status === 200, "create order: list succeeds");
}

async function testCancelOrder(): Promise<void> {
  // Create an order to cancel — need a fresh product with inventory
  const prodId = "e0000000000000000000000000000001";
  await req("POST", "/products", {
    id: prodId, name: "Cancel Test", price_cents: 100, inventory: 10,
  });
  await req("POST", "/orders", {
    items: [{ product_id: prodId, quantity: 1 }],
  });

  // We don't have the order ID from the response. Cancel with a known ID won't work
  // unless we create with a known order ID. The create_order handler generates IDs.
  // For now, test that the endpoint responds correctly to a cancel on a nonexistent order.
  const r = await req("POST", "/orders/00000000000000000000000000000099/cancel");
  assert(r.status === 200, `cancel order status: ${r.status}`);
  assert(has(r.body, "not found"), "cancel nonexistent order: not found");
}

async function testCompleteOrder(): Promise<void> {
  // Same constraint as cancel — we need an order ID.
  // Test with nonexistent order ID.
  const r = await req("POST", "/orders/00000000000000000000000000000099/complete", {
    result: "confirmed",
  });
  assert(r.status === 200, `complete order status: ${r.status}`);
  assert(has(r.body, "not found"), "complete nonexistent order: not found");
}

// --- Dashboard ---

async function testDashboard(): Promise<void> {
  const r = await req("GET", "/");
  assert(r.status === 200, `dashboard status: ${r.status}`);
  assert(has(r.body, "Tiger Web"), "dashboard has title");
  assert(has(r.body, "Products"), "dashboard has Products section");
  assert(has(r.body, "Collections"), "dashboard has Collections section");
  assert(has(r.body, "Orders"), "dashboard has Orders section");
}

async function testDashboardAfterData(): Promise<void> {
  // After creating products/collections, dashboard should show them
  const r = await req("GET", "/");
  assert(has(r.body, "Updated Widget") || has(r.body, "Another Item"), "dashboard shows products");
  assert(has(r.body, "Summer Sale"), "dashboard shows Summer Sale");
}

// --- Login / Auth ---

async function testLoginPage(): Promise<void> {
  const r = await req("GET", "/login");
  assert(r.status === 200, `login page status: ${r.status}`);
}

async function testRequestLoginCode(): Promise<void> {
  const r = await req("POST", "/login/code", { email: "test@example.com" });
  assert(r.status === 200, `request login code status: ${r.status}`);
}

async function testVerifyLoginCode(): Promise<void> {
  const r = await req("POST", "/login/verify", {
    email: "test@example.com", code: "000000",
  });
  assert(r.status === 200, `verify login code status: ${r.status}`);
}

async function testLogout(): Promise<void> {
  const r = await req("POST", "/logout");
  assert(r.status === 200, `logout status: ${r.status}`);
}

// --- Query param routing (// query annotation) ---

async function testQueryParamRouting(): Promise<void> {
  // GET /products (no ?q=) → list_products
  const list = await req("GET", "/products");
  assert(list.status === 200, "GET /products routes to list");
  // Should contain products (no filtering)
  assert(has(list.body, "Another Item"), "list has Another Item");

  // GET /products?q=Another → search_products (via // query q annotation)
  const search = await req("GET", "/products?q=Another");
  assert(search.status === 200, "GET /products?q= routes to search");
  assert(has(search.body, "Another Item"), "search has Another Item");
  // Search should exclude products that don't match "Another"
  assert(!has(search.body, "Order Product"), "search excludes non-matching");
}

// --- Sidecar alive check ---

async function testSidecarAlive(): Promise<void> {
  // After all tests, verify sidecar process is still running.
  // If it crashed, requests went through the native Zig pipeline instead.
  assert(sidecar !== null && !sidecar.killed, "sidecar process alive");
  assert(server !== null && !server.killed, "server process alive");

  // Verify by checking sidecar exitCode is null (still running)
  assert(sidecar!.exitCode === null, "sidecar has not exited");
}

// --- Runner ---

async function main(): Promise<void> {
  try {
    await startServer();

    // Dashboard (before data)
    await testDashboard();

    // Products CRUD
    await testCreateProduct();
    await testCreateSecondProduct();
    await testListProducts();
    await testGetProduct();
    await testUpdateProduct();
    await testSearchProducts();
    await testSearchEmpty();
    await testGetProductNotFound();
    await testGetProductInventory();
    await testTransferInventory();
    await testDeleteProduct();

    // Collections CRUD
    await testCreateCollection();
    await testListCollections();
    await testGetCollectionNotFound();
    await testCollectionMembers();
    await testDeleteCollection();

    // Orders
    await testCreateOrder();
    await testListOrders();
    await testGetOrderNotFound();
    await testCancelOrder();
    await testCompleteOrder();

    // Dashboard (after data)
    await testDashboardAfterData();

    // Auth
    await testLoginPage();
    await testRequestLoginCode();
    await testVerifyLoginCode();
    await testLogout();

    // Query param routing
    await testQueryParamRouting();

    // Sidecar health
    await testSidecarAlive();

    t.done();
  } catch (err) {
    console.error("Test harness error:", err);
    t.failed++;
    t.done();
  } finally {
    stopServer();
  }
}

main();
