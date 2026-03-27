# Worker — Async Dispatch for External IO and Heavy Compute

> **TODO:** Stop and ask TigerBeetle for critiques. This plan needs to
> be refined.

The state machine is deterministic, single-threaded, and never does IO.
Real applications need side effects: charge payments, call external APIs,
resize images, run ML models, fetch from remote databases, delegate
compute to other machines. Workers are the boundary where side effects
live — outside the state machine, outside the tick loop, outside
determinism.

## Implementation checklist

### 1. `_worker_queue` table

- [ ] Auto-create on server startup. Framework owns the schema.
- [ ] Schema: `id` integer PK, `worker` text, `args` blob, `status`
  text (`pending`/`dispatched`/`failed`), `attempts` integer default 0,
  `created_at` integer, `dispatched_at` integer nullable.
- [ ] Args use the sidecar binary row format — same serialization as
  the protocol.
- [ ] Three queries, same for any number of workers:
  - Poll: `SELECT FROM _worker_queue WHERE worker = ? AND status = 'pending'`
  - Claim: `UPDATE ... SET status = 'dispatched' WHERE id = (SELECT ... LIMIT 1) RETURNING *`
  - Sweep: `UPDATE ... SET status = 'pending', attempts = attempts + 1 WHERE status = 'dispatched' AND dispatched_at < threshold`

### 2. Annotation scanner — `[worker]` phase

- [ ] Add `worker` to the scanner's Phase enum.
- [ ] Parse `[worker] .name` — operation name.
- [ ] Parse `returns .operation` — completion route target.
- [ ] Parse `interval Ns` — poll frequency. Default 5s.
- [ ] Validate `returns` target exists as a registered route.
- [ ] Validate argument types match between dispatch call and function
  signature.
- [ ] Collect all `[worker]` annotations globally into manifest.

### 3. Scanner enforcement — `ctx.worker_failed`

- [ ] Identify completion handlers: any handle whose route is the
  `returns` target of a worker.
- [ ] Assert completion handler branches on `ctx.worker_failed`. Missing
  branch is a build error.
- [ ] Enforcement is in handle only. Render is not enforced.

### 4. Codegen — `worker` object

- [ ] Generate one typed method per `[worker]` annotation.
- [ ] Each method serializes args to binary and inserts into
  `_worker_queue` with `status = 'pending'`.
- [ ] The `worker` object is available in every handle. No imports.
- [ ] Method signature matches the worker function's parameter types.

### 5. Codegen — sidecar worker dispatch

- [ ] Generate dispatch table: worker name → user function.
- [ ] On pending rows from server: deserialize binary args, call user
  function concurrently (fire all, let runtime handle parallelism).
- [ ] On function return: POST result to the `returns` route as JSON
  body with flat fields (no path params).

### 6. Server — polling and delivery

- [ ] Server polls `_worker_queue` for pending rows on tick interval.
- [ ] Sends pending rows to sidecar over existing unix socket.
- [ ] Marks rows as `dispatched` with `dispatched_at` timestamp.
- [ ] On result POST from sidecar: route through normal pipeline
  (prefetch → handle → render).

### 7. Boundary assertions

- [ ] On every worker result POST, assert before state machine:
  - Worker name matches a known `[worker]` annotation.
  - Completion route for this worker exists.
  - Body shape conforms to expected schema.
  - `_worker_queue` row exists, has status `dispatched`.
  - Row ID matches, worker name matches row's worker field.
- [ ] Reject all invalid results before prefetch runs.

### 8. Failure handling

- [ ] Sweep: periodic check for `dispatched` rows older than timeout
  threshold. Reset to `pending`, increment `attempts`.
- [ ] Max attempts: after threshold (default 3), mark `failed` instead
  of `pending`.
- [ ] Failure delivery: when row moves to `failed`, framework POSTs to
  completion route with `ctx.worker_failed = true`.
- [ ] Result: every dispatched worker eventually resolves — success or
  failure. No stuck states.

### 9. `tiger-web queue` CLI

- [ ] Read `_worker_queue` table, deserialize binary args, display
  readable output.
- [ ] Flags: `--worker=name`, `--status=pending|dispatched|failed`,
  `--id=N`.
- [ ] Fallback debugging tool. Framework should log proactively when
  sweep fires repeatedly or rows exceed max attempts.

### 10. Worker boundary fuzzer

- [ ] Generate malformed worker results via PRNG:
  - Unknown worker names.
  - Results for non-dispatched rows (pending, failed, absent).
  - Mismatched row IDs.
  - Malformed binary args (truncated, oversized, wrong type tags).
  - Results for nonexistent completion routes.
  - Duplicate results (same row ID twice).
- [ ] Assert every malformed result is rejected before state machine.
- [ ] PRNG-seeded, deterministic, matches existing fuzz infrastructure.

### 11. Auth

- [ ] Use same cookie model as any other client. Revisit when auth is
  solidified.

---

## Design decisions

These decisions are documented to prevent regression — each was
explored and resolved during design. They are not implementation steps.

### The flow

A user request arrives and the handle phase makes a decision. If that
decision involves work that is slow, external, or side-effectful, the
handle schedules a worker and the render phase responds to the user
immediately with a loading state, notification, or preview. The user
never waits for the external work to complete.

The worker is a separate process. It polls the server over HTTP for
pending scheduled work, receives the function arguments the handle
recorded, and runs the user's async function. When the work is done,
the worker posts the result back to the server as a normal HTTP request.

That HTTP post enters the server like any other client request — full
pipeline, same deterministic guarantees.

### User syntax

**Dispatch:** `worker.process_image(ctx.params.id, ctx.body.url)` in
handle. The `worker.` prefix makes the async boundary visible. No
await — the handle has already made its decision.

**Define:**
```typescript
// [worker] .process_image
// returns .image_complete
// interval 5s
export async function process_image(product_id: string, url: string) {
  const processed = await imageService.resize(url);
  return { url: processed.url };
}
```
Plain async function — args in, data out. No `post()`, no URLs, no
HTTP knowledge. The framework delivers the return data to the `returns`
route.

**Complete:**
```typescript
// [route] POST /products/:id/image-complete
// [prefetch] SELECT * FROM products WHERE id = :id
// [handle] .image_complete
export function handle(ctx: HandleContext, db: WriteDb) {
  if (ctx.worker_failed) {
    db.execute("UPDATE products SET image_status = 'failed' WHERE id = ?", ctx.params.id);
    return "failed";
  }
  db.execute("UPDATE products SET thumbnail_url = ?, image_status = 'done' WHERE id = ?",
    ctx.body.url, ctx.params.id);
  return "ok";
}
```
Scanner enforces the `ctx.worker_failed` branch. Handle returns a
status. Render branches on the status — no special worker logic in
render.

### Full example — image upload flow

```typescript
// handlers/upload_image.ts

// [route] POST /products/:id/image
// [prefetch] SELECT * FROM products WHERE id = :id
// [handle] .upload_image
export function handle(ctx: HandleContext, db: WriteDb) {
  db.execute("UPDATE products SET image_status = 'processing' WHERE id = ?", ctx.params.id);
  worker.process_image(ctx.params.id, ctx.body.url);
}
// [render]
export function render() {
  return `<div class="processing">Processing your image...</div>`;
}

// [worker] .process_image
// returns .image_complete
// interval 5s
export async function process_image(product_id: string, url: string) {
  const processed = await imageService.resize(url);
  return { url: processed.url };
}

// [route] POST /products/:id/image-complete
// [prefetch] SELECT * FROM products WHERE id = :id
// [handle] .image_complete
export function handle(ctx: HandleContext, db: WriteDb) {
  if (ctx.worker_failed) {
    db.execute("UPDATE products SET image_status = 'failed' WHERE id = ?", ctx.params.id);
    return "failed";
  }
  db.execute("UPDATE products SET thumbnail_url = ?, image_status = 'done' WHERE id = ?",
    ctx.body.url, ctx.params.id);
  return "ok";
}
// [render]
export function render(ctx: RenderContext) {
  if (ctx.result.image_status === "failed") {
    return `<div class="error">Image processing failed. Try again.</div>`;
  }
  return `<img src="${ctx.result.thumbnail_url}" />`;
}
```

### Why workers are reusable

A `process_image` worker does not belong to the handler that defines
it — any handle that needs an image processed can dispatch it. The
scanner collects all `[worker]` annotations globally and generates one
`worker` object with every method. Each worker maps to exactly one
completion operation via `returns`. If two flows need different
completions, those are two workers. Shared logic is the developer's
problem.

### Why settings belong on the annotation

The handle decides what work to do and with what arguments. The worker
decides how to do it. The only configurable knob is `interval`. The
framework provides sensible defaults for everything else. If the same
worker needs different operational profiles, that is two workers with
different names.

### Why the sidecar runs workers

The sidecar is already a long-running process. Workers are functions in
the sidecar language. The sidecar fires them concurrently — the
language runtime handles parallelism (event loop, asyncio, goroutines).
The framework does not manage concurrency.

### Why completion routes use flat POST bodies

The worker returns all data the completion handler needs as a flat
object. No path params, no URL construction. The framework posts the
return data as the request body. Prefetch binds from `ctx.body`.

### Why `_worker_queue` instead of a traditional queue

Atomic enqueueing (same transaction as handle's writes). Queryable.
No infrastructure. Polling is already the architecture. Scaling is not
a differentiator — the database is the bottleneck before the queue is.

### Why the queue is binary, not JSON

Same binary row format as the sidecar protocol. One serialization
strategy. The server knows the layout at compile time. Boundary
assertions become struct field checks, not string parsing. Debugging
is through `tiger-web queue` CLI, not raw SQL.

### Queue debugging is a fallback

If the developer needs to debug the queue, the system may have already
failed. The framework should surface stuck or failed state proactively
through logging and the `ctx.worker_failed` completion path. Consider
logging when the sweep fires repeatedly for the same row or when rows
exceed max attempts.

### Why parallelism preserves determinism

Workers fire concurrently in the sidecar. Results post back as
independent HTTP requests. The state machine handles each in arrival
order through the deterministic pipeline. Non-determinism is contained
in the sidecar. The state machine never depends on worker completion
order.

### Why this covers every external integration

Every external interaction is: send something out, wait, get something
back. The handle records intent, responds immediately. The worker does
the external work. The worker returns the result. The state machine
processes it. The framework makes it impossible to block a request on
an external call.

### Error handling philosophy

The framework catches failures (sweep, max attempts, automatic failure
delivery). The developer handles failures (state transition, user
message). The scanner enforces that the handling exists. Not that the
developer caught an error, but that they decided what happens when work
fails.
