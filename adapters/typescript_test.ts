// Test for the TypeScript adapter.
// Run: npx tsx adapters/typescript_test.ts

import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync } from "fs";
import { execSync } from "child_process";

if (!existsSync("generated/types.generated.ts")) {
  console.error("error: generated/types.generated.ts not found. Run `zig build codegen` first.");
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

// Copy types.generated.ts to the test directory (adapter imports it).
const typesContent = readFileSync("generated/types.generated.ts", "utf-8");
writeFileSync(`${testDir}/generated/types.generated.ts`, typesContent);

// Test source file with annotated handlers.
writeFileSync(
  `${testDir}/ts/products.ts`,
  `
// [translate] .create_product
export function translateCreateProduct(req: any) { return req; }

// [execute] .create_product
export function executeCreateProduct(cache: any, body: any) { return { status: 'ok', writes: [] }; }

// [render] .create_product
export function renderCreateProduct(op: string, status: string, result: any) { return '<div>ok</div>'; }

// [translate] .get_product
export function translateGetProduct(req: any) { return req; }

// [execute] .get_product
export function executeGetProduct(cache: any) { return { status: 'ok', writes: [] }; }

// [render] .get_product
export function renderGetProduct(op: string, status: string, result: any) { return '<div>product</div>'; }
`
);

// Test manifest matching the source file.
const manifest = {
  annotations: [
    { phase: "translate", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 2 },
    { phase: "execute", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 5 },
    { phase: "render", operation: "create_product", file: `${testDir}/ts/products.ts`, line: 8 },
    { phase: "translate", operation: "get_product", file: `${testDir}/ts/products.ts`, line: 11 },
    { phase: "execute", operation: "get_product", file: `${testDir}/ts/products.ts`, line: 14 },
    { phase: "render", operation: "get_product", file: `${testDir}/ts/products.ts`, line: 17 },
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

// Test: file exists and is non-empty.
assert(dispatch.length > 0, "dispatch file is non-empty");

// Test: imports the annotated functions.
assert(dispatch.includes("translateCreateProduct"), "imports translateCreateProduct");
assert(dispatch.includes("executeCreateProduct"), "imports executeCreateProduct");
assert(dispatch.includes("renderCreateProduct"), "imports renderCreateProduct");
assert(dispatch.includes("translateGetProduct"), "imports translateGetProduct");
assert(dispatch.includes("executeGetProduct"), "imports executeGetProduct");
assert(dispatch.includes("renderGetProduct"), "imports renderGetProduct");

// Test: dispatch tables contain the operations.
assert(dispatch.includes("'create_product': translateCreateProduct"), "translate table has create_product");
assert(dispatch.includes("'get_product': translateGetProduct"), "translate table has get_product");
assert(dispatch.includes("'create_product': executeCreateProduct"), "execute table has create_product");
assert(dispatch.includes("'get_product': executeGetProduct"), "execute table has get_product");
assert(dispatch.includes("'create_product': renderCreateProduct"), "render table has create_product");
assert(dispatch.includes("'get_product': renderGetProduct"), "render table has get_product");

// Test: no default/fallback handlers.
assert(!dispatch.includes("? handler"), "no ternary fallback in dispatch");
assert(!dispatch.includes(": { status:"), "no inline default response");

// Test: dispatch has the socket server.
assert(dispatch.includes("net.createServer"), "has socket server");
assert(dispatch.includes("TagValues.translate"), "dispatches on translate tag");
assert(dispatch.includes("TagValues.execute_render"), "dispatches on execute_render tag");

// Test: direct handler calls (no optional chaining).
assert(dispatch.includes("handler(req)"), "direct translate call");
assert(dispatch.includes("executeHandlers[req.operation](req.cache, typedBody)"), "direct execute call");
assert(dispatch.includes("renderHandlers[req.operation](execResult.status, req.cache)"), "direct render call");

// Cleanup.
rmSync(testDir, { recursive: true, force: true });

// Summary.
console.log(`${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
