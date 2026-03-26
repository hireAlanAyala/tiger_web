// Test for the TypeScript adapter — verifies dispatch.generated.ts format.
// Run: npx tsx adapters/typescript_test.ts
//
// Creates a temp handler file with annotations, runs the adapter, and
// verifies the generated dispatch has the correct structure.

import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "fs";
import { execSync } from "child_process";

if (!existsSync("generated/types.generated.ts")) {
  console.error("error: generated/types.generated.ts not found.");
  process.exit(1);
}

const testDir = "/tmp/tiger-adapter-test";
let passed = 0;
let failed = 0;

function assert(condition: boolean, msg: string) {
  if (!condition) {
    console.error(`FAIL: ${msg}`);
    failed++;
  } else {
    passed++;
  }
}

// Setup: create temp directory with test source files + manifest.
rmSync(testDir, { recursive: true, force: true });
mkdirSync(`${testDir}/ts`, { recursive: true });
mkdirSync(`${testDir}/generated`, { recursive: true });

// Copy framework files the adapter needs.
writeFileSync(`${testDir}/generated/types.generated.ts`,
  readFileSync("generated/types.generated.ts", "utf-8"));
writeFileSync(`${testDir}/generated/serde.ts`,
  readFileSync("generated/serde.ts", "utf-8"));
writeFileSync(`${testDir}/generated/routing.ts`,
  readFileSync("generated/routing.ts", "utf-8"));
writeFileSync(`${testDir}/generated/method_vectors.json`,
  readFileSync("generated/method_vectors.json", "utf-8"));

// Test handler file with all 4 phases.
writeFileSync(
  `${testDir}/ts/products.ts`,
  `
import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, WriteDb, RenderContext } from "tiger-web";

// [route] .create_product
// match POST /products
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "create_product", id: "0".repeat(32), body: {} };
}

// [prefetch] .create_product
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  return {};
}

// [handle] .create_product
export function handle(ctx: HandleContext, db: WriteDb): string {
  return "ok";
}

// [render] .create_product
export function render(ctx: RenderContext): string {
  return "<div>ok</div>";
}
`
);

// Second handler to test multiple operations.
writeFileSync(
  `${testDir}/ts/get_product.ts`,
  `
import type { RouteRequest, RouteResult, PrefetchMessage, PrefetchDb, HandleContext, RenderContext } from "tiger-web";

// [route] .get_product
// match GET /products/:id
export function route(req: RouteRequest): RouteResult | null {
  return { operation: "get_product", id: req.params.id };
}

// [prefetch] .get_product
export function prefetch(msg: PrefetchMessage, db: PrefetchDb) {
  const product = db.query("SELECT * FROM products WHERE id = ?1", msg.id);
  return { product };
}

// [handle] .get_product
export function handle(ctx: HandleContext): string {
  if (!ctx.prefetched.product) return "not_found";
  return "ok";
}

// [render] .get_product
export function render(ctx: RenderContext): string {
  return "<div>product</div>";
}
`
);

// Manifest with route_match (matching real scanner output).
const manifest = {
  annotations: [
    { phase: "translate", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 4, has_body: true,
      route_match: { method: "post", pattern: "/products" } },
    { phase: "prefetch", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 10, has_body: true },
    { phase: "execute", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 15, has_body: true },
    { phase: "render", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 20, has_body: true },
    { phase: "translate", operation: "get_product", file: `${testDir}/ts/get_product.ts`, line: 4, has_body: true,
      route_match: { method: "get", pattern: "/products/:id" } },
    { phase: "prefetch", operation: "get_product", file: `${testDir}/ts/get_product.ts`, line: 10, has_body: true },
    { phase: "execute", operation: "get_product", file: `${testDir}/ts/get_product.ts`, line: 16, has_body: true },
    { phase: "render", operation: "get_product", file: `${testDir}/ts/get_product.ts`, line: 21, has_body: true },
  ],
};

writeFileSync(`${testDir}/manifest.json`, JSON.stringify(manifest, null, 2));

// Run the adapter.
const outputPath = `${testDir}/generated/dispatch.generated.ts`;
try {
  execSync(
    `npx tsx adapters/typescript.ts ${testDir}/manifest.json ${outputPath}`,
    { stdio: "pipe" }
  );
} catch (e: any) {
  console.error("Adapter failed:", e.stderr?.toString());
  process.exit(1);
}

// Verify the dispatch file was generated.
const dispatch = readFileSync(outputPath, "utf-8");

// --- Structure tests ---

assert(dispatch.length > 0, "dispatch file is non-empty");

// Namespace imports for each handler file.
assert(dispatch.includes("import * as createProduct"), "imports createProduct namespace");
assert(dispatch.includes("import * as getProduct"), "imports getProduct namespace");

// Dispatch tables — 4 phases, keyed by operation.
assert(dispatch.includes("routeHandlers"), "has routeHandlers table");
assert(dispatch.includes("prefetchHandlers"), "has prefetchHandlers table");
assert(dispatch.includes("handleHandlers"), "has handleHandlers table");
assert(dispatch.includes("renderHandlers"), "has renderHandlers table");

// Route table from match directives.
assert(dispatch.includes("routeTable"), "has routeTable");
assert(dispatch.includes("'create_product'"), "route table has create_product");
assert(dispatch.includes("'get_product'"), "route table has get_product");
assert(dispatch.includes("pattern: '/products'"), "route table has /products pattern");
assert(dispatch.includes("pattern: '/products/:id'"), "route table has /products/:id pattern");
assert(dispatch.includes("method: 'post'"), "route table has post method");
assert(dispatch.includes("method: 'get'"), "route table has get method");

// Route matching — imported from shared module.
assert(dispatch.includes("import { matchRoute }"), "imports matchRoute from routing.ts");
assert(dispatch.includes("matchRoute(path, entry.pattern)"), "calls matchRoute with pattern");

// Method enum from cross-language contract.
assert(dispatch.includes("['get','put','post','delete']") ||
       dispatch.includes('["get","put","post","delete"]'), "method enum from vectors");

// Binary protocol.
assert(dispatch.includes("net.createServer"), "has socket server");
assert(dispatch.includes("MessageTag.route_request"), "dispatches on route_request tag");
assert(dispatch.includes("MessageTag.prefetch_results"), "dispatches on prefetch_results tag");
assert(dispatch.includes("MessageTag.render_results"), "dispatches on render_results tag");

// Dispatch resilience — handler calls wrapped in try/catch.
assert(dispatch.includes("route error:"), "try/catch on route handler");
assert(dispatch.includes("prefetch error:"), "try/catch on prefetch handler");
assert(dispatch.includes("handle error:"), "try/catch on handle handler");
assert(dispatch.includes("render error:"), "try/catch on render handler");
assert(dispatch.includes('"storage_error"'), "handle catch returns storage_error");
assert(dispatch.includes("Internal error"), "render catch returns error HTML");

// Handler function references in dispatch tables.
assert(dispatch.includes("createProduct.route"), "routeHandlers references createProduct.route");
assert(dispatch.includes("getProduct.route"), "routeHandlers references getProduct.route");
assert(dispatch.includes("createProduct.handle"), "handleHandlers references createProduct.handle");
assert(dispatch.includes("createProduct.render"), "renderHandlers references createProduct.render");

// Cleanup.
rmSync(testDir, { recursive: true, force: true });

// Summary.
console.log(`${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
