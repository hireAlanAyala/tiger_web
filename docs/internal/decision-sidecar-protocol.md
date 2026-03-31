# Sidecar Protocol — Design Decisions

These decisions were reached through systematic application of
TigerBeetle's six principles. Each closes a design branch — don't
reopen without revisiting the reasoning.

## The sidecar is a dumb function executor

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

## The server drives the sidecar

The sidecar connects to the server (not the reverse). The server's
tick loop pushes CALL frames when it has work. The sidecar processes
and responds. The server controls pace, batching, and backpressure.

**Why:** "Don't react directly to external events. Your program should
run at its own pace." (TigerBeetle tiger_style.) The server is the
authority. The tick loop is the heartbeat.

## One pipeline, one Handlers type

The framework has one pipeline: route -> prefetch -> handle -> commit ->
render. There is no ZigHandlers vs SidecarHandlers distinction at the
interface level. One Handlers type, one pipeline, one code path.

The scanner generates dispatch functions (handlers.generated.zig) that
are pure: handler module -> function call. The sidecar orchestration
(CALL/RESULT protocol, async epoll, state management) lives in
HandlersType in app.zig — framework code, not generated code.

The runtime `if (sidecar)` checks in HandlersType are intentional.
Moving sidecar logic into generated code would couple the scanner
to the protocol layer. Wrong separation of concerns.

## Serial pipeline — one request at a time

The commit pipeline processes one request at a time, matching
TigerBeetle's model. Prefetch state lives on the StateMachine — one
slot. No concurrent prefetch, no interleaved pipelines, no
per-connection pipeline state.

Pipeline stages driven by `commit_dispatch` (TB's pattern):
idle -> prefetch -> handle -> render -> idle.

While a sidecar CALL is in-flight, the tick loop can still accept
connections, read requests, send responses, manage timeouts — but
NOT start another request's pipeline.

**Why:** Eliminates per-connection state expansion, transaction
boundary changes, ordering ambiguity, and concurrent access to
prefetch_cache.

## Async prefetch + render, sync handle + route

Prefetch and render are async (QUERY sub-protocol, multiple round
trips, epoll-driven). Handle is intentionally sync — one round trip,
no QUERY sub-protocol, microseconds on unix socket. Making handle
async would require splitting sm.commit (WriteView + WAL + response
building) for negligible latency gain. Route is sync — one round
trip, no QUERY.

## QUERY sub-protocol — db.query() as mid-CALL RPC

Prefetch and render call `await db.query(sql, params)`. The sidecar
sends a QUERY frame, the server executes the SQL, returns a
QUERY_RESULT frame. The function continues with the data.

- query_id on QUERY/QUERY_RESULT enables Promise.all() for parallel queries.
- Server enforces comptime max queries per CALL.
- QUERY frames during handle CALLs are rejected (protocol invariant).

## Transaction boundary

begin_batch/commit_batch wraps the .handle stage in commit_dispatch.
Render runs OUTSIDE the transaction — it reads post-commit state.
SQLite WAL mode allows reads without a transaction.

Time is set once per pipeline (when the request arrives), not per
tick. A pending pipeline uses the arrival time, not the resume time.

## Error encoding — one flag byte

RESULT frames carry success (0) or failure (1). No error detail in
the protocol — sidecar logs locally. One byte. No unbounded strings.

## Startup sequencing

Server does not accept HTTP until the sidecar has connected. One
state transition: not ready -> ready.

## Sidecar adapter strategy

Per-language reimplementation of the spec. The spec is four frame
types (CALL, RESULT, QUERY, QUERY_RESULT), each is tag + request_id
+ length-prefixed payload. Any language with unix socket IO can
implement it. No shared libraries, no FFI. TypeScript adapter is the
reference implementation.

## Cross-language verification

Cross-language vector tests (`call_test.ts`): Zig writes known frames
to a file, TS reads and verifies byte-for-byte agreement. Every
adapter must pass the same vectors.

Protocol fuzzer (`sidecar_fuzz.zig`): 11 categories of malformed
input, 10K events per run. Proves the protocol boundary rejects
every malformed input before the state machine.
