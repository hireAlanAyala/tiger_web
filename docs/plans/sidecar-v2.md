# Sidecar v2 — Unified Pipeline, Async Prefetch, Dumb Executor

The sidecar protocol, pipeline architecture, and worker system are
one dependency chain. This plan covers the bottom-up sequence. Each
phase builds correctly on the one below — no shims, no rework.

```
Phase 1: Unify pipeline       ✓ complete
Phase 2: CALL/RESULT protocol  ✓ complete
Phase 3: Protocol fuzzer       ✓ complete
Phase 4: Async prefetch        ✓ complete (prefetch async, handle/render still blocking)
Phase 5: Scanner refactor       ✓ complete (5a: TS adapter, 5b: Zig dispatch)
Phase 6: Workers               (see worker-v2.md)
```

Phase order revised after Phase 1: protocol before async. Build the
right protocol first, then make it non-blocking.

### Phase 2 progress
- ✓ Frame types: CALL, RESULT, QUERY (with query_id), QUERY_RESULT
- ✓ State machine: call_submit / on_recv / run_to_completion
- ✓ QueryFn with *anyopaque context (TB callback pattern)
- ✓ Handlers sidecar branches wired to state machine
- ✓ Sidecar holds state between CALLs (no pass-through)
- ✓ WriteView.execute_raw for unified WAL recording
- ✓ Zeroed cache pair assertion
- ✓ TS runtime: async QUERY sub-protocol, Promise.all() via query_id Map
- ✓ Handler .ts files: async prefetch with await db.query()
- ✓ PrefetchDb type updated for Promise return
- ✓ Server listens, sidecar connects (listen_and_accept)
- ✓ End-to-end verified: reads, writes, QUERY sub-protocol
- ✓ Cross-language vector tests (call_test.ts)
- ✓ Old 3-RT code deleted (-751 lines)
- ✓ 5 bugs found and fixed during verification (all interface mismatches)
- TODO: when scanner generates Handlers, sidecar Cache type should be
  void — comptime enforcement instead of convention. Blocked on scanner.

## Design decisions

These decisions were reached through discussion and are load-bearing.
Each one closes a design branch — don't reopen without revisiting the
reasoning.

### The sidecar is a dumb function executor

The sidecar has no knowledge of the system. It doesn't read the
manifest, doesn't know about routes, doesn't understand the protocol
beyond "deserialize args, call function, serialize result." The server
owns all decisions — routing, dispatch, auth, WAL, transactions.

The sidecar is a foreign function interface over a socket. The server
sends CALL frames, the sidecar runs functions and returns RESULT
frames. The QUERY sub-protocol lets the sidecar request data from the
server mid-execution.

**Why:** The annotation scanner already knows everything at compile
time. Duplicating that knowledge in the sidecar is two things knowing
the same thing, which is a bug waiting to happen. The sidecar is a
leaf node, like a storage device. It does what it's told.

### The server drives the sidecar

The sidecar connects to the server (not the reverse). The server's
tick loop pushes CALL frames when it has work. The sidecar processes
and responds. The server controls pace, batching, and backpressure.

**Why:** "Don't react directly to external events. Your program should
run at its own pace." (TigerBeetle tiger_style.) The server is the
authority. The tick loop is the heartbeat.

### One pipeline, one Handlers type

The framework has one pipeline: route → prefetch → handle → commit →
render. There is no ZigHandlers vs SidecarHandlers distinction at the
interface level. There is one `Handlers` type, generated at compile
time by the annotation scanner.

`StateMachineType(Storage, Handlers)` is already parameterized on
Handlers. The scanner sees all handler files — `.zig`, `.ts`, `.py`,
whatever — and generates one Handlers type with a comptime dispatch
per operation. Each operation routes to the right runtime:

- Zig handler → direct function call. Zero overhead. Compiler inlines.
- Sidecar handler → CALL over unix socket to the appropriate runtime.

If every handler is Zig, no sidecar connections are opened. If every
handler is TS, no direct calls are generated. If mixed, each
operation takes the right path. The framework doesn't have modes.

Multiple sidecar runtimes can coexist — each language runtime
connects on its own unix socket. The CALL/RESULT protocol is
language-agnostic. The only per-language work is the adapter (how
the runtime deserializes args and calls the function).

**Why:** TB parameterizes `StateMachineType(Storage)` — the Storage
type determines IO behavior. Same pattern. Don't add separate
executor types the user sees. The scanner knows everything at compile
time. One Handlers type, one pipeline, one code path. The language
boundary is an implementation detail, not an architecture.

### Serial pipeline — one request at a time

The commit pipeline processes one request at a time, matching
TigerBeetle's model. Prefetch state lives on the StateMachine — one
slot. There is no concurrent prefetch, no interleaved pipelines, no
per-connection pipeline state.

```
tick: process_inbox picks ONE ready connection
  → prefetch (async: callback resumes)
  → handle (sync for Zig, async CALL for sidecar)
  → commit (sync: transaction + WAL)
  → render (sync for Zig, async CALL for sidecar)
  → encode response, set on connection
  → connection transitions to .sending
  → next tick: process_inbox picks next ready connection
```

While a sidecar CALL is in-flight, the tick loop can still:
- Accept new connections
- Read incoming HTTP requests into recv_buf
- Send in-progress responses
- Manage timeouts
- But NOT start another request's pipeline

**Why:** TigerBeetle commits one prepare at a time, in strict FIFO
order. No concurrent prefetch. No interleaved commits. State lives
on the StateMachine (one set of `prefetch_*` fields), not per-
connection. This eliminates: per-connection state expansion,
transaction boundary changes, ordering ambiguity, and concurrent
access to `prefetch_cache`. The async callback is for "don't block
the tick loop on IO," not for "run multiple pipelines concurrently."

### Prefetch state lives on the StateMachine

Matching TB, prefetch state is stored on the SM:

```zig
prefetch_callback: ?*const fn (*StateMachine) void = null,
prefetch_cache: ?Handlers.Cache = null,
prefetch_identity: ?PrefetchIdentity = null,
```

One set of fields. One request in the pipeline at a time. The
callback fires, the pipeline resumes, the fields are consumed and
cleared. No per-connection cache, no concurrent access.

`Handlers.Cache` is an associated type:
- **ZigHandlers:** `Cache = PrefetchCache` (typed union, as today)
- **SidecarHandlers:** `Cache = SidecarPrefetchResult` (opaque bytes
  or request_id — the sidecar holds the real data)

The pipeline passes `Cache` from prefetch to handle opaquely. It
never looks inside.

**Why:** TB stores prefetch state on the SM because only one prefetch
is active at a time. Same constraint, same solution. No state
expansion.

### Transaction model unchanged

The commit transaction wraps the handle phase, same as today.
`begin_batch` / `commit_batch` around the handle's writes. One
request at a time means one transaction at a time. No change to
the transaction model.

**Why:** Serial pipeline means the transaction model doesn't break.
No concurrent commits, no cross-tick transactions, no ordering
ambiguity. The existing `begin_batch` / `commit_batch` in
`process_inbox` works unchanged.

### QUERY sub-protocol — db.query() as mid-CALL RPC

Prefetch and render need to read from the database. The sidecar
doesn't have DB access — it asks the server. When the user calls
`await db.query(sql, params)`, the sidecar sends a QUERY frame to
the server, the server executes the query, returns a QUERY_RESULT
frame, and the function continues with the data.

Three interfaces, consistent syntax:
- **prefetch** — `async`, `await db.query()` reads pre-commit data
- **handle** — sync, `db.execute()` queues writes, no round trip
- **render** — `async`, `await db.query()` reads post-commit data

The server enforces a comptime max queries per CALL. QUERY frames
during a handle CALL are rejected — protocol-level invariant.

**Why:** `db.query()` does what it says. No declarations pretending
to be data, no functions running twice, no annotations for post-commit
reads. The syntax is consistent across phases. Bounded, scoped to
prefetch and render only, fuzzable.

### Three CALLs per request

Every sidecar request requires three CALLs: prefetch, handle, render.
Prefetch must complete before handle can decide. Handle must commit
before render can read post-mutation state. The phases are sequential
by necessity.

All annotation pipeline phases must be explicitly declared — no
exceptions.

**Why:** Correctness requirement. Collapsing phases means either
render can't read post-mutation state (wrong) or the sidecar does the
commit (breaks dumb executor).

### Error encoding — one flag byte

RESULT frames carry a single flag byte: success (0) or failure (1).
No error detail in the protocol — sidecar logs locally.

**Why:** One byte. No unbounded strings. The server's response to
failure is the same regardless of exception type. The sidecar is
trusted — it's part of the app.

### Startup sequencing — sidecar before HTTP

The server does not accept HTTP connections until the sidecar has
connected. One state transition: not ready → ready.

**Why:** The server cannot serve sidecar-routed requests without the
sidecar. No partial availability.

### Sidecar down past threshold = crash

If the sidecar disconnects, the server gives the hypervisor a bounded
window to recover it. During the window, sidecar-routed requests
receive 503. Past the threshold (comptime constant), the server
crashes.

**Why:** The server must not operate in a degraded state indefinitely.
The threshold gives the hypervisor a bounded chance to act.

---

## Phase 1: Unify the pipeline

**Goal:** One pipeline for both Zig and sidecar handlers via the
existing `Handlers` comptime type parameter. No new abstractions.

**Current state:** Two separate pipelines in `app.zig`:
- `commit_and_encode()` — native Zig path
- `sidecar_commit_and_encode()` — sidecar path with 3-RT protocol

Both use the same shared infrastructure (storage, auth, WAL, tracer,
HTTP encoding) but compose them differently. The branching point is
one `if` in `server.zig:248`.

**Target state:** One pipeline function. `StateMachineType(Storage,
Handlers)` already takes a Handlers parameter. The sidecar works
through this interface, not around it.

### Handlers type design

The scanner generates one Handlers struct per app. The SM holds it
as a runtime instance (`self.handlers: Handlers`), matching TB's
`self.storage: Storage` pattern.

```zig
pub fn StateMachineType(comptime Storage: type, comptime Handlers: type) type {
    return struct {
        storage: Storage,
        handlers: Handlers,
        prefetch_cache: ?Handlers.Cache = null,
        // ...
    };
}
```

The generated Handlers struct:

```zig
pub const Handlers = struct {
    // Runtime state — zero-size if no sidecar operations
    sidecar: SidecarClient,

    pub const Cache = union(Operation) {
        // Zig — typed prefetch results
        get_product: @import("handlers/get_product.zig").Prefetch,
        list_products: @import("handlers/list_products.zig").Prefetch,
        // Sidecar — no local cache, sidecar holds state
        create_order: void,
    };

    // handler_route receives the already-matched operation and params.
    // The pipeline owns the route table lookup. Handlers only runs the
    // user's value transformation function.
    pub fn handler_route(self: *Handlers, comptime op: Operation, params: RouteParams, body: []const u8) ?Message {
        return switch (op) {
            .get_product => @import("handlers/get_product.zig").route(params, body),
            .create_order => self.sidecar.route(op, params, body),
        };
    }

    pub fn handler_prefetch(self: *Handlers, storage: anytype, msg: *const Message) ?Cache {
        return switch (msg.operation) {
            .get_product => .{ .get_product = @import("handlers/get_product.zig").prefetch(storage, msg) orelse return null },
            .create_order => .{ .create_order = self.sidecar.prefetch(storage, msg) orelse return null },
        };
    }

    pub fn handler_execute(self: *Handlers, cache: Cache, msg: Message, fw: anytype, db: anytype) HandleResult {
        return switch (msg.operation) {
            .get_product => @import("handlers/get_product.zig").handle(cache.get_product, msg, fw, db),
            .create_order => self.sidecar.handle(msg, fw, db),
        };
    }

    pub fn handler_render(self: *Handlers, cache: Cache, status: Status, buf: []u8, storage: anytype) []const u8 {
        return switch (msg.operation) {
            .get_product => @import("handlers/get_product.zig").render(cache.get_product, status, buf, storage),
            .create_order => self.sidecar.render(status, buf),
        };
    }
};
```

For a pure-Zig app, the scanner omits the sidecar field. Handlers
is a zero-size struct. All switches inline to direct calls. No
sidecar code survives compilation.

For a pure-sidecar app, all Cache variants are `void`. The Cache
union is one byte (the tag).

For a mixed app, Zig operations have typed Prefetch variants,
sidecar operations have `void` variants. Each operation dispatches
to the right runtime. The compiler inlines Zig paths.

The `void` variants follow TB's pattern — their `PrefetchContext`
union has a `.null` variant. The union must be exhaustive. Unused
variants are zero-cost.

### Checklist

- [x] Route table lookup stays in the pipeline (server/SM).
- [x] Add `handler_route` to the Handlers interface.
- [x] Handlers interface provides: handler_route, handler_prefetch,
  handler_execute, handler_render. Associated type Cache.
- [x] Sidecar connection state on module-level var (runtime check).
  Comptime elimination deferred to scanner-generated Handlers.
- [x] Extract shared response encoding (encode_response).
- [x] Merge commit_and_encode and sidecar_commit_and_encode.
- [x] server.zig: removed sidecar branch and sidecar WAL branch.
- [x] Connection state machine unchanged.
- [x] All tests pass — unit, sim, fuzz smoke.
- [ ] Sidecar availability check before Handlers — deferred to
  server connection management (Phase 2 remaining).

### Phase 1 is a manual refactor

App.zig already has the dispatch switches (dispatch_prefetch,
dispatch_execute, dispatch_render) and the PrefetchCache union.
Phase 1 restructures this existing code into the Handlers struct
shape. The sidecar dispatch arms are added alongside the Zig ones
in the same switches. Same code, new shape.

No scanner changes. No new tooling. The scanner generates the
Handlers type later (Phase 3) when the protocol changes and multi-
language support is complete. Phase 1 is one thing: restructure.

### Design constraints

- One Handlers type. No ZigHandlers / SidecarHandlers split at the
  interface level. The scanner generates one type with per-operation
  dispatch.
- Zig operations must have zero overhead. The comptime switch inlines
  the direct call path. No function pointer indirection.
- The pipeline function must not branch on language or runtime. It
  calls Handlers. Handlers dispatches.
- PrefetchCache stays on the StateMachine. The Cache associated type
  accommodates both Zig (typed union) and sidecar (protocol state)
  operations.

---

## Phase 2: CALL/RESULT protocol

**Goal:** Replace the 3-RT sidecar protocol with the dumb executor
model. The Handlers sidecar branches send CALL frames and receive
RESULT frames. The QUERY sub-protocol enables `await db.query()` in
prefetch and render. Eliminates Phase 1's zeroed cache and cross-
phase state awkwardness.

**Current state:** Handlers sidecar branches use the 3-RT protocol
(from Phase 1). The sidecar process reads the manifest, has a
dispatch table, understands routing. Cache is zeroed for sidecar
operations. SidecarClient holds cross-phase state.

**Target state:** Handlers sidecar branches send CALL/RESULT frames.
The sidecar process is a dumb function registry. Each phase is a
separate CALL with explicit args — no zeroed cache, no cross-phase
state. The server owns all knowledge.

### Serial pipeline model

One request in the pipeline at a time. Matching TigerBeetle:

```
process_inbox:
  1. Pick ONE ready connection
  2. prefetch(msg, callback) — may return immediately or pend
  3. If pending: set commit_stage = .prefetch, return
     (tick continues: accept, recv, send, timeout — but no new pipeline)
  4. Callback fires (same tick for Zig, later tick for sidecar)
  5. commit_stage advances: handle → commit → render → encode → send
  6. Pipeline complete. commit_stage = .idle
  7. Next tick: process_inbox picks next ready connection
```

The server tracks pipeline state with a `commit_stage` enum on the
server (not the connection), matching TB's `replica.commit_stage`:

```zig
const CommitStage = enum {
    idle,              // No request in pipeline
    prefetch,          // Waiting for prefetch callback
    handle,            // Waiting for handle callback (sidecar)
    commit,            // Executing writes in transaction
    render,            // Waiting for render callback (sidecar)
    encode,            // Building HTTP response
};
```

For ZigHandlers, all stages complete in one tick (callbacks fire
immediately). For SidecarHandlers, prefetch/handle/render stages
may span ticks (callback fires on epoll RESULT).

### Protocol frames

| Frame | Direction | Fields |
|-------|-----------|--------|
| CALL | Server → Sidecar | `request_id`, `function_name`, `args` |
| RESULT | Sidecar → Server | `request_id`, `flag` (success/failure), `result` |
| QUERY | Sidecar → Server | `request_id`, `sql`, `params` |
| QUERY_RESULT | Server → Sidecar | `request_id`, `rows` |

- All payloads use self-describing binary row format.
- QUERY/QUERY_RESULT is a sub-protocol within a CALL. The sidecar
  can request data mid-execution.
- RESULT flag byte: 0 = success, 1 = failure. No error detail in
  protocol — sidecar logs locally.

### Checklist

- [x] Define frame format: CALL, RESULT, QUERY (with query_id),
  QUERY_RESULT (echoes query_id). Enables Promise.all().
- [x] Reimplement Handlers sidecar branches using CALL/RESULT state
  machine (call_submit + on_recv + run_to_completion).
- [x] QUERY sub-protocol: server executes SQL from QUERY frames via
  QueryFn callback with *anyopaque context. Bounded by
  comptime queries_max.
- [x] Server rejects QUERY frames during handle CALLs — runtime null
  check on query_fn (comptime→runtime tradeoff documented).
- [x] Sidecar runtime (TypeScript): adapters/call_runtime.ts. Async
  QUERY sub-protocol, Promise.all() via query_id Map. Reference
  implementation — other languages reimplement the spec.
- [x] Handler .ts files: async prefetch with await db.query().
- [x] Server accepts sidecar connection on unix socket
  (listen_and_accept — server listens, sidecar connects).
- [x] Server does not accept HTTP until sidecar is connected.
- [x] Integration test: server + TS runtime end-to-end verified.
- [x] Cross-language vector tests (call_test.ts).
- [x] Remove: old 3-RT methods from sidecar.zig, sidecar_test.zig.
- [x] MessageTag removed from protocol.zig and serde.ts.
- [x] dispatch.generated.ts deleted.
- [ ] Sidecar availability check before Handlers — deferred (5b).
- [ ] Sidecar reconnection: bounded window, crash past threshold —
  deferred (connect/try_reconnect kept, needs revision).
- [ ] (Deferred) Extend SimIO to fault-inject on sidecar fd.

### User-space syntax

Three phases, consistent interfaces:

```typescript
// [prefetch]
export async function prefetch(msg, db) {
  const product = await db.query("SELECT * FROM products WHERE id = ?", msg.id);
  return { product };
}

// [handle]
export function handle(ctx, db) {
  db.execute("UPDATE products SET name = ? WHERE id = ?", ctx.body.name, ctx.params.id);
  return "ok";
}

// [render]
export async function render(ctx, db) {
  const product = await db.query(
    "SELECT p.*, c.name as category FROM products p JOIN categories c ON ... WHERE p.id = ?",
    ctx.params.id);
  return `<div>${product.name} - ${product.category}</div>`;
}
```

- `await db.query()` — same in prefetch and render. QUERY frame to
  server, awaits QUERY_RESULT.
- `db.execute()` — handle only. Queues write, no round trip.
- Render can be sync (no db.query, returns string) or async (uses
  db.query, returns promise). Framework detects.

### Request pipeline (three CALLs, serial)

```
tick N: process_inbox picks connection A
  commit_stage = .prefetch
  → CALL prefetch (server sends, tick continues IO work)

tick N+1: sidecar RESULT arrives on epoll
  commit_stage = .handle
  → CALL handle (server sends, tick continues IO work)

tick N+2: sidecar RESULT arrives
  commit_stage = .commit
  → server executes writes in transaction, WAL records
  commit_stage = .render
  → CALL render (server sends, tick continues IO work)

tick N+3: sidecar RESULT arrives
  commit_stage = .encode
  → server encodes HTTP response, sets on connection
  commit_stage = .idle
  → connection A transitions to .sending

tick N+4: process_inbox picks connection B
  ...
```

For Zig handlers, all stages complete in tick N (immediate callbacks).
For sidecar handlers, stages may span ticks. The server does IO work
(accept, recv, send, timeout) in every tick regardless.

---

## Phase 3: Protocol fuzzer

**Goal:** Prove the CALL/RESULT protocol boundary is correct under
adversarial input before building async on top. This is a gate —
don't start Phase 4 until the fuzzer runs clean.

Rewrite `sidecar_fuzz.zig` for the CALL/RESULT protocol. The old
fuzzer tests the 3-RT protocol (dead code). The new fuzzer exercises
the state machine (`call_submit` / `on_recv`) with PRNG-driven
malformed input.

### What to fuzz

- Malformed RESULT frames: truncated, wrong tag, invalid flag byte,
  oversized payload, zero-length payload.
- Malformed QUERY_RESULT frames: truncated row set, wrong query_id,
  invalid type tags, oversized values.
- Protocol violations: QUERY during no-query CALL, RESULT with
  unknown request_id, duplicate RESULT for same CALL.
- Disconnect mid-exchange: sidecar closes socket after CALL sent,
  after QUERY sent, after partial RESULT.
- Query count exceeded: more QUERY frames than queries_max.
- Valid exchanges interleaved with malformed ones: verify the state
  machine recovers to .idle after each failure.

### Assertion targets

- Every malformed input is rejected before reaching the state machine
  (no handler code runs on bad data).
- The state machine transitions to .failed on every error, never
  .complete with corrupted data.
- After failure, reset_call_state returns to .idle — the next CALL
  can proceed.
- No panics, no undefined behavior, no memory safety issues.

### What to defer

- SimIO sidecar fd fault injection — relevant for Phase 4 (async),
  not Phase 3 (sync blocking).
- Automated integration test — fuzzer is more valuable. Integration
  tests verify happy paths. Fuzzers verify the boundary.
- Cross-language vector tests — already done (call_test.ts).

---

## Phase 4: Async prefetch

**Goal:** Prefetch takes a callback and returns void, matching
TigerBeetle's pattern. The pipeline is serial — one request at a
time. The async callback is for "don't block the tick loop on IO,"
not for "run multiple pipelines concurrently."

### Implementation (complete)

Used `commit_dispatch` (TB's stage-driven state machine) instead of
the originally planned callback approach. Simpler — no callback
storage, no context pointers for resume.

- [x] CommitStage enum on server: idle, prefetch, handle, render.
- [x] commit_dispatch: stage loop, each stage completes or pends.
- [x] PrefetchResult enum: complete/busy/pending.
- [x] process_inbox: parse, translate, start pipeline via commit_dispatch.
- [x] Idempotent handler_prefetch/handler_render: safe for resume.
- [x] io.readable: epoll notification for sidecar fd.
- [x] sidecar_recv_callback: drives on_recv, resumes commit_dispatch.
- [x] Prefetch + render: async (QUERY sub-protocol, epoll-driven).
- [x] Handle: sync — intentionally blocking. One round trip, no
  QUERY sub-protocol, microseconds on unix socket. Making it async
  would require splitting sm.commit (WriteView + WAL + response
  building) for negligible latency gain.
- [x] Route: sync — one round trip, no QUERY.
- [x] Transaction boundary: begin/commit_batch wraps .handle stage.
- [x] Time: set once per pipeline, not per tick.
- [x] Invariant assertions at stage entry.
- [x] Verified end-to-end with TS runtime.

### Throughput note

Serial pipeline means the sidecar CALL latency directly impacts
throughput — one request at a time, each waiting for the sidecar.
This is the correct starting point. TB also commits one at a time.
Pipelining (preparing request N+1 while committing N) is a future
optimization — see "Future: pipelining" section below.

---

## Phase 5: Scanner refactor

Two parts: TS-side (done) and Zig-side (deferred).

### Phase 5a: TS adapter generates CALL/RESULT data ✓

- [x] TypeScript adapter generates handlers.generated.ts (imports,
  modules registry, route table) from manifest.json.
- [x] call_runtime.ts imports from generated file — no hardcoded
  handler imports or route table.
- [x] npm run build generates handlers.generated.ts, not old dispatch.
- [x] dispatch.generated.ts deleted. Old adapter test deleted.
- [x] MessageTag removed from serde.ts (no consumers).
- [x] test.ts updated for new protocol direction.

### Phase 5b: Zig scanner generates Handlers type (closed)

**Goal:** The annotation scanner generates a Zig file that replaces
the hand-written HandlersType in app.zig. Eliminates runtime sidecar
checks and zeroed cache convention.

**What changes:**

The scanner already generates `routes.generated.zig` (comptime route
table). The same pattern generates `handlers.generated.zig`:

- **PrefetchCache union** — typed Prefetch variants for Zig handlers,
  `void` for sidecar handlers. Operation-specific at comptime.
- **handler_prefetch/execute/render switches** — Zig operations call
  handler functions directly, sidecar operations dispatch via
  CALL/RESULT. No runtime `if (sidecar)` check.
- **is_sidecar_operation(op)** — comptime function replacing runtime
  is_sidecar_pending. Each operation is tagged Zig or sidecar at
  compile time from file extension.

**What this enables:**

- Comptime void Cache — zeroed cache convention eliminated. The
  invariant "sidecar handler_execute never reads cache" becomes
  comptime-enforced (void has no fields to read).
- Dead code elimination — pure-Zig apps compile zero sidecar code.
  Pure-sidecar apps compile zero native dispatch. Mixed apps get
  per-operation comptime dispatch.
- Module-level `sidecar` var removed — sidecar connection state
  moves to the generated Handlers type or the server.

**What was done:**

- [x] Scanner emits handlers.generated.zig with PrefetchCache,
  dispatch_prefetch/execute/render, is_sidecar_operation, and
  helper functions (prefetch_one, execute_one, render_one).
- [x] PrefetchCache uses void for sidecar operations (generated).
- [x] app.zig imports PrefetchCache + dispatch from generated file.

**What stays as-is (won't do):**

- Runtime `if (sidecar)` checks in HandlersType — INTENTIONAL.
  The sidecar decision is framework orchestration (CALL/RESULT
  protocol, async epoll, state management), not dispatch. The
  generated file is pure dispatch: handler module → function call.
  Moving sidecar logic into generated code would couple the scanner
  to the protocol layer. Wrong separation of concerns.
- Module-level `sidecar` var — framework state for the sidecar
  connection. Stays in app.zig with the HandlersType.
- Sidecar availability check — stays in server.zig pipeline code.

---

## Phase 6: Workers

Built on the CALL/RESULT protocol from Phase 3. See
[worker-v2.md](worker-v2.md) for full design decisions, checklist,
and examples.

Summary: Workers are async functions dispatched by the tick loop.
The WAL is the queue. `worker.xxx()` in handle is sugar for a WAL
entry. The sidecar runs the worker function via CALL. Results route
to a `returns` handler. `ctx.worker_failed` is enforced by the
scanner. Backpressure is a comptime constant. Dead dispatch
resolution prevents slot leaks.

Worker CALLs are in-flight concurrently with the serial request
pipeline. The pipeline processes one request at a time, but worker
CALLs are long-running and don't block the pipeline. Worker RESULT
arrivals enter the pipeline as completion operations — processed
in FIFO order like any other request.

---

## Dependency graph

```
Phase 1 (unify pipeline) ✓
    ↓
Phase 2 (CALL/RESULT protocol) ✓
    ↓
Phase 3 (protocol fuzzer) ✓
    ↓
Phase 4 (async prefetch) ✓
    ↓
Phase 5 (scanner refactor)
    ↓
Phase 6 (workers — worker-v2.md)
```

Each phase builds on the one below. Each phase is independently
testable — all existing tests pass after each phase.

---

## Future: pipelining (deferred)

Prepare request N+1's prefetch while committing request N. Overlaps
pipeline stages. ~3x throughput improvement for sidecar handlers
(unix socket round trips dominate — three per request at ~50-100μs
each).

### Benchmark context

Benchmarking with `hey -c 128` crashed the server — 128 concurrent
connections hit the serial pipeline which processes one at a time.
Connection pool fills up, connections timeout, server runs out of
resources. The bottleneck is the serial pipeline draining slower
than connections arrive. Use `hey -c 1` or `hey -c 4` for serial
pipeline benchmarks.

### Workbench estimates

```
┌─────────────────────────────────┬───────────────┬───────────────┐
│              Setup              │    SQLite     │   Postgres    │
├─────────────────────────────────┼───────────────┼───────────────┤
│ epoll + sync prefetch           │ ~50K req/s    │ ~2K req/s     │
├─────────────────────────────────┼───────────────┼───────────────┤
│ epoll + async prefetch (done)   │ ~50K req/s    │ ~15-25K req/s │
├─────────────────────────────────┼───────────────┼───────────────┤
│ io_uring + async prefetch       │ ~55-60K req/s │ ~30-50K req/s │
└─────────────────────────────────┴───────────────┴───────────────┘
```

Async prefetch (Phase 4) was the high-value change — 7-12x for
network-bound storage (Postgres). Pipelining is incremental (~3x
for sidecar). io_uring is a different axis (IO layer, not pipeline).

### Server robustness

The benchmark crash exposed a separate issue: the server doesn't
handle connection pool exhaustion gracefully. Should reject new
connections when the pool is full or pipeline queue is too deep,
not crash. This is a framework robustness fix, independent of
pipelining.
