# Scanner-Generated Status Enums

## Principle

**The handle function body is the single source of truth for statuses.**

The scanner extracts status literals from handle() return statements and
generates the enforcement artifact for each language. The developer never
declares a status enum — they return statuses in handle(), and the build
system makes sure render handles every one.

One path for all languages. No deviation.

## How it works

### 1. Scanner extracts statuses from handle()

The annotation scanner already scans handler files for `[handle]`
annotations. It locates the handle function body and extracts every
literal status return.

Zig pattern:
```zig
return t.ExecuteResult.read_only(t.HandlerResponse.not_found);
return t.ExecuteResult.read_only(t.HandlerResponse.ok);
// Scanner extracts: { ok, not_found }
```

TS pattern:
```ts
return { status: "not_found", writes: [] };
return { status: "ok", writes: [...] };
// Scanner extracts: { ok, not_found }
```

The scanner looks for literal status values in return statements.
If a status is assigned to a variable first, the scanner misses it.
This is self-correcting: missing status → generated enum is incomplete →
compiler/type-checker error → developer rewrites as literal return.

Convention: **status must be a literal in the return expression.**
This is already how every handler is written.

### 2. Scanner outputs statuses in the manifest

The existing JSON manifest gains a `statuses` field per operation:

```json
{
  "operation": "get_product",
  "statuses": ["ok", "not_found"],
  "phases": { "route": {...}, "handle": {...}, "render": {...} }
}
```

### 3. Adapter generates enforcement per language

**Zig adapter** generates a per-handler Status enum:

```zig
// generated/statuses.generated.zig
pub const get_product = enum { ok, not_found };
pub const create_product = enum { ok, version_conflict };
pub const page_load_dashboard = enum { ok };
// ... one field per handler
```

The handler imports this instead of declaring its own:

```zig
const generated = @import("generated/statuses.generated.zig");
pub const Status = generated.get_product;
pub const Context = t.HandlerContext(Prefetch, Body, Identity, Status);

pub fn render(ctx: Context) []const u8 {
    return switch (ctx.status) {  // exhaustive — compiler enforces
        .ok => render_product(ctx),
        .not_found => "<div class=\"error\">Not found</div>",
    };
}
```

Adding a new status to handle() without updating render is a compile error:
1. Developer adds `.version_conflict` return to handle()
2. Build runs scanner → regenerates enum with 3 variants
3. Compiler sees non-exhaustive switch in render → error

**TS adapter** generates a union type:

```ts
// generated/statuses.generated.ts
export type GetProductStatus = "ok" | "not_found";
export type CreateProductStatus = "ok" | "version_conflict";
```

**Dynamic languages** generate a runtime validation set:

```python
# generated/statuses.py
GET_PRODUCT_STATUSES = frozenset({"ok", "not_found"})
```

### 4. Framework enforces at the boundary

**Zig**: `map_status()` in app.zig maps shared `message.Status` to the
generated per-handler enum. `unreachable` if handle returned a status
not in the enum — that means handle() uses a status the scanner didn't
extract (developer used a variable, not a literal).

**TS**: TypeScript compiler rejects non-exhaustive status handling.

**Dynamic**: Framework runtime check — if render returns without
handling a known status, the framework rejects the response.

## Build order

```
1. Scanner reads handler source files (text, not compiled)
2. Scanner extracts [handle] annotations + status literals
3. Scanner writes manifest.json with statuses
4. Adapter reads manifest → generates statuses.generated.zig (or .ts, .py)
5. Compiler compiles handlers (importing generated statuses)
```

Step 1-4 is a build step that runs before compilation.
For Zig: `zig build` step dependency.
For TS: `npm run build` step (already exists for codegen).

## What changes

### Handler files (all 24)

Before:
```zig
pub const Status = enum { ok, not_found };  // manual
pub const Context = t.HandlerContext(Prefetch, Body, Identity, Status);
```

After:
```zig
const generated = @import("generated/statuses.generated.zig");
pub const Status = generated.get_product;  // from scanner
pub const Context = t.HandlerContext(Prefetch, Body, Identity, Status);
```

The developer deletes their manual Status enum. The import replaces it.

### Scanner (annotation_scanner.zig)

Gains a status extraction phase. After locating `[handle]` annotations,
it scans the function body for status literals and records them in the
manifest.

### Zig adapter (adapters/zig_adapter.zig)

Gains a status enum generator. Reads manifest, writes one enum per
handler into `generated/statuses.generated.zig`.

### build.zig

Adds a build step: run scanner + adapter before compiling handlers.

## What doesn't change

- `map_status()` in app.zig — already handles per-handler enums
- `HandlerContext` — already parameterized on Status
- `ValidateHandler` — already validates Status is an enum with .ok
- `render_one` — already passes mapped status to render context
- The render contract — still returns []const u8 or tuple

## Self-correcting property

If the scanner misses a status (developer used a variable):
1. Generated enum is incomplete
2. `map_status()` hits unreachable at runtime when that status fires
3. Developer sees crash, rewrites handle to use literal status
4. Scanner picks it up, regenerates, crash gone

If the developer adds a status but forgets to handle it in render:
1. Generated enum includes the new variant
2. Zig switch is non-exhaustive → compiler error
3. Developer adds the render branch

Both failure modes are loud. No silent bugs.
