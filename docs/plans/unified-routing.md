# Plan: Unified Annotation Routing — One Source of Truth

## Status: Ready to implement

### History
1. Scanner was extended to emit `routes.generated.zig` from `// match` annotations
2. `app.zig translate()` was changed to use generated table, then reverted because
   `handler_for_operation()` couldn't handle shared method+pattern routes
3. `search_products` URL was changed to `/products/search`, then reverted because
   `GET /products?q=widget` is correct REST (filtering is the same endpoint)
4. Key insight: the generated file can `@import` handler modules directly — no need
   for a lookup function. TB confirmed this is how they do generated Zig files.
5. Second insight: don't maintain two code paths (constants + annotations) even if
   constants are "zero overhead." The performance difference is unmeasurable. One
   code path, one source of truth, one place to test.

## Design

**The annotation is the universal declaration.** Every handler — Zig, TypeScript,
Python — declares its route the same way:

```
// [route] .get_product
// match GET /products/:id
```

**The scanner generates both outputs:**
- `generated/manifest.json` → TypeScript/Python adapter → `dispatch.generated.ts`
- `generated/routes.generated.zig` → Zig pipeline reads at comptime

**The generated Zig file imports handler modules directly:**

```zig
pub const routes = [_]Route{
    .{ .operation = .get_product, .method = .get, .pattern = "/products/:id",
       .handler = @import("../handlers/get_product.zig") },
    .{ .operation = .create_product, .method = .post, .pattern = "/products",
       .handler = @import("../handlers/create_product.zig") },
};
```

`@import` at comptime resolves the handler module. No constants needed on the
handler. No operation declaration needed. The annotation is the only source of
truth.

**Shared patterns work:** `translate()` iterates all routes, calls each matching
handler's `route()`, asserts at most one accepts. `list_products` and
`search_products` both match `GET /products` — one checks for `?q=`, the other
rejects it. Handler-level disambiguation is valid REST design.

**The handlers tuple in `app.zig` becomes redundant.** The generated file IS the
handler registry. Adding a handler means: create the file with annotations, run
the scanner, the handler appears. No manual registration step.

## User-space changes to Zig handlers

Three lines deleted per handler, zero added. Signature simplified.

**Before:**
```zig
pub const route_method = t.http.Method.get;
pub const route_pattern = "/products/:id";

// [route] .get_product
// match GET /products/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    _ = method;
    if (t.match_route(raw_path, route_pattern) == null) return null;
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    // ... body validation ...
}
```

**After:**
```zig
// [route] .get_product
// match GET /products/:id
pub fn route(params: t.RouteParams, body: []const u8) ?t.Message {
    const id = t.stdx.parse_uuid(params.get("id") orelse return null) orelse return null;
    // ... body validation ...
}
```

- `route_method` deleted — framework matches method from annotation
- `route_pattern` deleted — framework matches pattern from annotation
- `match_route` call deleted — framework already matched, passes extracted params
- `method` param removed — framework verified method before calling
- `raw_path` param removed — framework extracted params, handler doesn't need raw path
- `params` param added — pre-extracted by framework, matches TypeScript `req.params`
- `body` stays — handler parses JSON body for POST/PUT payloads

## Implementation steps

### Step 1: Update `routes.generated.zig` emission

Add `@import` for each handler's file path:
```zig
.handler = @import("../handlers/get_product.zig"),
```

The scanner has the file path on every annotation. Emit it as a comptime import.
Verify relative paths resolve from `generated/` directory.

### Step 2: Rewrite `app.zig translate()`

```zig
const gen = @import("generated/routes.generated.zig");

pub fn translate(method: http.Method, path: []const u8, body: []const u8) ?Message {
    if (sidecar) |*client| return client.translate(method, path, body);

    const parse = @import("framework/parse.zig");

    var result: ?Message = null;
    inline for (gen.routes) |route| {
        if (method == route.method) {
            if (parse.match_route(path, route.pattern)) |params| {
                if (route.handler.route(params, body)) |msg| {
                    assert(result == null);
                    result = msg;
                }
            }
        }
    }
    return result;
}
```

No `handlers` tuple. No `handler_for_operation`. The generated routes
array has everything — operation, method, pattern, handler module.

### Step 3: Remove `handlers` tuple from `app.zig`

The generated routes table replaces it for routing. The prefetch/handle/render
dispatch (the `switch` on operation) also needs handler module access — either
keep the handlers tuple for that, or have the generated file export a
`handler_for_operation` lookup.

Check: does the prefetch/handle/render dispatch in app.zig also use the handlers
tuple? If yes, the generated file needs to cover those lookups too.

### Step 4: Update `route()` signature on all 24 Zig handlers

```zig
// Old: fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message
// New: fn route(params: t.RouteParams, body: []const u8) ?t.Message
```

For each handler:
- Delete `pub const route_method` and `pub const route_pattern`
- Delete `if (t.match_route(raw_path, route_pattern) == null) return null;`
- Change signature: remove `method`, `raw_path`, add `params`
- Update param access: `params.get("id")` already works (was doing this after match_route)

### Step 5: Update `build.zig` — scan before compile

```zig
const scan_step = b.addRunArtifact(scanner_exe);
scan_step.addArgs(&.{ "handlers/", "--routes-zig=generated/routes.generated.zig" });
exe.step.dependOn(&scan_step.step);
```

The scan must run before compilation because `generated/routes.generated.zig` is
`@import`ed by `app.zig`.

### Step 6: Update tests and other files that reference `route_method`/`route_pattern`

Grep for `route_method` and `route_pattern` across the codebase. Update sim tests,
state_machine_test, codec_fuzz if they reference these constants.

### Step 7: Update `prelude.zig`

- Export `RouteParams` (handlers need it for the new signature)
- Remove `match_route` re-export (handlers no longer call it directly)

## Verification

1. `zig build scan -- handlers/` generates both manifest and routes.generated.zig
2. `zig build` compiles with generated routes — all comptime assertions pass
3. `zig build test` — sim tests pass
4. `zig build unit-test` — all pass
5. `zig build fuzz -- smoke` — all fuzzers pass
6. Sidecar end-to-end — TypeScript handlers still route correctly
7. No handler file has `route_method` or `route_pattern`

## Files to modify

| File | Change |
|---|---|
| `annotation_scanner.zig` | Emit `@import` in routes.generated.zig |
| `app.zig` | Rewrite translate(), remove handlers tuple |
| `build.zig` | Add scan → compile dependency |
| `prelude.zig` | Export RouteParams, remove match_route |
| `handlers/*.zig` (24 files) | Delete constants, update route() signature |
| `generated/routes.generated.zig` | Include handler @import |
| `sim.zig` | Update if it calls route() directly |
| `codec.zig` / `codec_fuzz.zig` | Update if they reference route constants |
