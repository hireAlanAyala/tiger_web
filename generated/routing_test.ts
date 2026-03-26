// Cross-language route matching test — verifies TypeScript matchRoute()
// against shared test vectors from framework/parse.zig.
//
// Usage: npx tsx generated/routing_test.ts
//
// If this fails, the TypeScript matchRoute() diverges from Zig's match_route().

import { matchRoute } from "./routing.ts";
import { readFileSync } from "fs";

const vectors = JSON.parse(
  readFileSync(new URL("./route_match_vectors.json", import.meta.url), "utf-8"),
);

let passed = 0;
let failed = 0;

function assert(ok: boolean, msg: string): void {
  if (ok) {
    passed++;
  } else {
    failed++;
    console.error("FAIL:", msg);
  }
}

// Positive cases: path + pattern should match with expected params.
for (const v of vectors.match) {
  const result = matchRoute(v.path, v.pattern);
  if (result === null) {
    assert(false, `expected match: path=${v.path} pattern=${v.pattern}`);
    continue;
  }

  // Check all expected params are present and correct.
  const expectedKeys = Object.keys(v.params);
  const gotKeys = Object.keys(result);

  assert(
    expectedKeys.length === gotKeys.length,
    `param count: path=${v.path} pattern=${v.pattern} expected=${expectedKeys.length} got=${gotKeys.length}`,
  );

  for (const key of expectedKeys) {
    assert(
      result[key] === v.params[key],
      `param ${key}: path=${v.path} pattern=${v.pattern} expected=${v.params[key]} got=${result[key]}`,
    );
  }
}

// Negative cases: path + pattern should NOT match.
for (const v of vectors.no_match) {
  const result = matchRoute(v.path, v.pattern);
  assert(
    result === null,
    `expected no match: path=${v.path} pattern=${v.pattern} reason=${v._reason}`,
  );
}

// Query string stripping: path with ?key=value should match pattern without it.
{
  const result = matchRoute("/products?q=widget", "/products");
  assert(result !== null, "query string: /products?q=widget should match /products");
}
{
  const result = matchRoute("/products/abc123?format=json", "/products/:id");
  assert(result !== null, "query string with param: should match");
  if (result) {
    assert(result.id === "abc123", "query string param extraction: id should be abc123, got " + result.id);
  }
}
{
  const result = matchRoute("/?", "/");
  assert(result !== null, "root with empty query string should match /");
}

console.log(`${passed} passed, ${failed} failed`);
if (failed > 0) process.exit(1);
