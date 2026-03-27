# Decision: Annotation-driven routing — one syntax for all languages

## Status: Adopted (2026-03-26)

## Context

Route metadata must be declared per handler. With multiple sidecar
languages (TypeScript, future Python/Go), the declaration mechanism
must be language-agnostic.

## Decision

Every handler — Zig, TypeScript, Python — declares its route with
comment annotations:

```
// [route] .get_product
// match GET /products/:id
// query q                    (optional — extracts query params)
```

The annotation scanner parses these from any language (`//`, `#`, `--`
comment prefixes). Two outputs:
- `generated/manifest.json` → TypeScript adapter → `dispatch.generated.ts`
- `generated/routes.generated.zig` → Zig pipeline reads at comptime

Handlers receive pre-extracted params: `route(params, body)`. The
framework handles all URL parsing — path segments, query strings.
Handlers don't import match_route or parse query strings manually.

## `// query` annotations

Query params are extracted into `RouteParams` alongside path params.
The handler doesn't know whether a param came from the path or the
query string:

```zig
// match GET /products
// query q
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    const q = params.get("q") orelse return null;
```

This solves shared-pattern disambiguation (GET /products: list vs
search) without URL hacks (/products/search) or path param shims.

## Generated routes table

`routes.generated.zig` includes `@import` for handler modules:
```zig
.{ .operation = .get_product, .method = .get, .pattern = "/products/:id",
   .query_params = &.{}, .handler = @import("../handlers/get_product.zig") },
```

Comptime assertions verify:
- Every Operation has a route entry (missing annotation = compile error)
- Path params + query params fit RouteParams (overflow = compile error)

Shared patterns are allowed (scanner warns, translate() asserts at
runtime no two handlers accept the same request).

## Route specificity

Routes sorted by specificity: literal segments before param segments,
longer patterns before shorter. `/products/search` is tried before
`/products/:id`. Deterministic regardless of filesystem order.

## Why not comptime constants on handlers

Previously Zig handlers had `pub const route_method`/`route_pattern`.
These were redundant with annotations, required cross-validation, and
weren't available for non-Zig languages. One source of truth (annotations)
eliminates the mismatch class of bugs.

The performance difference is unmeasurable — pattern matching is not
the bottleneck in any HTTP server. One code path for all languages,
one place to test, is worth more than theoretical zero-overhead routing.

## Consequences

- Scanner must run before compilation (generated files committed, CI
  freshness check: `zig build scan` + `git diff --exit-code generated/`)
- New handler: create file with annotations, run scanner, handler appears
- New language adapter: read manifest.json, implement matchRoute, verify
  against route_match_vectors.json (cross-language test vectors)
- Handlers tuple in app.zig stays for PrefetchCache type construction
  (separate concern from routing, Zig deduplicates @import)
