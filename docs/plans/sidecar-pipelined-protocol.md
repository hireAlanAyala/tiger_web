# Sidecar pipelined protocol — saturated dispatch

## Principle

The number of round trips per request doesn't limit throughput
if: (1) every RT is synchronous and stateless, enabling pipelining
across requests, and (2) the per-frame overhead is small enough
that the bottleneck is compute, not protocol.

Keep all 4 user functions. No magic. Explicit data flow. The
framework pipelines transparently.

## Current state

1-CALL protocol, QUERY sub-protocol:
- 1 process: 17K req/s
- 4 processes: 36K req/s
- Fastify: 49K req/s
- Native Zig: 67K req/s

Bottleneck: QUERY sub-protocol blocks the TS process mid-request
(await). Can't interleave. Single process sits idle 75% of the
time.

## Design: 4 stateless RTs, pipelined

Each user function is one synchronous RT. No await. No db object.
The framework holds all state between RTs. The sidecar is a
stateless function executor.

### RT1: route

```
CALL  → { method, path, query_params, body }
RESULT ← { operation, id, params }
```

TS runs `route()`. Parses request, returns operation + extracted
params. Pure function of the request.

### RT2: prefetch

```
CALL  → { operation, id, params (from route) }
RESULT ← [sql, ...param_values]
```

TS runs `prefetch()`. Returns a query declaration — array where
index 0 is SQL, rest are param values. Pure function of the
message.

**Framework executes the SQL** on its own SQLite connection.
Single storage implementation. No db library in sidecar.

### RT3: handle

```
CALL  → { operation, id, params, body, rows (from prefetch SQL) }
RESULT ← { status, writes: [[sql, ...params], ...] }
```

TS runs `handle()`. Receives prefetched rows as `ctx.rows`.
Returns status + write declarations (same `[sql, ...params]`
array format). `ctx.write()` accumulates writes, collected when
the function returns.

### RT4: render

```
CALL  → { operation, status, rows, params, body }
RESULT ← html_string
```

TS runs `render()`. Returns HTML string. Pure function of status
+ data.

**Framework executes writes** from RT3 (serial, handle_lock, WAL),
encodes HTTP response with RT4 HTML, sends.

## User space

```typescript
// [route] .cancel_order
// match POST /orders/:id/cancel
export function route(req) {
  return { operation: "cancel_order", id: req.params.id };
}

// [prefetch] .cancel_order
export function prefetch(msg) {
  return ["SELECT id, status FROM orders WHERE id = ?", msg.id];
}

// [handle] .cancel_order
export function handle(ctx) {
  const order = ctx.rows[0];
  if (!order) return "not_found";
  if (order.status !== 0) return "not_pending";
  ctx.write(["UPDATE orders SET status = 3 WHERE id = ?", ctx.id]);
  return "ok";
}

// [render] .cancel_order
export function render(ctx) {
  if (ctx.status === "not_found") return "<div>Not found</div>";
  if (ctx.status === "not_pending") return "<div>Can't cancel</div>";
  return "<div>Cancelled</div>";
}
```

Four functions. No async. No db object. No imports. Every piece
of data is visible — the user names everything, the framework
passes it through.

Prefetch returns `[sql, ...params]`. Handle writes via
`ctx.write([sql, ...params])`. Same syntax for reads and writes.
Works in any language.

## Pipelining: saturate 1 process

Every RT is synchronous — returns immediately, holds no state.
The framework holds inter-RT state per request. This enables
interleaving RTs from different requests on one TS connection:

```
TS:  [route-A] [route-B] [pfetch-A] [route-C] [pfetch-B] [handle-A] [pfetch-C] [render-A] [handle-B] ...
```

The sidecar is always processing a function call. The framework
is always processing a SQL read, a write commit, or a frame.
Neither side idles. One process, fully saturated.

The pipeline depth = number of concurrent requests in different
stages. With 8+ HTTP connections feeding the pipeline, every RT
slot is filled.

**Benchmark validation:** pipelining assumes the HTTP arrival rate
sustains the pipeline. Under load gen (128 connections, tight
loop, no think time), requests are always available. If the
benchmark shows projected throughput, the pipeline fills
correctly. If lower, the framework dispatch has gaps (not sending
CALLs fast enough). Production traffic has lower arrival rates
(client latency, think time) — the pipeline drains gracefully in
gaps. This is correct, not a flaw. The pipeline must not be the
bottleneck when requests are available, but need not guarantee
saturation when requests aren't.

## Why pipelining + 4 RTs works

Throughput = 1 / max(T_ts, T_zig). With pipelining, TS and Zig
work overlap across requests.

**T_ts per request:** ~12µs (route + prefetch + handle + render)
**T_zig per request:** ~10µs (HTTP parse + SQL read + SQL write
+ response encode) + N_frames × frame_cost

With unix sockets (frame_cost ~2µs):
- 8 frames: T_zig = 10 + 16 = 26µs → ceiling ~38K
- 6 frames: T_zig = 10 + 12 = 22µs → ceiling ~45K

With shared memory (frame_cost ~0.5µs):
- 8 frames: T_zig = 10 + 4 = 14µs → ceiling ~71K
- 6 frames: T_zig = 10 + 3 = 13µs → ceiling ~77K

**With shared memory, 8 frames and 2 frames have nearly the same
throughput.** Frame cost is negligible. Keep all 4 functions.

## RT0: prefetch extraction (optimization)

The annotation scanner can extract prefetch SQL + param mappings
at build time. Prefetch is a pure function returning
`[sql_literal, msg.field, ...]`. The scanner parses the return
expression and extracts:
- SQL string (index 0)
- Param field names (indices 1+ are `msg.field` references)

The scanner enforces purity: if the return expression isn't
`[literal, msg.field, ...]`, the build fails with an error. No
fallback — this is the API contract. Relax later if needed.

At runtime, the framework reads param values from the message
and executes the SQL natively. **Skips RT2 entirely.** Reduces
from 8 frames to 6 per request.

Every typical CRUD handler qualifies: the prefetch SQL is a
string literal, the params are `msg.field` pass-throughs.

## Projected throughput

| Phase | Change | 1 proc req/s | vs Fastify |
|---|---|---|---|
| Current | 1-CALL + QUERY | 17K | 35% |
| Phase 1+2 | Stateless 4-RT + pipelining | 38K | 78% |
| Phase 3 | + RT0 prefetch extraction | 43-50K | 88-102% |
| Phase 4 | + Shared memory | 65-71K | 133-145% |

## Determinism: write-boundary ordering

TB-correct. The pipeline overlaps stages across requests except
across the write boundary.

**Rule:** a request's prefetch (RT2 SQL execution) must not run
until all prior mutations' writes have committed.

The write serializer maintains a **commit sequence number.**

**Sequence numbers are assigned after RT1 (route), not at HTTP
arrival.** The framework doesn't know whether a request is a
mutation until route completes and identifies the operation.
Assigning at HTTP arrival creates a window where the framework
can't classify requests. After RT1, `is_mutation()` is known.

**RT1 (route) is processed sequentially for all requests** before
pipelining the remaining stages. Route is cheap (~1µs of TS
compute) — pure request parsing, no I/O. Sequential route
preserves HTTP arrival order and ensures every request is
classified (read vs write) before entering the pipelined stages.
After route, the framework has: operation, sequence number, and
read/write classification. Prefetch/handle/render pipeline freely
within the write-boundary rules.

Before executing prefetch SQL, the framework checks: "have all
mutations with lower sequence numbers committed?" If yes, proceed.
If no, wait.

```
Read A  (seq=1): RT1 → RT2 (no wait)           → RT3 → RT4
Read B  (seq=2): RT1 → RT2 (no wait)           → RT3 → RT4
Write C (seq=3): RT1 → RT2 (no wait, A/B read) → RT3 (write queued)
Read D  (seq=4): RT1 → RT2 (waits for C)       → RT3 → RT4
Write E (seq=5): RT1 → RT2 (waits for C)       → RT3 (write queued)
Read F  (seq=6): RT1 → RT2 (waits for C, E)    → RT3 → RT4
```

**Reads flow freely.** Only a read-after-write (or write-after-
write) boundary causes a wait. This matches SQLite WAL's natural
model and TB's commit ordering.

**Throughput impact:** proportional to write ratio. At 70% reads
/ 30% writes (typical CRUD), nearly all requests pipeline freely.
The write commit window is ~5µs — at 38K req/s, ~0.2 requests
are waiting on average. Negligible. At 100% writes, the pipeline
collapses to sequential — same as current model and Fastify.
No regression.

Additional guarantees:
- Zig owns all SQLite reads and writes
- Reads use WAL snapshots — concurrent, consistent
- TS is a pure stateless function: (data in) → (data out)
- Write ordering controlled by Zig, not TS

## Single storage implementation

Zig owns all SQLite. The sidecar has no db library, no
connection, no SQL execution code. Prefetch declares queries,
handle declares writes. The framework executes both.

This enables:
- **Prefetch deduplication** — same SQL + params → execute once
- **Write batching** — batch writes into one SQLite transaction
- **Speculative prefetch** — start N+1's read during N's write
- **Language-agnostic sidecar** — no database driver needed

## Additional optimizations

**Native read-only fast path (0 RT).** Future: if handle returns
"ok" with no writes and render is a known template, skip the
sidecar entirely. Prefetch → native render → send. 0 frames,
67K for reads.

**Prefetch deduplication.** Same `(sql, params)` hash → execute
once, share result across concurrent requests.

## Implementation: clean rewrite, not shim

The current server pipeline was built for the 1:1
slot-to-process model with sequential stages. Shimming pipelining
onto it means fighting existing assumptions at every turn — slot
ownership, connection pairing, dispatch ordering. The pipelined
dispatch should be a clean implementation informed by everything
we learned, not a patch on the old code.

### Core abstractions

**Pipeline pool.** A bounded array of pipeline entries, statically
allocated at init. `pipeline_depth_max` is a comptime constant.
Each entry holds one request's state as it progresses through
stages. Replaces the current slot array — same concept, decoupled
from sidecar connection count. When the pool is full, incoming
requests are suspended (backpressure). When an entry completes,
the next suspended connection is dispatched immediately.

**Pipeline entry (request state).** Per-request struct that moves
through stages independently. Holds: operation, params, rows,
status, writes, html — accumulated across RTs. Sequence number
assigned after RT1 for write-boundary ordering.

**No SidecarClient.** The dispatch module owns the frame protocol
directly. It writes CALL frames into the bus send queue and
reads RESULT frames from the bus callback. No intermediary
client object. `SidecarClient` was designed for 1 CALL in flight
with shared state — it doesn't fit the pipelined model. The
dispatch module is the protocol state machine, per-entry.

**Per-entry buffers, sized to stage.** Each entry owns small
buffers for route/prefetch/handle results (~256 bytes each).
Render uses a single shared buffer (`render_scratch_buf` pattern)
— only one entry renders at a time since render is the last
stage before encoding into the connection's send_buf.

This avoids 256KB × N entries. At 32 entries: ~24KB of per-entry
buffers + 64KB shared render buffer = ~88KB total. Bounded,
sized to actual stage maximums.

**Frame sending.** The dispatch module builds CALL frames and
sends via `bus.send_frame_to(connection_index, payload)`.
Frames are built directly into bus pool messages (zero-copy,
same as current `call_submit` pattern). No intermediate buffer.

**Frame receiving.** The bus delivers frames via `on_frame_fn`.
The dispatch module parses request_id, finds the entry, copies
result data into the entry's stage-specific buffer. No shared
state between entries. Each entry is self-contained.

**Re-entrancy guard.** `advance()` sets `dispatch_entered` on
entry, clears via `defer`. Prevents recursive iteration when
a callback triggered by `advance()` calls `advance()` again.
TB's `commit_dispatch` pattern.

**Write-boundary watermark.** `pending_mutation_count` +
`lowest_pending_mutation_seq` enable O(1) `can_prefetch` check.
No scan of all entries. `recompute_lowest_pending_mutation`
called only on write commit (infrequent).

**Invariants.** `defer self.invariants()` after every `on_frame`
and `advance`. Cross-checks: no duplicate request_ids, valid
operations for non-free entries, pending mutation count matches
actual entries in mutation stages.

**Write serializer.** Not a deferred queue — writes execute
immediately when the RT3 RESULT arrives, within the event
callback, under the handle_lock. Acquire lock, execute writes
in SQLite transaction, WAL append, release lock. Same synchronous
path as the current `commit_dispatch` handle stage. The "queue"
is only for ordering when two RT3 RESULTs arrive in the same
epoll batch — the lock serializes them naturally.

### Phase 1+2: Stateless protocol + pipelining (one implementation)

These phases are one implementation, separated only for testing.
The dispatch layer is designed for pipelining from the start.

1. Define wire format: 4 CALL/RESULT pairs, request_id matching
2. New sidecar dispatch module — request queue, function executor,
   write serializer
3. Update call_runtime.ts — stateless dispatch per function name,
   no global request state, interleaved RTs from different requests
4. Prefetch returns `[sql, ...params]`, handle uses `ctx.write()`
5. Framework executes prefetch SQL and handle writes
6. Pipelining: send next available CALL immediately after any
   RESULT, don't wait for current request to complete all RTs
7. Update sim tests — new sidecar format
8. Benchmark: 1 proc pipelined vs current

### Gate: validate projections before proceeding

Phase 1+2 benchmark must show pipelined throughput within 80%
of the projected 38K (i.e. >30K with 1 proc). If lower, the
pipelining model has a flaw — diagnose before proceeding to
Phase 3. If higher, the projections are conservative and
Phases 3+4 are worth pursuing.

Do not commit to Phase 3 or 4 based on arithmetic alone.

### Phase 3: RT0 prefetch extraction

9. Scanner extracts prefetch SQL + param mappings from source
10. Build error on non-extractable patterns
11. Framework executes prefetch natively for extracted handlers
12. Benchmark: RT0 impact

### Phase 4: Shared memory transport

13. Replace unix socket with mmap + futex for sidecar frames
14. Protocol (CALL/RESULT with request_id) unchanged
15. Benchmark: final throughput numbers

## Backpressure

The request queue must be bounded. If HTTP requests arrive faster
than the pipeline drains, the queue must not grow without limit.

**Mechanism:** configurable max queue depth (comptime constant,
like `max_connections`). When the queue is full, new HTTP
requests are suspended at the connection level — same pattern as
the current `suspend_connection` but applied to queue admission
instead of slot availability. The server stops calling
`on_ready_fn` until a queue slot frees up.

**Why not reject connections:** a full queue means the pipeline
is busy, not broken. The client's TCP connection stays open.
When a request completes and drains from the queue, the next
suspended connection is dispatched immediately (same pattern as
the `pipeline_reset` → resume fix we implemented).

**Sizing:** queue depth = max in-flight requests. Each request
holds a state struct (~1KB: operation, params, rows pointer,
status, writes pointer, html pointer). At depth 128: ~128KB.
Bounded by the constant, not by traffic.

## Error recovery

If the TS process crashes mid-pipeline, multiple requests are
in-flight at different stages. The framework must recover all
of them.

**Detection:** the sidecar bus connection closes (same as today).
`sidecar_on_close` fires.

**Recovery:** iterate all in-flight request states. For each:
- If pre-write (RT1, RT2, RT3 pending): discard. Return 503 to
  the HTTP connection.
- If post-write (RT3 complete, writes committed, RT4 pending):
  writes are durable. Return a fallback HTML response (same
  pattern as the current `render_crash_fallback`).
- If completed (RT4 done, response in send buffer): no action,
  the response is already being sent.

**Key invariant:** writes are never lost. The write serializer
commits to SQLite before advancing to RT4. If the sidecar dies
between RT3 and RT4, the write is committed but the render is
lost. The framework returns a minimal "operation succeeded"
response — the data is safe.

**Reconnection:** the sidecar process restarts (supervisor), sends
READY, the framework resumes dispatching new requests. In-flight
requests that received 503 are retried by the client (standard
HTTP retry for 503).

## TS runtime: per-request state isolation

The current TS runtime holds a single global `requestState`
object mutated across CALLs. With pipelined interleaved RTs,
this breaks — route-A's state would leak into handle-B.

**Replace with a Map keyed by request_id.** The request_id is
already in every CALL frame.

```typescript
const requests = new Map<number, {
  operation: string;
  id: string;
  body: any;
  params: any;
  rows: any;
  status: string;
}>();
```

**Lifecycle:**
- `route` CALL: create entry, store operation + params
- `prefetch` CALL: read entry, return query declaration
- `handle` CALL: read entry, add rows from framework, collect
  writes, store status
- `render` CALL: read entry, return HTML, **delete entry**

**Cleanup on error:** TTL sweep clears entries older than the
sidecar timeout (5 seconds). No cancel frame — adding a new
frame type for an edge case (client disconnect mid-request)
adds protocol complexity. The TTL sweep handles it. If the
sidecar reconnects, all entries are cleared (fresh connection,
fresh Map).

**Concurrency safety:** every function is synchronous (no await).
Node's event loop executes them one at a time within a tick.
Multiple CALLs arrive in one socket read but are processed
sequentially in `processFrames()`. No actual concurrency — just
interleaving. The Map provides isolation, not synchronization.

**Memory:** ~5KB per entry (route result + body + rows pointer +
status). At 128 concurrent requests: ~640KB. Negligible.

**This is strictly better than the current global object** even
without pipelining — isolated by construction, explicit lifecycle,
observable pipeline depth via `requests.size`.

## Sim test coverage

The clean rewrite replaces the old dispatch model. Existing
sim_sidecar.zig tests don't apply — new tests for the pipelined
dispatch. Transport-level tests (sidecar_fuzz.zig,
message_bus_fuzz.zig) are unchanged.

**Interleaved RTs.** Two requests in the pipeline simultaneously.
A is in RT3 (handle) while B is in RT1 (route). Both complete
correctly with isolated state. No cross-contamination.

**Write-boundary ordering.** Write C (seq=3) then read D (seq=4).
D's prefetch must see C's committed writes. Concrete: create
product → list products → assert the product appears in the list.

**Read-read concurrency.** Two concurrent reads pipeline without
waiting on each other. Both complete in fewer ticks than
sequential execution.

**Write-write ordering.** Two mutations in sequence. First write
commits before second write's prefetch runs. Order preserved
regardless of pipeline depth.

**Sidecar crash with multiple in-flight.** 3 requests in different
stages. Sidecar dies. Pre-write requests get 503. Post-write
request (writes committed, render pending) gets fallback HTML.
All request states cleaned up. No leaked entries.

**Backpressure.** Queue full (N requests in flight). New HTTP
request arrives. Connection is suspended. Request completes,
queue drains, suspended connection resumes immediately.

**Cancel/cleanup.** Request starts RT1, HTTP connection closes
(client disconnect) before RT2. Framework discards pipeline entry.
TS Map entry cleared by TTL sweep. No leaked state.

**Pipelining saturation.** N requests dispatched rapidly. TS
process receives interleaved CALLs without gaps. Measure ticks to
complete vs sequential baseline — concurrent must be faster.

**Request_id uniqueness.** No two in-flight requests share a
request_id. Framework ensures uniqueness across the pipeline.

**Empty pipeline drain.** All requests complete. No leaked request
states. Queue empty. SimSidecar Map equivalent empty.

## Migration

Protocol version bumps to 2. New CALL names per function:
"route", "prefetch", "handle", "render". Old 1-CALL "request"
stays for version 1 sidecars. Version negotiated during READY
handshake. The old sidecar_handlers.zig is removed after
migration — the new dispatch module replaces it entirely.
