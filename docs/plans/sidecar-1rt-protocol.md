# Plan: 1-RT SHM Sidecar Protocol

## Context

The V2 4-RT SHM protocol gets 15K req/s. The sidecar is CPU-bound at 110% — each of the 4 handler invocations costs ~17µs, totaling ~68µs/request. The sidecar has spare capacity per-invocation (60K stages/s > Fastify's 49K/s), but 4 invocations per request waste it.

Two of the four round trips are redundant:
- **Route**: The framework already routes natively via `app.zig:handler_route()` using a compiled route table
- **Prefetch**: 19/20 handlers use static SQL extractable at build time

Collapsing to 1 RT: framework does route + prefetch natively, sends `{operation, rows, body}` to sidecar, gets back `{status, writes, html}`. At ~17µs for handle+render combined, throughput = ~59K/s theoretical, ~42K realistic with pipeline overhead.

## Handler syntax: unchanged

Developers write the same 4 functions. The build step determines what runs where.

## Handler classification

| Category | Count | Strategy | Example |
|---|---|---|---|
| Static SQL, id param | 12 | 1-RT | get_product, delete_product |
| Static SQL, literal param | 3 | 1-RT | list_products (LIMIT 50) |
| No prefetch | 3 | 1-RT | logout, page_load_login |
| Multi-query static SQL | 2 | 1-RT | page_load_dashboard (3 queries), transfer_inventory (2 queries) |
| Body-derived param | 1 | 1-RT | search_products (`msg.body.query`) |
| Dynamic loop query | 1 | 4-RT fallback | create_order (N queries for N items) |

19/20 handlers use 1-RT. `create_order` falls back to 4-RT.

## Implementation steps

### Step 1: Extract prefetch SQL in annotation scanner

**File: `annotation_scanner.zig`**

The `SqlStringIterator` (line ~1033) already extracts SQL strings for validation. Extend it to also collect:
- The SQL text
- The query mode (`db.query` vs `db.queryAll`)
- Parameter expressions (`msg.id`, `msg.body.X`, literal integers)
- The return key name (from `return { KEY: ... }`)

Add a `PrefetchSqlExtractor` that scans `db.query(` / `db.queryAll(` calls in the prefetch function body. For each call:
- Extract SQL string (already done by SqlStringIterator)
- Detect mode from method name
- Parse params after the SQL string's closing quote
- Parse return key from the `return { key: ... }` pattern

If any param is unrecognized or the body has loops/conditionals around SQL calls → mark as `fallback`.

Add `--prefetch-zig=PATH` CLI flag. Emit `prefetch.generated.zig`:

```zig
pub const ParamSource = enum { none, id, body_field, literal_int };
pub const ParamSpec = struct {
    source: ParamSource,
    field: []const u8,  // body field name when source = .body_field
    int_val: i64,       // value when source = .literal_int
};
pub const QuerySpec = struct {
    sql: []const u8,
    mode: protocol.QueryMode,
    params: []const ParamSpec,
    key: []const u8,
};
pub const PrefetchSpec = struct {
    queries: []const QuerySpec,
};
// Indexed by @intFromEnum(Operation). null = fallback to 4-RT.
pub const specs: [operation_count]?PrefetchSpec = .{ ... };
```

Also emit the prefetch key mapping into the TS build artifacts so the sidecar knows which row set maps to which `ctx.prefetched` key.

### Step 2: 1-RT dispatch path in sidecar_dispatch.zig

**File: `sidecar_dispatch.zig`**

Add stages for the 1-RT path alongside existing 4-RT stages:

```
1-RT: free → native_prefetch → combined_pending → combined_complete → write_pending → write_complete → render_complete
4-RT: free → route_pending → route_complete → prefetch_pending → ... (existing)
```

In `start_request`:
1. Route natively (call `App.handler_route()` or use the compiled route table)
2. Check `prefetch.generated.zig` specs for the operation
3. If spec exists → 1-RT path: execute prefetch SQL, build combined CALL
4. If spec is null → 4-RT fallback: send route CALL as before

In `advance()`, handle 1-RT stages:
- `native_prefetch`: For each QuerySpec, assemble params from `entry.msg.id` / body field / literal. Call `storage.query_raw()`. Concatenate row sets as `[row_set_count: u8][row_set_0][row_set_1]...`. Move to `combined_pending`.
- `combined_pending` → `combined_complete`: on_frame delivers RESULT with {status, writes, html}. Parse like existing handle+render combined.
- Then proceeds to `write_pending` → `write_complete` → `render_complete` (same as current).

### Step 3: Combined CALL/RESULT frame format

**CALL "handle_render":**
```
[operation: u8][id: 16B LE][body_len: u16 BE][body bytes]
[row_set_count: u8][row_set_0...][row_set_1...]...
```

Each row set is the existing `protocol.zig` binary row format. For no-prefetch handlers, `row_set_count = 0`.

**RESULT:**
```
[status_len: u16 BE][status][session_action: u8]
[write_count: u8][writes...]
[html to end]
```

Same as existing V1 handle result format (minus operation/id prefix which the server already has).

### Step 4: TS sidecar `dispatchHandleRender`

**File: `adapters/call_runtime_v2_shm.ts`**

New function that:
1. Parses the combined CALL (operation, id, body, row sets)
2. Deserializes row sets using existing `readRowSet`
3. Builds `ctx.prefetched` using the key mapping from the build manifest
4. Runs `mod.handle(ctx, db)` → status + writes
5. Runs `mod.render({...ctx, status})` → html
6. Builds combined RESULT frame

Add to the frame dispatch switch:
```typescript
case "handle_render": resultData = dispatchHandleRender(requestId, args); break;
```

### Step 5: Wire it up

**File: `app.zig`** — no new flag needed. The dispatch checks per-operation specs automatically. Operations with specs use 1-RT; `create_order` (null spec) uses 4-RT.

**File: `framework/server.zig`** — `try_dispatch_v2` calls the updated `start_request` which now does native routing internally.

**File: `build.zig`** — add `--prefetch-zig` to the scanner step.

**File: `examples/ecommerce-ts/package.json`** — `npm run build` already runs `zig build scan`. Ensure it passes the new flag.

### Step 6: Param assembly for body fields

For `search_products` (`msg.body.query`): the server needs to extract a JSON field from the HTTP body. The body is already a byte slice in `entry.msg.body`. A minimal JSON field extractor (find `"query":"` then extract the string value) handles this. No full JSON parser needed — ~20 lines of Zig, bounded, no allocations.

For `transfer_inventory` (`msg.body.target_id`): same pattern, extract `"target_id"` string field.

## Files to modify

| File | Change |
|---|---|
| `annotation_scanner.zig` | Extract prefetch SQL, params, keys. Emit `prefetch.generated.zig` |
| `sidecar_dispatch.zig` | Add 1-RT stages, native route + prefetch, combined CALL send |
| `framework/server.zig` | Minor: `start_request` now does native routing before SHM CALL |
| `adapters/call_runtime_v2_shm.ts` | Add `dispatchHandleRender` combined handler |
| `build.zig` | Add `--prefetch-zig` flag to scanner step |
| `generated/prefetch.generated.zig` | New: comptime prefetch specs per operation |

## Verification

1. `zig build scan` generates `prefetch.generated.zig` with correct SQL for all 20 handlers
2. `create_order` spec is null (fallback)
3. Unit test: native prefetch with `query_raw` returns same rows as sidecar-mediated prefetch
4. Smoke test: `curl http://localhost:9877/products` returns product HTML through 1-RT path
5. Smoke test: `curl -X POST http://localhost:9877/orders` (create_order) works through 4-RT fallback
6. Benchmark: `zig-out/bin/tiger-load --port=9877 --connections=128 --requests=100000 --ops=list_products:50,get_product:50` → target ≥35K req/s
7. Write test: POST create product then GET list_products shows it → write visibility works through 1-RT

## Risks

- **Body JSON parsing in Zig**: Minimal extractor needed for 2 handlers. Bounded, no allocations. Falls back to 4-RT if extraction fails.
- **Multi-query buffer size**: 3 queries × 50 rows ≈ 112KB, within 256KB frame_max.
- **Annotation scanner complexity**: SQL extraction is the hardest part. The scanner already has SqlStringIterator. Extending it to collect (not just validate) is incremental.
