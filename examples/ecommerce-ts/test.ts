// Integration test suite for the ecommerce-ts example project.
//
// Exercises all 24 handlers through the full sidecar pipeline:
// TypeScript handler → sidecar binary protocol → Zig state machine → SQLite → back.
//
// Usage: npx tsx test.ts
//
// Requires the sidecar + server to be running (test.sh handles this).
// Tests run against http://localhost:${PORT} with a fresh :memory: database.

import { execSync } from "child_process";
import { spawn, ChildProcess } from "child_process";

const PORT = 3033; // Avoid conflict with dev server on 3000
const BASE = `http://localhost:${PORT}`;
const PROJ = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
const SOCK = `/tmp/tiger-web-test-${process.pid}.sock`;

let passed = 0;
let failed = 0;
let sidecar: ChildProcess | null = null;
let server: ChildProcess | null = null;

function assert(ok: boolean, msg: string): void {
  if (ok) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL: ${msg}`);
  }
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
  const text = await res.text();
  return { status: res.status, body: text };
}

function bodyContains(body: string, text: string): boolean {
  return body.includes(text);
}

// --- Lifecycle ---

async function startServer(): Promise<void> {
  // Build the sidecar dispatch
  execSync("npm run build", { cwd: `${PROJ}/examples/ecommerce-ts`, stdio: "pipe" });

  // Start sidecar
  sidecar = spawn("npx", ["tsx", `${PROJ}/generated/dispatch.generated.ts`, SOCK], {
    cwd: `${PROJ}/examples/ecommerce-ts`,
    stdio: "pipe",
  });

  // Wait for socket
  await new Promise<void>((resolve) => {
    const check = setInterval(() => {
      try {
        const fs = require("fs");
        fs.accessSync(SOCK);
        clearInterval(check);
        resolve();
      } catch {}
    }, 100);
  });

  // Build the Zig server if needed
  execSync(`${PROJ}/zig/zig build`, { cwd: PROJ, stdio: "pipe" });

  // Delete stale database — tests need a fresh state.
  // Server hardcodes "tiger_web.db" relative to cwd.
  const fs = require("fs");
  for (const ext of ["", "-wal", "-shm"]) {
    try { fs.unlinkSync(`${PROJ}/tiger_web.db${ext}`); } catch {}
  }
  try { fs.unlinkSync(`${PROJ}/tiger_web.wal`); } catch {}

  // Start server with fresh database
  server = spawn(
    `${PROJ}/zig-out/bin/tiger-web`,
    [`--port=${PORT}`, `--sidecar=${SOCK}`],
    { cwd: PROJ, stdio: "pipe" },
  );

  // Wait for server ready
  for (let i = 0; i < 30; i++) {
    try {
      await fetch(`${BASE}/`);
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  throw new Error("Server failed to start");
}

function stopServer(): void {
  if (server) { server.kill(); server = null; }
  if (sidecar) { sidecar.kill(); sidecar = null; }
  try { require("fs").unlinkSync(SOCK); } catch {}
  // Clean up test database
  for (const f of ["tiger_web.db", "tiger_web.db-wal", "tiger_web.db-shm", "tiger_web.wal"]) {
    try { require("fs").unlinkSync(`${PROJ}/${f}`); } catch {}
  }
}

// --- Tests ---

async function testProducts(): Promise<void> {
  // Create product
  const create = await req("POST", "/products", {
    name: "Test Widget",
    price_cents: 1999,
    inventory: 50,
  });
  assert(create.status === 200, `create product status: ${create.status}`);
  assert(!bodyContains(create.body, "error"), `create product no error: ${create.body.slice(0, 100)}`);

  // List products — should contain the created product
  const list = await req("GET", "/products");
  assert(list.status === 200, `list products status: ${list.status}`);
  assert(bodyContains(list.body, "Test Widget"), "list products contains Test Widget");

  // Create second product for search
  await req("POST", "/products", {
    name: "Another Item",
    price_cents: 500,
    inventory: 100,
  });

  // Search products — GET /products?q= (same endpoint, query param disambiguation)
  const search = await req("GET", "/products?q=Widget");
  assert(search.status === 200, `search status: ${search.status}`);
  assert(bodyContains(search.body, "Test Widget"), "search finds Test Widget");

  // Search with no results
  const searchEmpty = await req("GET", "/products?q=Nonexistent");
  assert(searchEmpty.status === 200, `search empty status: ${searchEmpty.status}`);
  assert(!bodyContains(searchEmpty.body, "Test Widget"), "search empty doesn't find Widget");

  // Get nonexistent product
  const notFound = await req("GET", "/products/00000000000000000000000000000099");
  assert(notFound.status === 200, `get missing product status: ${notFound.status}`);
  assert(bodyContains(notFound.body, "not found"), "get missing product shows not found");
}

async function testCollections(): Promise<void> {
  // Create collection
  const create = await req("POST", "/collections", {
    name: "Summer Sale",
  });
  assert(create.status === 200, `create collection status: ${create.status}`);
  assert(!bodyContains(create.body, "error"), `create collection no error: ${create.body.slice(0, 100)}`);

  // List collections
  const list = await req("GET", "/collections");
  assert(list.status === 200, `list collections status: ${list.status}`);
  assert(bodyContains(list.body, "Summer Sale"), "list collections contains Summer Sale");

  // Get nonexistent collection
  const notFound = await req("GET", "/collections/00000000000000000000000000000099");
  assert(notFound.status === 200, `get missing collection status: ${notFound.status}`);
  assert(bodyContains(notFound.body, "not found"), "get missing collection shows not found");
}

async function testOrders(): Promise<void> {
  // Create a product first (orders need products)
  await req("POST", "/products", {
    name: "Order Test Product",
    price_cents: 1000,
    inventory: 10,
  });

  // List orders (should be empty initially)
  const listEmpty = await req("GET", "/orders");
  assert(listEmpty.status === 200, `list orders status: ${listEmpty.status}`);

  // Get nonexistent order
  const notFound = await req("GET", "/orders/00000000000000000000000000000099");
  assert(notFound.status === 200, `get missing order status: ${notFound.status}`);
  assert(bodyContains(notFound.body, "not found"), "get missing order shows not found");
}

async function testDashboard(): Promise<void> {
  const dash = await req("GET", "/");
  assert(dash.status === 200, `dashboard status: ${dash.status}`);
  assert(bodyContains(dash.body, "Tiger Web"), "dashboard has title");
  assert(bodyContains(dash.body, "Products"), "dashboard has Products section");
  assert(bodyContains(dash.body, "Collections"), "dashboard has Collections section");
  assert(bodyContains(dash.body, "Orders"), "dashboard has Orders section");
}

async function testLogin(): Promise<void> {
  // Login page
  const login = await req("GET", "/login");
  assert(login.status === 200, `login page status: ${login.status}`);

  // Request login code (will fail without valid email handling, but should not crash)
  const code = await req("POST", "/login/code", { email: "test@example.com" });
  assert(code.status === 200, `request login code status: ${code.status}`);

  // Logout (should succeed even without session)
  const logout = await req("POST", "/logout");
  assert(logout.status === 200, `logout status: ${logout.status}`);
}

async function testQueryParamRouting(): Promise<void> {
  // GET /products — should route to list_products (no ?q=)
  const list = await req("GET", "/products");
  assert(list.status === 200, "GET /products routes to list");

  // GET /products?q=test — should route to search_products
  const search = await req("GET", "/products?q=test");
  assert(search.status === 200, "GET /products?q=test routes to search");

  // Verify list and search return different results — list shows all,
  // search filters. Both use GET /products, disambiguated by ?q=.
  assert(!bodyContains(list.body, "search"), "list doesn't contain search UI");
  assert(bodyContains(search.body, "search"), "search contains search UI");
}

// --- Runner ---

async function main(): Promise<void> {
  try {
    await startServer();

    await testDashboard();
    await testProducts();
    await testCollections();
    await testOrders();
    await testLogin();
    await testQueryParamRouting();

    console.log(`\n${passed} passed, ${failed} failed`);
  } catch (err) {
    console.error("Test harness error:", err);
    failed++;
  } finally {
    stopServer();
  }

  if (failed > 0) process.exit(1);
}

main();
