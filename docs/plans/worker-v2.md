# Worker v2 — WAL-Derived State, Scanner-Enforced Completion

> Built on the unified pipeline, async prefetch, and CALL/RESULT
> protocol. Sidecar design decisions in
> `docs/internal/decision-sidecar-protocol.md`.

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
has been outstanding longer than the deadline (comptime-known global
constant), the framework resolves it as dead: it
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
knowledge. Workers cannot call `db.query()` — they have no QUERY
sub-protocol. The worker connection only handles RESULT frames.
Workers do external IO (API calls, network), not database IO.

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

### `worker.xxx()` is sugar — separate field, not writes list

The handle calls `worker.process_image(id, url)`. Codegen transforms
this into a dispatch entry on a separate `worker_dispatches` field
of the handle result — NOT mixed into the SQL writes list.

The sidecar handle RESULT payload:
`[status][write_count][writes...][dispatch_count][dispatches...]`

The server processes both: writes → SQL execution + WAL, dispatches →
dispatch index + WAL. Both in the same WAL entry, same transaction.
Atomic enqueueing. If the handle returns a non-ok status, the
dispatch still commits — the status is for the HTTP response, not
a rollback signal. The developer controls both: if they don't want
the worker dispatched on error, they don't call `worker.xxx()` in
the error path.

**Why:** The writes list is for SQL mutations. Worker dispatch is
intent to do external work — not a SQL mutation. Mixing them requires
a marker byte and runtime parsing to distinguish types. Separate
fields are explicit (server knows what each field contains), safe
(SQL engine never sees dispatch data), and independently bounded
(writes_max for SQL, dispatches_max for workers). Wins on all six
TB principles vs the marker byte approach.

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

### Dead dispatch deadline

Deadline is a global comptime constant (e.g.,
`worker_deadline_seconds = 300`). If no result in 5 minutes, resolve
as dead. The developer sets this based on their longest expected
worker execution time.

### Settings belong on the annotation

The handle decides what work to do and with what arguments. The worker
decides how to do it. One required setting:
- `returns .operation` — completion handler target.

The framework provides sensible defaults for everything else. If the
same worker needs different operational profiles, that is two workers
with different names.

Interval/cron-style workers are a separate feature — not in scope
for this plan.

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

The WAL entry gains two sections:
- SQL writes: existing format `[write_count][sql_len][sql][param_count][params]...`
- Worker dispatches: `[dispatch_count][name_len][name][args_bytes]...`

No marker byte. The WAL entry header knows how many writes and
how many dispatches (separate counts). On replay, SQL writes
replay as SQL, worker dispatches rebuild the pending dispatch index.

The WAL `op` number identifies each dispatch. Completion WAL entries
reference the dispatch op. Pending = dispatch op with no completion
referencing it. The `op` is the stable identifier — request_id is
ephemeral (assigned by WorkerClient, lost on crash). Mapping:
`request_id → PendingCall.op → worker_name → returns operation`.

**Why:** The WAL already records every committed mutation. Worker
dispatches are mutations — "intent to do external work." Without
WAL entries, the server loses track of pending work after a crash.
Separate sections (not marker bytes) match the sidecar RESULT
format — explicit, no parsing ambiguity.

### Completion flows through the normal annotation pipeline

When a worker RESULT arrives, the server calls the `returns`
operation's route function with the worker's return data as
`req.body`. The route function extracts `id` and `body` — same as
an HTTP route, just without `// match`. The result flows through
the normal pipeline: prefetch → handle → render.

Completion handlers use the same annotations as HTTP handlers:
`[route]`, `[prefetch]`, `[handle]`, `[render]`. The only
difference: no `// match` directive (not triggered by HTTP).

The scanner suppresses the "missing match" warning for operations
that are `returns` targets of a worker annotation. A routeless
`[route]` is intentional for completion handlers, not a mistake.

```typescript
// HTTP handler — has match:
// [route] .get_product
// match GET /products/:id
export function route(req) {
  return { id: req.params.id };
}

// Completion handler — no match, triggered by worker RESULT:
// [route] .image_complete
export function route(req) {
  return { id: req.body.product_id, body: req.body };
}
```

The framework knows the operation from the `returns` annotation.
The route function just transforms data. Same pipeline, no special
path.

### Uniform handler signature: `ctx` + `db`

Every phase after route receives `ctx`:
- `route(req)` — transforms input, returns `{id, body}`
- `prefetch(ctx, db)` — reads via `await db.query()`
- `handle(ctx, db)` — writes via `db.execute()`
- `render(ctx)` or `render(ctx, db)` — returns HTML

`ctx` contains: `id`, `body`, `prefetched` (after prefetch),
`status` (in render), `worker_failed` (for completion handlers).
Consistent across HTTP and worker completion handlers.

### `ctx.worker_failed` is a status value

Don't add a flag to Message. The server sets the message status to
a reserved value (e.g., `.worker_failed`). The completion handler
checks `ctx.status === "worker_failed"` or the framework derives
`ctx.worker_failed` from the status. The scanner enforces the branch
exists.

### Two sidecar connections, two client types

Two unix sockets, two paths. The server creates both listen sockets
before accepting HTTP. The TS runtime connects to both.

- **Request socket** — existing `SidecarClient` + `listen_and_accept`.
  Serial, one CALL in-flight, request_id=0.
- **Worker socket** — new `WorkerClient` + second `listen_and_accept`.
  Concurrent, fixed array of pending slots, incrementing request_ids.

`WorkerClient` is a separate type from `SidecarClient` — different
invariants. SidecarClient is serial (one slot). WorkerClient is
concurrent (array of max_in_flight slots). Don't extend one into
the other.

```
WorkerClient:
  pending: [max_in_flight]PendingCall  // fixed array, static alloc
  dispatch(name, args) → ?request_id  // find free slot, send CALL
  on_recv()                            // match RESULT to pending slot
  take_completed() → ?PendingCall      // dequeue for completion routing
  check_deadlines(now) → ?PendingCall  // find expired, resolve dead
```

Result data is copied into owned `result_buf` on completion —
recv_buf is reused for the next frame. Same `copy_state` pattern
as SidecarClient.

### Completion operations are normal operations

Adding a worker means adding its completion operation to the
Operation enum in message.zig (`image_complete = 25`), same as
any other handler. Writing the handler file with `[route]`,
`[prefetch]`, `[handle]`, `[render]` annotations. Running the
scanner. Same workflow — no special registration.

---

## Implementation checklist

### 1. Annotation scanner — `[worker]` phase

- [ ] Add `worker` to the scanner's Phase enum.
- [ ] Parse `[worker] .name` — worker name (becomes function name for
  CALL).
- [ ] Collect all `[worker]` annotations.
- [ ] Parse `returns .operation` — completion handler target.
- [ ] Validate `returns` target exists as a registered operation.
- [ ] Assert completion handler branches on `ctx.worker_failed`.
  Missing branch is a build error.

### 2. Codegen — `worker` object sugar

- [ ] Generate one typed method per `[worker]` annotation on the
  `worker` object.
- [ ] Each method serializes args to binary format and appends to
  a separate `worker_dispatches` list — NOT the SQL writes list.
- [ ] The sidecar handle RESULT includes `[dispatch_count][dispatches]`
  after `[write_count][writes]`.
- [ ] The server parses dispatches separately from writes.
- [ ] Method signature matches the worker function's parameter types.
- [ ] The `worker` object is available in every handle. No imports.

### 3. Second sidecar connection (worker socket)

- [ ] Server creates second unix socket for worker CALLs.
- [ ] Second `listen_and_accept` before HTTP is accepted.
- [ ] Worker SidecarClient: own send_buf, recv_buf, epoll completion.
- [ ] Supports concurrent in-flight CALLs with incrementing request_ids.
- [ ] TS runtime connects to both sockets.
- [ ] call_runtime.ts handles worker CALLs on the second connection.

### 4. WAL — worker dispatch entries

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

### 5. Tick loop — dispatch

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

### 6. Completion flow

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

### 7. Worker boundary fuzzer

- [ ] PRNG-driven, deterministic, seeded.
- [ ] Generate malformed CALL results:
  - Unknown operation names in result.
  - Malformed binary args (truncated, wrong type tags).
  - Results for dispatches that don't exist.
  - Duplicate results (same request_id twice).
- [ ] Assert every malformed result is rejected before state machine.

### 8. Tooling

- [ ] Extend `replay.zig` with a `--workers` flag.
- [ ] Show pending dispatches (dispatch entries without completions).
- [ ] Show completed/failed (dispatch + completion pairs).
- [ ] Deserialize binary args using self-describing row format.

### 9. Delete old worker

- [ ] Remove `worker.zig`.
- [ ] Remove `run-worker` from `build.zig`.
- [ ] Update ecommerce example to use worker annotations.

---

## Full example — image upload flow

```typescript
// handlers/upload_image.ts

// [route] .upload_image
// match POST /products/:id/image

// [prefetch]
export async function prefetch(ctx, db) {
  const product = await db.query(
    "SELECT * FROM products WHERE id = ?", ctx.id);
  return { product };
}

export function handle(ctx, db) {
  db.execute("UPDATE products SET image_status = 'processing' WHERE id = ?",
    ctx.id);
  worker.process_image(ctx.id, ctx.body.url);
  return "processing";
}

// [render]
export function render() {
  return `<div class="processing">Processing your image...</div>`;
}

// [worker] .process_image
// returns .image_complete
export async function process_image(product_id: string, url: string) {
  const processed = await imageService.resize(url);
  return { product_id, url: processed.url };
}

// Completion handler — triggered by worker RESULT, not HTTP.
// Same annotations as HTTP handlers, just no // match directive.
// The `returns .image_complete` on the worker tells the framework
// which operation to route the RESULT to.

// [route] .image_complete
export function route(req) {
  return { id: req.body.product_id, body: req.body };
}

// [prefetch] .image_complete
export async function prefetch(ctx, db) {
  const product = await db.query(
    "SELECT * FROM products WHERE id = ?", ctx.id);
  return { product };
}

// [handle] .image_complete
export function handle(ctx, db) {
  if (ctx.worker_failed) {
    db.execute("UPDATE products SET image_status = 'failed' WHERE id = ?", ctx.id);
    return "failed";
  }
  // Idempotent: check status before writing
  if (ctx.prefetched.product.image_status === "done") {
    return "ok";
  }
  db.execute("UPDATE products SET thumbnail_url = ?, image_status = 'done' WHERE id = ?",
    ctx.body.url, ctx.id);
  return "ok";
}

// [render] .image_complete
export function render(ctx) {
  if (ctx.status === "failed") {
    return `<div class="error">Image processing failed.</div>`;
  }
  return `<div>Image updated.</div>`;
}
```

## Second example — payment processing

```typescript
// handlers/charge_payment.ts

// [worker] .charge_payment
// returns .payment_complete
export async function charge_payment(order_id: string, amount: number) {
  const charge = await stripe.charges.create({ amount, currency: "usd" });
  return { order_id, charge_id: charge.id, status: charge.status };
}

// [route] .payment_complete
export function route(req) {
  return { id: req.body.order_id, body: req.body };
}

// [prefetch] .payment_complete
export async function prefetch(ctx, db) {
  const order = await db.query("SELECT * FROM orders WHERE id = ?", ctx.id);
  return { order };
}

// [handle] .payment_complete
export function handle(ctx, db) {
  if (ctx.worker_failed) {
    db.execute("UPDATE orders SET payment_status = 'failed' WHERE id = ?", ctx.id);
    return "failed";
  }
  if (ctx.prefetched.order.payment_status === "paid") {
    return "ok";  // idempotent
  }
  db.execute("UPDATE orders SET payment_status = 'paid', charge_id = ? WHERE id = ?",
    ctx.body.charge_id, ctx.id);
  return "ok";
}

// [render] .payment_complete
export function render(ctx) {
  if (ctx.status === "failed") {
    return `<div class="error">Payment failed.</div>`;
  }
  return `<div>Payment confirmed.</div>`;
}
```
