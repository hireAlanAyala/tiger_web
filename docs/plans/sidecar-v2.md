# Sidecar v2 — Unified Pipeline, Async Prefetch, Dumb Executor

The sidecar protocol, pipeline architecture, and worker system are
one dependency chain. This plan covers the bottom-up sequence. Each
phase builds correctly on the one below — no shims, no rework.

```
Phase 1: Unify pipeline       (Handlers type parameter, remove two-path branching) ✓
Phase 2: CALL/RESULT protocol  (dumb executor, QUERY sub-protocol)
Phase 3: Async prefetch        (callback-driven, serial pipeline, TB pattern)
Phase 4: Workers               (see worker-v2.md)
```

Phase order revised after Phase 1: protocol before async. Making the
old 3-RT protocol async would be wasted work — Phase 2 replaces it
entirely. Build the right protocol first (eliminates Phase 1's zeroed
cache and cross-phase state awkwardness), then make it non-blocking.

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

- [ ] Route table lookup stays in the pipeline (server/SM). The
  pipeline matches method + path → operation + params. Handlers
  receives the matched operation, not raw HTTP.
- [ ] Sidecar availability check in the pipeline, before Handlers.
  The route table tags each operation as Zig or sidecar (comptime).
  If the matched operation is sidecar and the sidecar is down,
  return 503. Handlers never called — it assumes availability.
  For pure-Zig apps, the check is eliminated by the compiler.
- [ ] Add `handler_route` to the Handlers interface: takes matched
  operation, route params, body, returns `?Message`. Runs the
  user's value transformation function. Both Zig and sidecar
  routes go through Handlers.
- [ ] Generate one Handlers type from the annotation scanner. Per-
  operation comptime switch dispatches to the right runtime: direct
  function call for Zig handlers, 3-RT protocol for sidecar
  handlers (current protocol, replaced in Phase 3).
- [ ] Handlers interface provides: `handler_route(method, path, body)`,
  `handler_prefetch(storage, msg)`,
  `handler_execute(cache, msg, fw, db)`,
  `handler_render(...)`. Associated type `Cache` — typed union for
  Zig operations, sidecar state for sidecar operations.
- [ ] Sidecar connection state lives on the Handlers type (or a field
  accessible to it). One connection per sidecar runtime. Managed
  by the server, accessible to Handlers at dispatch time.
- [ ] Extract shared response encoding (cookie formatting, SSE
  framing, HTML framing) from both pipeline functions into one
  shared function. This is pure mechanical dedup — identical code
  exists in both paths today.
- [ ] Merge `commit_and_encode` and `sidecar_commit_and_encode` into
  one pipeline function that calls Handlers generically.
- [ ] `server.zig`: remove the `if (@hasDecl(App, "sidecar"))` branch.
  One call to the pipeline. The Handlers dispatch handles routing
  to the right runtime per-operation.
- [ ] Connection state machine unchanged — connections are pure IO
  machinery. Pipeline phase tracking stays in server/SM, not on
  connections.
- [ ] If all handlers are Zig, no sidecar socket is opened. Compiler
  eliminates dead sidecar branches.
- [ ] All existing tests pass — sim tests, fuzz tests, unit tests.
  The unification is a refactor, not a behavior change.
- [ ] Sidecar integration tests pass — same behavior, new plumbing.

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

### Checklist

- [ ] Add `commit_stage: CommitStage` to the server. Initialized to
  `.idle`. Guards against starting a new pipeline while one is
  in-flight.
- [ ] Add `commit_connection` to the server: tracks which connection
  is currently in the pipeline. Set on pipeline start, cleared on
  pipeline complete.
- [ ] Change `StateMachine.prefetch` signature: take callback, return
  void. Match TB's `prefetch(callback, op, ...)` pattern.
- [ ] Store prefetch callback and state on the SM:
  `prefetch_callback`, `prefetch_cache`, `prefetch_identity`.
  One set of fields — one request at a time.
- [ ] ZigHandlers: `handler_prefetch` calls handler synchronously,
  fires callback immediately. No behavior change from Phase 1.
- [ ] SidecarHandlers: `handler_prefetch` sends 3-RT prefetch (still
  old protocol in Phase 2), stores callback, returns. Callback
  fires on socket response.
- [ ] Server tick loop: `process_inbox` checks `commit_stage`. If not
  `.idle`, skip pipeline dispatch — only do IO work (accept, recv,
  send, timeout).
- [ ] Pipeline resumes via callback: prefetch callback advances to
  handle stage. Handle callback advances to commit. Commit
  advances to render. Render callback advances to encode.
- [ ] Busy/retry: if ZigHandlers' storage is busy (current `null`
  return), the callback fires with a busy signal. The connection
  stays in `.ready`, `commit_stage` returns to `.idle`. Retried
  next tick. Same behavior as today.
- [ ] Ordering: FIFO. `process_inbox` picks the first `.ready`
  connection. One at a time. No reordering.
- [ ] All existing tests pass. For ZigHandlers, callbacks fire
  immediately — functionally identical to the current sync path.
  Same tick, same order.

### Design constraints

- One request in the pipeline at a time. `commit_stage != .idle`
  means no new pipeline starts. Matches TB.
- Prefetch state on the SM, not per-connection. One set of fields.
- The callback pattern matches TB: `prefetch(callback)` where the
  callback receives `*StateMachine`.
- ZigHandlers' immediate callback produces identical timing to the
  current synchronous path — same tick, same order, same results.
- Transaction model unchanged. `begin_batch` / `commit_batch` wraps
  the commit stage. One transaction, one request, same as today.

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

- [ ] Define frame format: CALL, RESULT, QUERY, QUERY_RESULT.
- [ ] Reimplement Handlers sidecar branches using CALL/RESULT frames.
  Replace the 3-RT protocol. Eliminates zeroed cache and
  stored_prefetch_len cross-phase state from Phase 1.
- [ ] Server accepts sidecar connection on unix socket (reverse of
  current — server listens, sidecar connects).
- [ ] Server does not accept HTTP until sidecar is connected.
- [ ] Serial pipeline means at most one CALL in-flight for request
  handling (+ worker CALLs later in Phase 4). Request_id tracking
  in bounded array.
- [ ] QUERY sub-protocol: server executes SQL from QUERY frames
  during prefetch/render CALLs. Returns QUERY_RESULT. Bounded:
  comptime max queries per CALL.
- [ ] Server rejects QUERY frames during handle CALLs — handle has
  db.execute() only. Protocol-level invariant, asserted.
- [ ] Sidecar reconnection: server gives hypervisor a bounded window.
  Past threshold (comptime constant), server crashes.
- [ ] Sidecar runtime (TypeScript): scan handlers, build function
  registry, connect to server, loop: receive CALL → look up
  function → call it → send RESULT. This is the reference
  implementation — other languages reimplement the spec, not
  share a binary. The spec is four frame types (CALL, RESULT,
  QUERY, QUERY_RESULT), each is tag + request_id + length-prefixed
  payload using the self-describing binary row format. Any language
  that can read/write bytes on a unix socket can implement it.
  No shared libraries, no FFI, no embedding. Per-language
  reimplementation allows the most languages.
- [ ] Remove: 3-RT exchange from `sidecar.zig`, manifest reading
  from TS adapter, `generated/dispatch.generated.ts`, old protocol
  frame types from `protocol.zig`.
- [ ] Update cross-language tests.
- [ ] (Deferred) Extend SimIO to fault-inject on sidecar fd: partial
  frames, disconnects mid-CALL, corrupted QUERY_RESULTs, dropped
  RESULTs. Same infrastructure as TCP fault injection, aimed at the
  unix socket. Blocked on protocol stabilization.

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

## Phase 3: Async prefetch

**Goal:** Prefetch takes a callback and returns void, matching
TigerBeetle's pattern. The pipeline is serial — one request at a
time. The async callback is for "don't block the tick loop on IO,"
not for "run multiple pipelines concurrently."

**Current state (after Phase 2):** Pipeline is synchronous — blocks
on each CALL/RESULT exchange. CALL/RESULT protocol is in place.

**Target state:** `state_machine.prefetch(msg, callback)` returns
`void`. The callback fires when prefetch is complete — immediately
for Zig handlers (SQLite is sync), later for sidecar handlers
(RESULT arrives on epoll). Same pattern for handle and render.

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

For Zig handlers, all stages complete in one tick (callbacks fire
immediately). For sidecar handlers, prefetch/handle/render stages
may span ticks (callback fires on epoll RESULT).

### Checklist

- [ ] Add `commit_stage: CommitStage` to the server. Initialized to
  `.idle`. Guards against starting a new pipeline while one is
  in-flight.
- [ ] Add `commit_connection` to the server: tracks which connection
  is currently in the pipeline. Set on pipeline start, cleared on
  pipeline complete.
- [ ] Change `StateMachine.prefetch` signature: take callback, return
  void. Match TB's `prefetch(callback, op, ...)` pattern.
- [ ] Store prefetch callback and state on the SM:
  `prefetch_callback`, `prefetch_cache`, `prefetch_identity`.
  One set of fields — one request at a time.
- [ ] Zig handlers: handler_prefetch calls handler synchronously,
  fires callback immediately. No behavior change.
- [ ] Sidecar handlers: handler_prefetch sends CALL, stores callback,
  returns. Callback fires on RESULT from epoll.
- [ ] Server tick loop: `process_inbox` checks `commit_stage`. If not
  `.idle`, skip pipeline dispatch — only do IO work (accept, recv,
  send, timeout).
- [ ] Pipeline resumes via callback: prefetch callback advances to
  handle stage. Handle callback advances to commit. Commit
  advances to render. Render callback advances to encode.
- [ ] Busy/retry: if Zig handler storage is busy (current `null`
  return), the callback fires with a busy signal. The connection
  stays in `.ready`, `commit_stage` returns to `.idle`. Retried
  next tick. Same behavior as today.
- [ ] Ordering: FIFO. `process_inbox` picks the first `.ready`
  connection. One at a time. No reordering.
- [ ] All existing tests pass. For Zig handlers, callbacks fire
  immediately — functionally identical to the current sync path.
  Same tick, same order.

### Design constraints

- One request in the pipeline at a time. `commit_stage != .idle`
  means no new pipeline starts. Matches TB.
- Prefetch state on the SM, not per-connection. One set of fields.
- The callback pattern matches TB: `prefetch(callback)` where the
  callback receives `*StateMachine`.
- Zig handlers' immediate callback produces identical timing to the
  current synchronous path — same tick, same order, same results.
- Transaction model unchanged. `begin_batch` / `commit_batch` wraps
  the commit stage. One transaction, one request, same as today.

### Throughput note

Serial pipeline means the sidecar CALL latency directly impacts
throughput — one request at a time, each waiting for the sidecar.
This is the correct starting point. TB also commits one at a time.
Pipelining (preparing request N+1 while committing N) is a future
optimization, not a Phase 3 concern. Build correct first, optimize
later.

---

## Phase 4: Workers

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
Phase 1 (unify pipeline — Handlers type parameter) ✓
    ↓
Phase 2 (CALL/RESULT protocol — dumb executor)
    ↓
Phase 3 (async prefetch — serial, callback-driven)
    ↓
Phase 4 (workers — worker-v2.md)
```

Phase order revised after Phase 1: protocol before async. The
protocol eliminates Phase 1's temporary awkwardness (zeroed cache,
cross-phase state). Async is then applied to the final protocol —
no rework.

Each phase builds on the one below. Each phase is independently
testable — all existing tests pass after each phase.
