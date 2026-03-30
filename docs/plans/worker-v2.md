# Worker v2 — WAL-Derived State, Scanner-Enforced Completion

> Depends on [sidecar-v2.md](sidecar-v2.md) Phases 1–3. Workers are
> built on the unified pipeline, async prefetch, and CALL/RESULT
> protocol.

## Design decisions

These decisions were reached through discussion and are load-bearing.
Each one closes a design branch — don't reopen without revisiting the
reasoning.

### The WAL is the queue

No `_worker_queue` table. Worker dispatch is a WAL entry. Worker
completion is a WAL entry. The lifecycle is derived from history:

- **Pending:** dispatch entry exists, no completion entry follows.
- **Completed:** success completion entry committed.
- **Failed:** failure completion entry committed.

No mutable status field. No state that can diverge from the log.

**Why:** The WAL already records every committed mutation. A mutable
queue table is derived state that can diverge — a user can corrupt it
with an outside `sqlite3` command. The WAL is the source of truth
because the server is the single writer, by contract.

### Trust the WAL

The framework's trust boundary is the server process. Everything that
goes through the server is correct. Everything outside (direct DB
edits, filesystem writes) is the user's problem. The WAL is
trustworthy because the server is the single writer.

External data enters through the pipeline like any other request. Sync
workers fetch from external services and write to local tables through
the normal commit path. The state machine never reaches out — data
comes in.

**Why:** Tiger-web sits above SQLite and the filesystem. It can't own
the disk like TigerBeetle does. Instead of hedging (reconciliation,
checksums on reads), it defines a clear contract: all mutations go
through the server. Same principle, different layer.

### No retries, but dead dispatch resolution

The framework does not retry failed workers. The user handles retry
logic explicitly if they need it.

However, the framework must guarantee liveness. If the sidecar crashes
mid-worker or a RESULT is lost, the dispatch stays pending in the WAL
forever, consuming an in-flight slot. Without resolution, slots leak
until the bound fills up and no new workers dispatch.

The tick loop enforces a deadline on in-flight dispatches. If a CALL
has been outstanding longer than the deadline (comptime-known, derived
from the worker's interval), the framework resolves it as dead: it
commits a dead-dispatch entry to the WAL (freeing the in-flight slot)
and logs a warning. The dispatch is no longer pending — it's resolved.

Dead dispatch triggers the `returns` handler with
`ctx.worker_failed = true` — same path as any other failure.

**Why:** Automatic retries add hidden state and hide failures. Dead
resolution is the minimum mechanism that prevents slot leaks without
hiding the failure. Every dispatch eventually resolves — success,
failure (sidecar exception), or dead (framework deadline). No stuck
states.

### Worker returns data, framework routes to `returns`

The worker is a pure function: args in, data out. It returns happy
path data only. No error handling, no routing decisions, no framework
knowledge.

```typescript
export async function process_image(product_id: string, url: string) {
  const processed = await imageService.resize(url);
  return { product_id, url: processed.url };
}
```

The `returns` annotation declares the completion handler. The
framework always delivers to it:

- **Success:** completion handler receives the worker's return data.
- **Any failure** (uncaught exception, sidecar crash, dead dispatch):
  completion handler receives `ctx.worker_failed = true`, no data.

The scanner enforces that the `returns` handler branches on
`ctx.worker_failed`. Missing branch is a build error.

**Why:** The framework guarantees every dispatch resolves with a
handler call. The scanner proves failure handling exists at build time.
The worker stays pure — no try/catch, no error routing. The completion
handler owns all branching. No path leaves business state stuck.

### `worker.xxx()` is sugar

The handle calls `worker.process_image(id, url)`. Codegen transforms
this into a write instruction that records the dispatch intent in the
WAL. The handle's return signature doesn't change. The worker call is
a side effect on the writes list.

**Why:** The dispatch is just a write like any other. It commits in
the same transaction as the handle's business writes. Atomic
enqueueing with no special path.

### Backpressure is a comptime constant

The max in-flight workers is a comptime constant declared by the
developer — `max_in_flight_workers = 16`. This is the size of the
fixed array that tracks in-flight dispatches, allocated at init.

When the limit is hit, the tick loop stops dispatching. New dispatch
entries wait in the WAL for a slot. The sidecar never receives more
than the bound — bounded by design, not by runtime capacity.

**Why:** The critical variable (external completion time) isn't in the
annotations and isn't knowable at compile time. Static allocation is
explicit — the developer knows their system, declares the bound, the
framework allocates exactly that many slots and enforces the limit.

### Workers are reusable

A `process_image` worker does not belong to the handler that defines
it — any handle that needs an image processed can dispatch it. The
scanner collects all `[worker]` annotations globally and generates one
`worker` object with every method available in every handle. No
imports. Shared logic is the developer's problem.

### Settings belong on the annotation

The handle decides what work to do and with what arguments. The worker
decides how to do it. The only configurable knob is `interval`. The
framework provides sensible defaults for everything else. If the same
worker needs different operational profiles, that is two workers with
different names.

### Parallelism preserves determinism

Workers fire concurrently in the sidecar. Results return as
independent RESULT frames. The server processes each through the
normal pipeline in arrival order. Non-determinism is contained in the
sidecar — the state machine never depends on worker completion order.

**Why:** The sidecar is where determinism ends. The external API call
takes however long it takes. But the moment the result re-enters the
server, it's just another operation in the deterministic pipeline.
Arrival order is the execution order.

### Workers cover every external integration

Every external interaction is: send something out, wait, get something
back. The handle records intent, responds immediately. The worker does
the external work. The result re-enters the pipeline. The framework
makes it impossible to block a request on an external call.

The render phase responds to the user with a loading state,
notification, or preview. The user never waits for the external work
to complete.

### Completion handlers must be idempotent

If the server crashes after dispatching a CALL but before receiving
the RESULT, it restarts, rebuilds the in-memory index from the WAL,
and re-dispatches. The sidecar might run the worker twice. The
completion handler could run twice.

The framework does not deduplicate. The developer writes idempotent
completion handlers. The data to deduplicate is already in the
business logic — the developer tracks status (`processing`, `done`,
`failed`) and the completion handler checks it in prefetch.

```typescript
// Idempotent: checks status before writing
if (ctx.prefetched.product.image_status === "done") {
  return "ok";  // already completed, no-op
}
```

**Why:** Framework-level deduplication is hidden behavior. Idempotent
handlers are correct by construction. The status column is the
developer's own deduplication key.

### Completion routing is comptime-resolved

The `returns` annotation names an operation. The scanner validates at
build time that the target exists as a registered `[handle]`. The
mapping is stored as a comptime enum value in the generated dispatch
table — no runtime string lookup.

**Why:** The scanner can prove at build time that the target exists
and the types align. Runtime only checks that the request_id maps to
a known in-flight dispatch — all values are comptime-known.

### Table sync is the external data pattern

Microservices that need external data write to a local table through
the server's pipeline. A sync worker fetches from the external service
and posts the data through a completion operation. The state machine
reads locally, never reaches out.

**Why:** The server stays air-gapped at runtime. The tick sees all
data locally. The WAL captures every mutation including synced data.
No unbounded waits, no external dependencies in the hot path.

### Separate connections for workers and requests

Worker CALLs are long-running (minutes — external API calls).
Request CALLs are short-lived (microseconds — sidecar handler
returns immediately). Mixing them on one socket means a slow worker
blocks all request processing.

The sidecar accepts two connections from the server:
- **Request connection** — serial pipeline, request_id=0, fast CALLs
  (route, prefetch, handle, render).
- **Worker connection** — concurrent, incrementing request_ids,
  slow CALLs (worker functions). Multiple in-flight, matched by id.

Each connection has its own SidecarClient with its own send_buf,
recv_buf, and epoll completion. No multiplexing, no frame
interleaving.

**Why:** TB separates control plane from data plane. Request
handling is data plane (fast, bounded). Worker dispatch is control
plane (slow, unbounded). Don't mix them on the same connection.

### WAL entry format for worker dispatches

Worker dispatches are recorded in the WAL alongside SQL writes.
A handle can do SQL writes AND dispatch a worker in the same
transaction — both are in the same WAL entry.

The WAL entry format gains a discriminator:
- SQL writes: existing format `[sql_len][sql][param_count][params]`
- Worker dispatches: `[marker][name_len][name][args_bytes]`

The marker byte distinguishes worker dispatches from SQL writes
in the entry's write list. On WAL replay, SQL writes replay as
SQL, worker dispatches rebuild the pending dispatch index.

**Why:** The WAL already records every committed mutation. Worker
dispatches are mutations — "intent to do external work." Without
WAL entries, the server loses track of pending work after a crash.

---

## Implementation checklist

### 1. Annotation scanner — `[worker]` phase

- [ ] Add `worker` to the scanner's Phase enum.
- [ ] Parse `[worker] .name` — worker name (becomes function name for
  CALL).
- [ ] Parse `interval Ns` — dispatch frequency. Default 5s.
- [ ] Collect all `[worker]` annotations.
- [ ] Parse `returns .operation` — completion handler target.
- [ ] Validate `returns` target exists as a registered operation.
- [ ] Assert completion handler branches on `ctx.worker_failed`.
  Missing branch is a build error.

### 2. Codegen — `worker` object sugar

- [ ] Generate one typed method per `[worker]` annotation on the
  `worker` object.
- [ ] Each method serializes args to binary row format and appends an
  INSERT-equivalent write instruction to the handle's writes list.
- [ ] The write records dispatch intent in the WAL.
- [ ] Method signature matches the worker function's parameter types.
- [ ] The `worker` object is available in every handle. No imports.

### 3. WAL — worker dispatch entries

- [ ] Worker dispatch is a WAL entry: operation type marker, function
  name, serialized args, sequence number.
- [ ] Worker completion is a normal operation commit — already a WAL
  entry.
- [ ] Dead-dispatch resolution is a WAL entry: marks a dispatch as
  resolved-dead, frees the in-flight slot, triggers `returns`
  handler with `ctx.worker_failed`.
- [ ] In-memory index of pending dispatches: rebuilt from WAL on
  startup, updated on dispatch commit / completion commit / dead
  resolution. Avoids unbounded WAL scan on every tick.
- [ ] Index size bounded by `max_in_flight_workers` (comptime
  constant, static allocation).

### 4. Tick loop — dispatch

- [ ] On each tick, read pending dispatches from in-memory index (up
  to in-flight bound).
- [ ] Send `CALL(function_name, args)` to sidecar for each.
- [ ] Track in-flight count. Stop dispatching when bound is reached.
- [ ] If sidecar connection is down, skip dispatch (entries remain
  pending in WAL).
- [ ] Check in-flight deadlines. If a CALL has been outstanding past
  the deadline, commit a dead-dispatch entry to WAL, free the slot,
  route to `returns` handler with `ctx.worker_failed`, log a
  warning.

### 5. Completion flow

- [ ] Sidecar returns `RESULT(request_id, result_bytes)` — happy path
  data only.
- [ ] Server constructs a message for the `returns` operation with the
  result data.
- [ ] Message enters the normal pipeline: prefetch → handle → render.
- [ ] The completion operation commits to WAL — this is what makes the
  dispatch "completed" (no pending dispatch without completion).
- [ ] On failure (sidecar reports exception, dead dispatch deadline):
  server constructs a message for the `returns` operation with
  `ctx.worker_failed = true`, no data.
- [ ] Completion handler always runs — success or failure.

### 6. Worker boundary fuzzer

- [ ] PRNG-driven, deterministic, seeded.
- [ ] Generate malformed CALL results:
  - Unknown operation names in result.
  - Malformed binary args (truncated, wrong type tags).
  - Results for dispatches that don't exist.
  - Duplicate results (same request_id twice).
- [ ] Assert every malformed result is rejected before state machine.

### 7. Tooling

- [ ] Extend `replay.zig` with a `--workers` flag.
- [ ] Show pending dispatches (dispatch entries without completions).
- [ ] Show completed/failed (dispatch + completion pairs).
- [ ] Deserialize binary args using self-describing row format.

### 8. Delete old worker

- [ ] Remove `worker.zig`.
- [ ] Remove `run-worker` from `build.zig`.
- [ ] Update ecommerce example to use worker annotations.

---

## Full example — image upload flow

```typescript
// handlers/upload_image.ts

// [route] POST /products/:id/image
// [handle] .upload_image

// [prefetch]
export async function prefetch(msg, db) {
  const product = await db.query(
    "SELECT * FROM products WHERE id = ?", msg.id);
  return { product };
}

export function handle(ctx, db) {
  db.execute("UPDATE products SET image_status = 'processing' WHERE id = ?",
    ctx.params.id);
  worker.process_image(ctx.params.id, ctx.body.url);
  return "processing";
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
  return { product_id, url: processed.url };
}

// [route] POST /internal/image-complete
// [handle] .image_complete

// [prefetch]
export async function prefetch(msg, db) {
  const product = await db.query(
    "SELECT * FROM products WHERE id = ?", msg.body.product_id);
  return { product };
}

export function handle(ctx, db) {
  if (ctx.worker_failed) {
    db.execute("UPDATE products SET image_status = 'failed' WHERE id = ?",
      ctx.body.product_id);
    return "failed";
  }
  // Idempotent: check status before writing
  if (ctx.prefetched.product.image_status === "done") {
    return "ok";
  }
  db.execute("UPDATE products SET thumbnail_url = ?, image_status = 'done' WHERE id = ?",
    ctx.body.url, ctx.body.product_id);
  return "ok";
}

// [render]
export async function render(ctx, db) {
  const product = await db.query(
    "SELECT p.*, c.name as category FROM products p JOIN categories c ON p.category_id = c.id WHERE p.id = ?",
    ctx.params.id);
  if (ctx.status === "failed") {
    return `<div class="error">Image processing failed for ${product.name}.</div>`;
  }
  return `<img src="${product.thumbnail_url}" /> <span>${product.name} - ${product.category}</span>`;
}
```

## Table sync example — Stripe data

```typescript
// handlers/sync_stripe.ts

// [worker] .sync_stripe_charges
// returns .ingest_charges
// interval 60s
export async function sync_stripe_charges() {
  const charges = await stripe.charges.list({ limit: 100 });
  return { charges: charges.data };
}

// [route] POST /internal/ingest-charges
// [handle] .ingest_charges

// [prefetch]
export async function prefetch(msg, db) {
  return {};  // no prefetch needed
}

export function handle(ctx, db) {
  if (ctx.worker_failed) {
    // Log, alert, or schedule retry — developer decides.
    return "sync_failed";
  }
  for (const charge of ctx.body.charges) {
    db.execute("INSERT OR REPLACE INTO stripe_charges (id, amount, status) VALUES (?, ?, ?)",
      charge.id, charge.amount, charge.status);
  }
  return "ok";
}

// [render]
export function render(ctx) {
  return `<div>Synced ${ctx.body.charges.length} charges.</div>`;
}
```
