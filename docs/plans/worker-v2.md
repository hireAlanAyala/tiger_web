# Worker Implementation Plan

> Built on the unified pipeline, async prefetch, and CALL/RESULT
> protocol. Sidecar design decisions in
> `docs/internal/decision-sidecar-protocol.md`.
>
> **Principle:** Always implement the most architecturally correct
> solution, not the simplest. Every layer must be correctly set up
> for the layer above. Cut corners in the foundation and every layer
> above inherits the doubt.

---

## Layer 1: WAL — dispatch + completion entries

The WAL is the queue. No `_worker_queue` table. No mutable state
that can diverge from the log.

### WAL entry format

The WAL entry gains a second section alongside SQL writes:
- SQL writes: `[write_count][sql_len][sql][param_count][params]...`
- Worker dispatches: `[dispatch_count][name_len][name][args_bytes]...`

Separate counts in the header. No marker bytes. On replay, SQL
writes replay as SQL, worker dispatches rebuild the pending index.

The WAL `op` number identifies each dispatch. Completion entries
reference the dispatch op. Pending = dispatch op with no completion
referencing it. The `op` is the stable identifier — request_id is
ephemeral (lost on crash).

### Lifecycle (derived from WAL history)

- **Pending:** dispatch entry exists, no completion follows.
- **Completed:** completion entry committed (success).
- **Failed:** completion entry committed (worker_failed).
- **Dead:** dead-dispatch entry committed (framework deadline).

### In-memory pending index

Rebuilt from WAL on startup. Updated on dispatch commit, completion
commit, and dead-dispatch resolution. Bounded by
`max_in_flight_workers` (comptime constant, static allocation).

### Checklist

- [ ] Extend WAL entry format with dispatch section.
- [ ] Dispatch entry: `[name_len][name][args_bytes]`.
- [ ] Completion entry: references dispatch op.
- [ ] Dead-dispatch entry: marks dispatch resolved-dead.
- [ ] In-memory pending index: `[max_in_flight_workers]PendingDispatch`.
- [ ] WAL replay rebuilds pending index.
- [ ] Index updated on dispatch/completion/dead-dispatch.

---

## Layer 2: WorkerClient — concurrent CALL/RESULT on worker socket

Separate type from SidecarClient. Different invariants: concurrent
(array of slots) vs serial (one slot).

### WorkerClient struct

```
WorkerClient:
  fd, path, send_buf, recv_buf, result_buf
  pending: [max_in_flight]PendingCall
  pending_count: u32
  next_request_id: u32

PendingCall:
  active, request_id, worker_name, dispatched_at
  dispatch_op (WAL op — stable identifier)
  result_flag, result_data (copied to result_buf)
  completed: bool
```

### Operations

- `dispatch(name, args, op)` → find free slot, send CALL, return
  request_id. Non-blocking.
- `on_recv()` → read frame, match request_id to PendingCall, copy
  result to result_buf, mark completed. Called by epoll callback.
- `take_completed()` → dequeue first completed slot for completion
  routing. Called by tick loop.
- `check_deadlines(now)` → find first expired slot. Called by tick
  loop.

No QUERY sub-protocol — workers do external IO, not database IO.
on_recv only handles RESULT frames.

Result data copied into owned `result_buf` — recv_buf reused for
next frame.

### Two sockets

Server creates two unix listen sockets before accepting HTTP. TS
runtime connects to both.

- Request socket: existing SidecarClient (serial, request_id=0).
- Worker socket: WorkerClient (concurrent, incrementing request_ids).

### Checklist

- [ ] Implement WorkerClient struct.
- [ ] `dispatch()` — find slot, build CALL, send frame.
- [ ] `on_recv()` — parse RESULT, match request_id, copy result.
- [ ] `take_completed()` — dequeue for completion routing.
- [ ] `check_deadlines()` — find expired dispatches.
- [ ] `listen_and_accept` for worker socket.
- [ ] Register worker fd with epoll (io.readable).
- [ ] Worker epoll callback drives `on_recv()`.
- [ ] TS runtime: connect to both sockets, handle worker CALLs on
  second connection.

---

## Layer 3: Tick loop — dispatch + completion + deadlines

The tick loop drives three worker operations per tick.

### Dispatch

Read pending dispatches from the in-memory index (WAL entries with
no in-flight CALL). For each, call `WorkerClient.dispatch()`. Stop
when `max_in_flight_workers` is reached or no more pending.

If worker socket is down, skip dispatch — entries stay pending in
WAL.

### Completion routing

Call `WorkerClient.take_completed()`. For each completed worker:
1. Call the `returns` operation's route function with worker result
   as `req.body`.
2. Route function returns `{id, body}`.
3. Enter the serial pipeline: prefetch → handle → render.
4. Completion commits to WAL — marks the dispatch as completed.

On failure (sidecar exception — RESULT flag=failure):
1. Same path, but status = `worker_failed`.
2. Completion handler receives `ctx.worker_failed = true`.
3. Scanner enforces the `ctx.worker_failed` branch at build time.

### Dead dispatch resolution

Call `WorkerClient.check_deadlines(now, worker_deadline_seconds)`.
For each expired dispatch:
1. Commit dead-dispatch WAL entry (frees the in-flight slot).
2. Route to `returns` handler with `ctx.worker_failed = true`.
3. Log a warning.

Deadline is a global comptime constant. No retries — dead
resolution is the minimum mechanism for liveness.

### Checklist

- [ ] Tick loop: dispatch pending WAL entries via WorkerClient.
- [ ] Tick loop: process completed workers (take_completed → pipeline).
- [ ] Tick loop: check deadlines (check_deadlines → dead resolution).
- [ ] Completion enters serial pipeline as normal operation.
- [ ] Dead dispatch commits WAL entry + routes to `returns`.
- [ ] Backpressure: stop dispatching at max_in_flight bound.

---

## Layer 4: Sidecar handle RESULT — dispatch field

The handle RESULT payload gains a dispatch section:
`[status][write_count][writes...][dispatch_count][dispatches...]`

### Server side

`handler_execute` parses dispatches separately from writes after
`sm.commit()`. For each dispatch:
1. Create dispatch WAL entry (recorded in the same WAL entry as
   the handle's SQL writes — atomic).
2. Add to pending index.

The dispatch still commits even if the handle returns a non-ok
status. The status is for the HTTP response. The developer controls
dispatch via code path — don't call `worker.xxx()` in error paths.

### Sidecar side (TS)

`worker.xxx()` appends to a `worker_dispatches` array in the handle
context. The handle RESULT serializer writes `[dispatch_count]`
followed by each dispatch entry after the writes section.

### Checklist

- [ ] Server: parse dispatch section from handle RESULT.
- [ ] Server: create WAL dispatch entries from parsed dispatches.
- [ ] Server: add dispatches to pending index.
- [ ] TS: `worker` object with methods per `[worker]` annotation.
- [ ] TS: handle RESULT serializer includes dispatch section.

---

## Layer 5: Annotation scanner — `[worker]` phase

### Scanner changes

- [ ] Add `worker` to the Phase enum.
- [ ] Parse `[worker] .name` — worker name (function name for CALL).
- [ ] Parse `returns .operation` — completion handler target.
- [ ] Validate `returns` target exists as a registered operation.
- [ ] Suppress "missing match" warning for `returns` target operations
  (completion handlers have `[route]` but no `// match`).
- [ ] Assert completion handler branches on `ctx.worker_failed`.
  Missing branch is a build error.
- [ ] Collect all `[worker]` annotations globally.

### Codegen changes

- [ ] Generate `worker` object with one method per `[worker]`.
- [ ] Method signature matches worker function parameter types.
- [ ] `worker` object available in every handle. No imports.

### Completion operations

Adding a worker requires:
1. Add completion operation to Operation enum in message.zig.
2. Write completion handler file with `[route]`, `[prefetch]`,
   `[handle]`, `[render]` annotations (no `// match`).
3. Run scanner. Same workflow as any handler.

---

## Layer 6: Fuzzer + tooling + cleanup

### Worker boundary fuzzer

- [ ] PRNG-driven, deterministic, seeded.
- [ ] Malformed CALL results: unknown operations, truncated args,
  wrong type tags.
- [ ] Results for non-existent dispatches.
- [ ] Duplicate results (same request_id twice).
- [ ] Assert: every malformed result rejected before state machine.

### Tooling

- [ ] Extend `replay.zig` with `--workers` flag.
- [ ] Show pending dispatches (dispatch entries without completions).
- [ ] Show completed/failed (dispatch + completion pairs).

### Cleanup

- [ ] Remove `worker.zig` (old prototype).
- [ ] Remove `run-worker` from `build.zig`.
- [ ] Update ecommerce example to use worker annotations.

---

## Handler signatures

```
route(req)           → { id, body }
prefetch(ctx, db)    → { ...queries }     // await db.query()
handle(ctx, db)      → status string      // db.execute(), worker.xxx()
render(ctx)          → HTML string        // or render(ctx, db)
worker_fn(args...)   → { ...result }      // async, external IO only
```

`ctx` contains: `id`, `body`, `prefetched`, `status`, `worker_failed`.
Consistent across HTTP handlers and worker completion handlers.

---

## Full example — image upload flow

```typescript
// handlers/upload_image.ts

// [route] .upload_image
// match POST /products/:id/image

// [prefetch] .upload_image
export async function prefetch(ctx, db) {
  const product = await db.query(
    "SELECT * FROM products WHERE id = ?", ctx.id);
  return { product };
}

// [handle] .upload_image
export function handle(ctx, db) {
  db.execute("UPDATE products SET image_status = 'processing' WHERE id = ?",
    ctx.id);
  worker.process_image(ctx.id, ctx.body.url);
  return "processing";
}

// [render] .upload_image
export function render() {
  return `<div class="processing">Processing your image...</div>`;
}

// [worker] .process_image
// returns .image_complete
export async function process_image(product_id: string, url: string) {
  const processed = await imageService.resize(url);
  return { product_id, url: processed.url };
}

// --- Completion handler (no // match — triggered by worker RESULT) ---

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
  if (ctx.prefetched.product.image_status === "done") {
    return "ok";  // idempotent
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

---

## Design rationale

Collected reasoning for each decision. Reference only — don't
reopen without revisiting the full discussion.

**WAL is the queue:** A mutable `_worker_queue` table is derived
state that can diverge — a user can corrupt it with `sqlite3`. The
WAL is the source of truth because the server is the single writer.

**Trust the WAL:** The framework's trust boundary is the server
process. Everything outside is the user's problem. Same principle
as TigerBeetle, different layer.

**No retries:** Automatic retries add hidden state and hide failures.
Dead resolution is the minimum mechanism for liveness. Every dispatch
resolves — success, failure, or dead.

**Worker returns data only:** The framework guarantees every dispatch
resolves with a handler call. The scanner proves failure handling
exists at build time. No path leaves business state stuck.

**Separate dispatch field:** The writes list is for SQL. Worker
dispatch is intent. Separate fields win on all six TB principles vs
marker byte mixing — safety, determinism, boundedness, fuzzable,
right primitive, explicit.

**Backpressure is comptime:** External completion time is unknowable.
Static allocation is explicit — the developer declares the bound.

**Workers are reusable:** Any handle can dispatch any worker. The
scanner generates one global `worker` object.

**Completion handlers are idempotent:** Framework doesn't deduplicate.
The status column is the developer's deduplication key.

**Completion routing is comptime:** Scanner validates at build time.
No runtime string matching.

**Separate connections:** Request handling is fast/bounded (data
plane). Worker dispatch is slow/unbounded (control plane). Don't mix.

**Parallelism preserves determinism:** Non-determinism contained in
sidecar. Results enter the deterministic pipeline in arrival order.

**Completion flows through normal pipeline:** Same annotations, same
route/prefetch/handle/render. Scanner suppresses missing-match for
returns targets.

**`ctx.worker_failed` is a status value:** No new flag on Message.
Reserved status, scanner-enforced branch.

**Interval/cron workers** are a separate feature, not in scope.
