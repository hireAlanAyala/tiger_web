# Sidecar Protocol — Self-Describing Binary Rows

Supersedes the JSON protocol (2026-03-24 attempt) and the original binary
protocol (PrefetchCache/WriteSlot extern structs).

## Problem

The original binary protocol serialized domain-typed structs over the wire:
`PrefetchCache` (65KB, 11 typed slots), `WriteSlot` (tagged union of domain
types). Adding a table meant updating an extern struct, a presence flag, a
codegen path, and a TS serde function — four places for one concept.

Those types were deleted when handlers switched to raw SQL (`db.execute`).
The protocol needed a rebuild.

The first attempt replaced binary with JSON length-prefixed frames. This
introduced hand-rolled JSON parsing in the hot path, 1MB frame buffers,
runtime string matching where comptime integer comparison used to work,
and a 150-line vulnerability surface of brace-matching code. TigerBeetle
would reject it on every axis.

## Decision

**Self-describing binary rows.** The framework sends SQL result sets in a
generic columnar format. The sidecar reads rows with one generic reader
per language — no per-type generated serde.

**SQL-write WAL.** The WAL stores committed SQL writes, not handler inputs.
Replay re-executes the SQL — no handlers, no sidecar, no typed Message body.

### What crosses the wire

```
Route:     method(u8) + path(len-prefixed) + body(len-prefixed)
         → operation(u8) + id(u128) + prefetch declarations

Prefetch:  framework executes declared SQL, sends back row sets
         → sidecar runs handle, sends status(u8) + writes + render declarations

Render:    framework commits writes, executes render SQL, sends row sets
         → sidecar renders, sends HTML (len-prefixed)
```

The body (parsed HTTP request) stays in sidecar memory between RT1 and
RT2. It does not cross the wire a second time. The framework never stores
it — the WAL records the SQL writes, not the handler input.

### Row format

Each SQL result is a self-describing row set:

```
[u16 column_count]
[columns: column_count x { u8 type_tag, u16 name_len, name_bytes }]
[u32 row_count]
[rows: row_count x { values: column_count x typed_value }]
```

Type tags match SQLite's type system:
- `0x01` integer (i64, little-endian 8 bytes)
- `0x02` float (f64, little-endian 8 bytes)
- `0x03` text (u16 len + bytes)
- `0x04` blob (u16 len + bytes)
- `0x05` null (0 bytes)

For `mode: "one"` queries: row_count is 0 (null result) or 1.
For `mode: "all"` queries: row_count is 0..N.

### Parameter format

SQL parameters from the sidecar (prefetch queries and handle writes):

```
[u8 param_count]
[params: param_count x { u8 type_tag, typed_value }]
```

Same type tags as rows. The framework binds them positionally (?1, ?2, ...).

### SQL declaration format

Prefetch and render declarations share the same format — an array of
named queries:

```
[u8 query_count]
[queries: query_count x {
    u8 key_len, key_bytes,          // field name in prefetched/render data
    u16 sql_len, sql_bytes,         // SQL string
    u8 mode,                        // 0x00 = one, 0x01 = all
    u8 param_count,                 // positional params
    params: param_count x { u8 type_tag, typed_value }
}]
```

### Frame format

Length-prefixed binary frames:

```
[u32 big-endian payload_length]
[u8 message_tag]
[payload bytes]
```

Message tags:
- `0x01` route_request
- `0x02` route_prefetch_response (route result + prefetch declarations)
- `0x03` prefetch_results (row sets from framework)
- `0x04` handle_render_response (status + writes + render declarations)
- `0x05` render_results (row sets from framework, post-commit)
- `0x06` html_response (final HTML from sidecar)

### Per-request exchange — always 3 round trips

```
Framework                              Sidecar
    |                                      |
    |--- route_request (0x01) ------------>|  method + path + HTTP body
    |<-- route_prefetch_response (0x02) ---|  operation + id + prefetch SQL
    |                                      |
    |  [framework executes prefetch SQL]   |
    |                                      |
    |--- prefetch_results (0x03) --------->|  row sets
    |<-- handle_render_response (0x04) ----|  status + writes + render SQL
    |                                      |
    |  [framework executes writes in txn]  |
    |  [framework commits]                 |
    |  [framework writes WAL (SQL writes)] |
    |  [framework executes render SQL]     |
    |                                      |
    |--- render_results (0x05) ----------->|  row sets (post-commit state)
    |<-- html_response (0x06) -------------|  HTML bytes
    |                                      |
    |  [framework sends HTTP response]     |
```

Always 3 round trips. No conditional paths. No optimizations worth the
complexity. Uniformity, simplicity, and safety are the priorities — not
unix socket throughput.

Handlers without render db access send zero render declarations. The
framework sends an empty row set. The sidecar renders immediately. The
cost is ~50us for the empty round trip. The gain is one code path
everywhere — framework, dispatch, fuzzer, tests.

## Pipeline architecture — two pipelines, shared building blocks

### The problem

The SM pipeline calls handler phases separately: translate → prefetch →
execute → render. Each is a synchronous function call to a local Zig
handler module. The SM passes typed data between phases through a
comptime `PrefetchCache` union.

The sidecar protocol is a 3-round-trip socket conversation. RT2
(send prefetch results, receive handle response) spans the boundary
between the SM's prefetch and execute phases. Forcing the sidecar
into the SM pipeline requires:

- **Stored state between SM calls.** The sidecar client holds prefetch
  declarations, write queues, and render declarations as buffer slices
  across separate SM function calls.
- **Dummy cache.** The SM stores and passes a `PrefetchCache` that the
  sidecar never uses. Dead type in the pipeline.
- **Buffer aliasing.** Stored slices alias `recv_buf`. Each phase
  overwrites the buffer, invalidating previous slices. Correctness
  depends on the SM calling phases in order — a contract not expressed
  in the type system.

### Options considered

**Option A: Sidecar as Handlers backend (single pipeline).**
The sidecar implements the SM's Handlers interface. The SM drives
translate → prefetch → execute → render without knowing it's talking
to a sidecar. Dummy cache, stored state, buffer aliasing.

Rejected: the impedance mismatch between the SM's phased dispatch and
the sidecar's round-trip protocol creates fragile state management.
A change to the SM's call ordering or retry semantics silently breaks
the sidecar's stored state.

**Option B: Sidecar bypass in commit_and_encode.**
All sidecar IO in one function, SM pipeline runs with dummies.

Rejected: `commit_and_encode` becomes two implementations. Violates
"SM doesn't know about sidecar." The SM's guarantees (transactions,
auth, WAL) must be replicated inside the bypass function.

**Option C: Generalize SM Cache to support opaque bytes.**
Add a sidecar variant to PrefetchCache that holds binary row data.

Rejected: PrefetchCache is `union(Operation)` — each variant is an
operation. A sidecar variant breaks the operation-indexed structure.
And the real problem isn't the cache type — it's that RT2 spans two
SM phases.

### Decision: two pipelines, shared building blocks

TigerBeetle has this pattern. Their real IO path and simulated IO path
have different orchestration but share the same state machine and storage
building blocks. The simulation doesn't go through the real IO pipeline —
it has its own driver that calls the same SM methods in a different
sequence.

Same pattern here. The building blocks are the product. The orchestration
is the adapter.

```
// Shared building blocks (framework owns these)
storage.begin_batch()       // transaction boundary
storage.commit_batch()      // transaction boundary
storage.query_raw()         // execute SQL, return binary rows
storage.execute_raw()       // execute SQL write
auth.resolve_credential()   // cookie → identity
wal.append()                // record committed SQL writes
http_response.encode()      // HTML → HTTP response
sse.encode()                // HTML → SSE response

// Native pipeline — SM orchestrates
msg = translate(method, path, body)
cache = handler_prefetch(storage, msg)
storage.begin_batch()
result = handler_execute(cache, msg, fw, db)
storage.commit_batch()
html = dispatch_render(cache, operation, status, storage)

// Sidecar pipeline — sidecar_pipeline orchestrates
msg = client.translate(method, path, body)         // RT1
prefetch_data = client.execute_prefetch(storage)    // local SQL
handle_result = client.exchange_handle(prefetch_data) // RT2
storage.begin_batch()
client.execute_writes(storage)                      // writes in txn
storage.commit_batch()
render_data = client.execute_render_sql(storage)    // local SQL
html = client.exchange_render(render_data)          // RT3
```

Both pipelines call the same storage/auth/WAL building blocks. The
building blocks are shared — no duplicated logic. The composition is
different because the execution models are different:

- **Native**: local function calls, typed data passing via PrefetchCache
- **Sidecar**: wire round trips, binary data passing via socket frames

### Auth in the sidecar pipeline

The sidecar handles business logic. The framework handles identity.

In the native path, the server fills `Message.credential` from the HTTP
cookie. The SM resolves the credential to a `user_id + identity`
(authenticated or anonymous). Handlers receive the identity via
`ctx.fw.identity`.

In the sidecar pipeline, `translate()` returns `operation + id` from
the sidecar — no credential. The credential comes from the HTTP request,
not the sidecar. The pipeline resolves credentials using the same auth
building block the SM uses. The resolved identity is framework-side
state — the sidecar handlers receive it if they need it (e.g., to render
the user's name), but auth enforcement is the framework's responsibility.

Same auth functions, different call site. No duplication.

### Session action — deferred

The native handle can return `session_action = .set_authenticated`
(login) or `.clear` (logout). The sidecar's handle_render_response
currently sends `status(u8) + writes + render_declarations` but no
session action.

For now, `session_action = .none` for all sidecar requests. Only logout
uses it, and session-as-writes is already deferred in the plan (handlers
will write to a sessions table via `db.execute` instead of returning a
session_action field).

When needed: add a `session_action(u8)` byte to the handle_render_response
frame after the status byte. One byte, no protocol redesign.

### Why this doesn't hurt correctness

Determinism comes from the handler logic and the database, not the
pipeline orchestration. Both pipelines execute the same SQL against
the same SQLite. Same writes, same transaction boundaries, same state.

Correctness comes from the building blocks: `begin_batch` before writes,
`commit_batch` after, WAL after commit, render after commit. Both
pipelines call the same functions in the same order.

The risk with two pipelines is maintenance, not correctness. If the SM
adds a new concern, the sidecar pipeline must add the same call. This
is a code review problem — the building block exists, it just needs to
be called. The alternative (impedance mismatch) creates an implicit
ordering risk that's harder to catch in review.

### Correctness proof

A test that proves both pipelines produce the same outcome for the
same input. Not the same call sequence — the same database state after
commit. The auditor can be extended: run a native request and a sidecar
request for the same operation, assert they produce the same writes.

### Implementation

The sidecar pipeline lives in `app.zig` alongside `commit_and_encode`.
The server calls it when `sidecar != null`:

```zig
// server.zig process_inbox (simplified)
const msg = App.translate(method, path, body) orelse return unmapped;

if (App.sidecar != null) {
    return App.sidecar_pipeline(msg, storage, send_buf, ...);
} else {
    return App.commit_and_encode(sm, msg, send_buf, ...);
}
```

The `sidecar_pipeline` function:

```zig
pub fn sidecar_pipeline(
    msg: Message,
    storage: *Storage,
    send_buf: []u8,
    is_sse: bool,
    secret_key: *const [auth.key_length]u8,
) ?CommitResult {
    const client = &sidecar.?;

    // Phase 1: execute prefetch SQL (declared in RT1, stored on client)
    const prefetch_len = client.execute_prefetch(
        Storage.ReadView.init(storage),
    ) orelse return null;

    // Phase 2: RT2 — send prefetch results, receive handle + writes
    const status = client.send_prefetch_recv_handle(prefetch_len) orelse return null;

    // Phase 3: execute writes inside transaction
    storage.begin_batch();
    const writes_ok = client.execute_writes(storage);
    if (writes_ok) {
        storage.commit_batch();
    } else {
        storage.rollback_batch();
        return null;
    }

    // Phase 4: RT3 — execute render SQL, send results, receive HTML
    const html = client.execute_render(
        Storage.ReadView.init(storage),
    ) orelse return null;

    // Phase 5: encode HTTP response (same as native path)
    // ... cookie, SSE/full-page encoding ...
}
```

The SM is untouched. The Handlers interface is untouched. The sidecar
pipeline calls the same storage methods as the SM does internally.
The server decides which pipeline to use at the top level.

### Sidecar failure mid-exchange

The sidecar failure is equivalent to a crash at different points in the
request. The correct behavior is crash recovery: don't retry, don't
recover mid-operation, fail the request. The database is consistent.

**Before writes commit** (sidecar dies during RT1 or RT2 before the
framework receives handle_render_response): no state change. Prefetch
SQL was read-only. Drop the request, return error to HTTP client. Clean.

**After writes commit** (sidecar dies during RT3, after framework
committed writes but before receiving HTML): state changed, no HTML.
Return a generic error to the client. The database is correct — the
client refreshes and sees the right state. The WAL recorded the writes.

**No retry of the current request.** Reconnecting and re-running the
handler could produce different results — the database state changed
from the committed writes. The handler's prefetch would read post-commit
state and make a different decision. Retrying a mutation through a fresh
sidecar connection is a new request, not a recovery.

**Reconnect on next request.** Lazy reconnect, same as the existing
`try_reconnect` pattern. The hypervisor restarts the sidecar. The next
HTTP request triggers a reconnect attempt. If the sidecar isn't back
yet, the request falls through to unmapped.

This is TigerBeetle's approach: the operation either completed or it
didn't. The client retries. No partial recovery, no mid-operation retry,
no buffering.

### Body lifecycle

The body stays in the sidecar. It never crosses the wire after RT1.

1. **RT1**: sidecar parses HTTP body in route(), stores structured result
   in dispatch memory, returns `operation(u8) + id(u128) + prefetch SQL`.
2. **RT2**: framework sends prefetch results. Dispatch retrieves stored
   body from memory, passes it to handle() as `ctx.body`.
3. **WAL**: records the committed SQL writes, not the handler input.
   The body is not persisted.
4. **Replay**: re-executes the SQL writes from the WAL. No body, no
   handler logic, no sidecar needed.

## WAL: SQL writes, not handler inputs

### The question

The original WAL stores Message inputs (operation + id + typed body).
Replay re-executes handlers to re-derive the SQL writes. This is
TigerBeetle's pattern — replay proves determinism.

The sidecar protocol raised a problem: the Message body is a 672-byte
extern struct (Product, OrderRequest, etc.). If the sidecar must
serialize typed bodies, per-type serde comes back into the protocol —
the thing we're trying to eliminate.

Three options were considered:
1. Keep input WAL — accept per-type serde in the sidecar protocol
2. Switch to SQL-write WAL — store committed SQL, not handler inputs
3. Store both — belt and suspenders (rejected: complexity without value)

### Why we don't need input replay

The Zig-native state machine IS pure. Handle receives a context, returns
status + writes, no IO, no clock reads. Same input → same output by
construction. Input replay could verify this.

But input replay is not the tool that verifies determinism. The fuzzer
is. The fuzzer generates random operations with random seeds, runs them
through prefetch → handle → commit, and the auditor asserts correct
outcomes. This runs on every build, covers edge cases input replay
never sees, and doesn't require a WAL.

TigerBeetle's input replay serves a different purpose: it's the
replication protocol. Every replica replays the same inputs and must
arrive at the same state. That's consensus, not debugging. We don't
replicate. We don't do consensus. SQLite handles crash recovery.

### Debug flow

TigerBeetle's debug flow: **seed + git commit**. The seed replays
events through the state machine in debug mode. You add asserts and
logs, follow the output, understand the bug. Mutations to the code
break seed replayability — you run new simulations to verify the fix.
You're not expecting identical execution. You're expecting correct
output.

Our debug flow: **git commit + WAL + seed**. Same pattern, but the WAL
fills the gap between production and the fuzzer:

1. **WAL** — answers "what happened?" A user reports a bug. The WAL
   shows the SQL writes that produced the wrong state. This is the
   starting point for investigation when you don't have a seed.
2. **Seed** — reproduces the bug. You write a fuzz test case that
   reproduces the scenario. The seed makes it deterministic.
3. **Git commit** — the code that ran. Add asserts, follow the output,
   understand the bug.
4. **Simulation** — verifies the fix. Run new simulations, ensure the
   auditor passes.

The WAL is the investigation tool. The seed is the reproduction tool.
The simulation is the verification tool. Each has a role. None of them
need typed Message bodies.

### Why SQL writes

Storing SQL writes matches our position in the stack:

- **We don't own the disk.** SQLite does. We log what we asked it to do.
- **We're db-agnostic.** SQL writes replay against any SQL database.
  Typed extern struct bodies only work with our specific Zig types.
- **The WAL is an audit trail.** "Show me the 5 writes from this order
  creation" is more useful than "here's 672 bytes of OrderRequest."
- **The sidecar is first-class.** If the WAL needs Zig handlers to
  replay, the sidecar path is second-class. SQL-write WAL treats both
  paths equally — same entries regardless of which path produced them.

### What this simplifies

- **Body format question disappears.** The WAL doesn't store the body.
  No typed bodies, no `body_as()`, no format tension between WAL replay
  and sidecar independence.
- **Replay works without handlers.** Re-execute SQL. No handler logic,
  no sidecar, no Zig-native handlers needed.
- **Two sources of truth eliminated.** Zig prefetch SQL and TS prefetch
  SQL can differ without breaking replay. The WAL records the outcome,
  not the derivation.
- **Message struct shrinks.** WAL entries become operation + id +
  timestamp + SQL writes. The 672-byte body field is not needed.

### What this costs

- **No what-if replay.** Can't replay a request through a patched
  handler to see if the fix would have produced different SQL. You
  write a fuzz test instead — faster and more reliable.
- **WAL entries are variable-size.** SQL strings + params per write vs
  a fixed 880-byte Message. For a handler with 3 writes of ~200 bytes,
  ~600 bytes — comparable. For create_order with 20+ writes, larger.
  Bounded by `writes_max` x `sql_max`.

### What this does NOT cost

- **Determinism.** The fuzzer verifies determinism on every build. The
  WAL never was the determinism tool. The seed is.
- **Debug capability.** WAL + seed + git commit gives the full story.
  The WAL shows what happened. The seed reproduces it. The code
  explains why.
- **Resilience to external mutations.** Neither WAL design survives a
  third party modifying the database outside the state machine. Input
  replay produces different output because prefetch reads different data.
  SQL-write replay hits constraint violations or silently wrong state.
  Both fail equally. The defense is the same: route all writes through
  the state machine. TigerBeetle's determinism guarantee is strong
  because it owns every byte on disk. We don't own the disk — input
  replay's "determinism proof" was always conditional on exclusive
  database ownership we can't enforce. SQL-write WAL is the honest
  choice for our position in the stack.

### Current WAL vs SQL-write WAL

```
                        Current (input WAL)        SQL-write WAL
────────────────────────────────────────────────────────────────────
Stores                  Message (op + id + body)   op + id + SQL writes
Replay requires         Zig handlers or sidecar    Nothing (just SQL)
Body format             extern struct (672 bytes)  Not stored
Sidecar replay          Needs sidecar running      Works without sidecar
Determinism proof       Via replay (redundant)     Via fuzzer (primary)
Audit readability       Opaque bytes               Human-readable SQL
DB portability          Zig-specific types          Any SQL database
Entry size (typical)    880 bytes fixed             Variable, ~600 bytes
Entry size (worst)      880 bytes fixed             writes_max x sql_max
Zig-native dependency   Yes                        No
Debug flow              Seed reproduces             WAL investigates,
                                                    seed reproduces
```

## Why this is better

### vs. the original binary protocol

- **No domain types on the wire.** Adding a table doesn't touch the protocol.
  The framework sends rows. It doesn't know or care what columns you selected.
- **One row reader per language**, not per-type generated serde. Adding Python
  means writing a row reader, not a codegen backend.
- **Prefetch is declarative SQL**, not a 65KB cache struct with 11 typed slots.
- **Render has post-commit db access.** The old protocol bundled handle+render
  into one call with no commit in between. The new protocol commits first,
  then gives render fresh query results.

### vs. the JSON protocol

- **No parsing in the hot path.** Type tags and lengths, not string-key
  scanning and brace matching.
- **Comptime-verifiable sizes.** Frame headers, type tags, and param counts
  are fixed-width integers. Buffer sizes derived from constants.
- **No hand-rolled JSON parser.** The 150 lines of `extractJsonString`,
  `findMatchingBrace`, `JsonObjectIterator` are deleted.
- **Exact buffer sizing.** Send/recv buffers sized to worst-case frame,
  not 1MB "should be enough."

### vs. an ORM instruction set

- **SQL is the universal instruction set.** The database already speaks it.
  An ORM restates SQL as structured operations, then translates back. Two
  translations, same result.
- **SQL is the schema contract.** The handler writes SQL. The framework
  executes it. Swap SQLite for Postgres — handlers don't change.
- **No abstraction to maintain.** Every ORM edge case (upserts, joins,
  window functions) either gets an escape hatch (raw SQL) or a new feature
  (scope creep). SQL is already complete.

## SQL validation at build time

The scanner already reads handler source files and extracts annotations.
It can also extract SQL string literals and validate them:

- **Prefetch SQL**: must be SELECT only. No INSERT, UPDATE, DELETE, DROP.
- **Handle writes**: must be INSERT, UPDATE, or DELETE. No SELECT, DROP.
- **Render SQL**: must be SELECT only. Same as prefetch.

The SQL is in the source text as string literals. The scanner can see it.
This doesn't require a SQL parser — just check the first keyword after
stripping whitespace. If the handler uses a variable or function call
instead of a string literal, the scanner flags it as unvalidatable.

This is build-time enforcement of read/write separation. The Zig-native
path enforces it via ReadView/WriteView types at comptime. The sidecar
path enforces it via scanner validation at build time. Same guarantee,
different mechanism.

## Column names on the wire

Each row set includes column names. This is redundant — the sidecar wrote
the SQL and knows what columns it selected. But:

- **Safety over bandwidth.** Omitting names means column order matters. A
  schema change silently misaligns columns. Names make misalignment
  impossible — the sidecar matches by name, not position.
- **The overhead is bytes, not correctness risk.** Column names are short
  strings sent once per result set (not per row). A 6-column query adds
  ~50 bytes to the frame. Negligible.
- **Self-describing data is debuggable.** Dump a frame, read it. No schema
  lookup needed.

## What stays from the current implementation

The TS handler API is wire-format-independent. All of this survives:

- **24 handler files** in `examples/ecommerce-ts/handlers/` — route, prefetch,
  handle, render functions. Same signatures, same SQL.
- **`types.generated.ts`** SDK — RouteRequest, PrefetchQuery, HandleContext,
  WriteDb, RenderContext, assert, esc, price.
- **`adapters/typescript.ts`** — manifest reading, namespace imports, dispatch
  tables. Only the socket server section changes (binary framing instead of
  JSON framing).
- **`annotation_scanner.zig`** — 4 phases (translate, prefetch, execute, render),
  status exhaustiveness, route match validation. Unchanged.
- **`build.zig`** — scan step takes dir from args. Unchanged.
- **`message.zig`** — Operation.from_string, Status.from_string (still needed
  for the route phase where operation names are strings).

## What changes

- **`protocol.zig`** — frame headers, row format, SQL declaration format,
  param format. All as extern structs with comptime assertions. No domain types.
- **`sidecar.zig`** — binary framing, 3-RT socket exchange. Connection
  management, translate (RT1), execute_prefetch, exchange_handle (RT2),
  execute_render (RT3). No JSON. No SM Handlers interface.
- **`app.zig`** — new `sidecar_pipeline` function alongside `commit_and_encode`.
  Calls the same storage/auth/WAL building blocks as the SM path. Server
  decides which pipeline to use: `if (sidecar) sidecar_pipeline() else sm_pipeline()`.
- **`codegen.zig`** — generates a generic row reader + param writer per
  language, not per-type serde. Much smaller output.
- **Dispatch socket server** (in adapter output) — binary framing, generic
  row deserialization into JS objects, param serialization from JS values.
  Dispatch stores route body in memory between RT1 and RT2.
- **`sidecar_fuzz.zig`** — fuzz binary frames, row format, param format,
  and the full 3-round-trip exchange with random/corrupt data.
- **`annotation_scanner.zig`** — SQL validation pass (SELECT-only for
  prefetch/render, write-only for handle).
- **`wal.zig`** — WAL entries store SQL writes (sql string + params),
  not Message bodies. Entry format: operation + id + timestamp +
  write_count + writes[].

## Row format — language-side deserialization

Each language needs one generic function:

```ts
// TypeScript — generic row reader
function readRowSet(buf: DataView, offset: number): Record<string, any>[] {
    const colCount = buf.getUint16(offset, false); offset += 2;
    const columns = [];
    for (let i = 0; i < colCount; i++) {
        const type = buf.getUint8(offset); offset += 1;
        const nameLen = buf.getUint16(offset, false); offset += 2;
        const name = decoder.decode(new Uint8Array(buf.buffer, offset, nameLen));
        offset += nameLen;
        columns.push({ name, type });
    }
    const rowCount = buf.getUint32(offset, false); offset += 4;
    const rows = [];
    for (let r = 0; r < rowCount; r++) {
        const row: Record<string, any> = {};
        for (const col of columns) {
            [row[col.name], offset] = readTypedValue(buf, offset, col.type);
        }
        rows.push(row);
    }
    return rows;
}
```

One function. All types. All tables. No codegen.

## Sizing

Route request: ~4KB worst case (method + max path + max body).
Prefetch declarations: ~4KB per query x max 32 queries = ~128KB worst case.
Prefetch results: depends on query results. Capped by `list_max` (50 rows)
  x max row size. Comptime-derivable from domain constants.
Handle+render response: status(1) + writes(count + SQL strings) + render
  declarations. Writes capped by `writes_max` x `sql_max`.
Render results: same shape as prefetch results, typically smaller.
HTML response: capped by `send_buf_max`.

All worst-case sizes derivable at comptime. Buffer allocation at startup.

## Resolved critiques

Each critique reviewed and resolved before implementation.

**1. "Why is the sidecar declaring SQL?"**
The framework runs untrusted SQL inside the transaction boundary. The sidecar
could send `DROP TABLE products`. Resolution: the scanner validates SQL at
build time. Prefetch/render must be SELECT. Handle must be INSERT/UPDATE/DELETE.
First keyword check on string literals. Non-literal SQL flagged as
unvalidatable. Same read/write guarantee as the Zig-native path
(ReadView/WriteView), different mechanism (scanner vs comptime types).

**2. "Three round trips per request."**
Collapsed route + prefetch declarations into RT1. Considered optimizing to
2 RTs by conditionally skipping render when no render SQL is declared.
Rejected: the database is the bottleneck, not the unix socket. 50us for
an empty round trip is not worth a second code path. Always 3 RTs.

**3. "Column names in every result set."**
Considered omitting names (sidecar knows the SQL) or schema-hash caching.
Rejected: omitting names means column order matters, schema changes silently
misalign data. Keeping names: ~50 bytes per result set, negligible.
Self-describing data is debuggable. Safety over bandwidth.

**4. "Render must have post-commit db access."**
Not optional. `complete_order` queries post-commit state in render.
The protocol commits writes between RT2 and RT3. Render SQL executes
after commit. Always. No conditional path.

**5. "Where does the body go? How does this integrate with the SM?"**
The body stays in sidecar memory. The WAL stores SQL writes, not handler
inputs — replay re-executes SQL without handlers or a sidecar. This is
correct for our position in the stack: we don't own the disk (SQLite does),
replay is a debugging tool (not crash recovery), and the sidecar is a
first-class path (not a dev convenience). The SM pipeline doesn't change —
the sidecar path implements the same Handlers interface.

**6. "Delivery order is backwards."**
Start with the fuzzer. Row format fuzz test first — generate random row
sets, serialize, deserialize, assert round-trip. The format falls out of
what the fuzzer exercises. Then implement to pass the fuzzer.

**7. "Sidecar as SM Handlers backend — impedance mismatch."**
The SM's pipeline calls phases separately with typed data passing. The
sidecar's protocol is a 3-RT socket conversation. Forcing the sidecar
into the SM pipeline requires stored state between calls, dummy cache,
and buffer aliasing. Resolution: two pipelines, shared building blocks.
TigerBeetle has this pattern — real IO and simulated IO have different
orchestration but share the same SM and storage. The building blocks
(transactions, auth, WAL) are shared. The composition is per-path.
Correctness proven by testing both pipelines produce the same database
state for the same input.

## Delivery order

1. ~~Row format fuzz test~~ ✓
2. ~~Define row/param/declaration format in `protocol.zig`~~ ✓
3. ~~Implement row serializer in Zig (SQLite rows → binary row format)~~ ✓
4. ~~Implement param deserializer in Zig (binary params → SQLite bind)~~ ✓
5. ~~Implement row deserializer in TS (binary row format → JS objects)~~ ✓
6. ~~Implement param serializer in TS (JS values → binary param format)~~ ✓
7. Rebuild `sidecar.zig` — 3-round-trip exchange, binary framing
8. Wire `sidecar_pipeline` in `app.zig` — calls storage/auth/WAL building blocks
9. Rebuild dispatch socket server in adapter — binary framing
10. Rebuild `sidecar_fuzz.zig` — fuzz full exchange with corrupt data
11. SQL validation pass in annotation scanner
12. WAL format change — SQL writes instead of Message bodies
13. Comptime worst-case sizing assertions
14. Delete JSON helpers from `sidecar.zig`
15. Cross-pipeline correctness test — same operation through native and
    sidecar pipelines produces same database state
