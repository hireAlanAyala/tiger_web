# Decision: SHM 1-RT Sidecar Protocol

**Date:** 2026-04-06 through 2026-04-08
**Status:** Implemented

## Problem

The V2 4-RT SHM protocol achieved 15K req/s. Each request made 4 round
trips to the sidecar (route, prefetch, handle, render). The sidecar was
CPU-bound at 110% — each invocation cost ~17µs, totaling 68µs/request.
Target: 42K req/s.

## Decision

Collapse to 1 round trip: the framework does route + prefetch natively,
sends one combined CALL to the sidecar for handle + render. The
annotation scanner extracts SQL at build time so the framework can
execute prefetch queries without calling the sidecar.

For handlers where SQL can't be extracted (loops, computed params),
fall back to 2-RT: sidecar runs route + prefetch in RT1, framework
executes SQL, sidecar runs handle + render in RT2.

## Key findings (with data)

### 1. The sidecar was not the bottleneck — the number of calls was

At 4-RT, the sidecar processed 60K handler invocations/s (faster than
Fastify per-call). The problem: 4 calls per request = 15K req/s.
At 1-RT: 1 call per request = 60K+ req/s from the same sidecar.

### 2. JS allocations dominated sidecar cost

Before optimization: 35K req/s per operation.
After eliminating per-call allocations (pre-allocated response buffer,
context objects, hex lookup table, TextEncoder.encodeInto): 61K req/s.
The `new Uint8Array(256KB)` per call was the biggest offender.

### 3. SQLite prepare was 60% of Zig-side SQL cost

`query_raw` called `sqlite3_prepare_v2` + `sqlite3_finalize` every
request. Prepare: ~4µs. Total SQL: 6.3µs. After adding a runtime
prepared statement cache (keyed by SQL pointer identity, reset+rebind):
SQL total: 1.1µs. Cache hit rate: 99.99%.

### 4. Double copy in CALL send was 50% of send cost

`start_combined_request` built args in a 260KB stack buffer, copied to
`msg.buffer`, copied to SHM slot. After direct SHM slot write via
`get_slot_request_buf` + `finalize_slot_send`: send cost: 0.4µs
(was 4.9µs).

### 5. Moving more work to C addon didn't help

Attempted: C addon pre-parses CALL args (operation, id hex, body string,
rows buffer) and passes pre-built JS values. Result: 10% slower (60K
vs 70K). Each `napi_create_string_utf8` costs ~0.7µs. Creating 4 extra
N-API values added more overhead than the JS parsing it replaced.
Lesson: N-API boundary crossing is expensive. Minimize crossings, not
per-crossing work.

### 6. Per-request time breakdown (get_product at 98K)

| Component | Time | % |
|---|---|---|
| Zig route matching | 80ns | 1% |
| Zig SQL (cached prepare + bind + step + serialize) | 1.1µs | 11% |
| Zig SHM send (direct slot write + CRC + epoch) | 0.4µs | 4% |
| JS handle + render | 2.9µs | 29% |
| Infrastructure (N-API, SHM poll, epoll, HTTP encode) | 5.4µs | 55% |
| **Total** | **~10µs** | |

### 7. Tiger beats Fastify on writes and lists, not trivial gets

Fastify's `get_*` operations hit 78-100K because there's zero IPC — one
function call from HTTP parse to response. Tiger pays ~5µs fixed IPC per
request. For trivial operations (get 1 row), IPC dominates. For complex
operations (list 50 rows, render HTML), Tiger's native SQL + pipeline
beats Fastify's single-threaded blocking model.

### 8. 1-core VPS: 2.7K req/s (starvation)

Both processes busy-poll. On 1 core they fight for CPU. Adaptive
epoll sleep (1ms after N empty polls) helps idle CPU but doesn't fix
throughput — any threshold that helps 1-core hurts 2-core. Solution:
io_uring unified wait (kernel schedules fairly). See todo.md.

### 9. The theory was right

The user's theory: "the single-threaded Zig loop can spin faster than
Fastify, and delegating to the sidecar is lighter than if the sidecar
ran Fastify directly." Confirmed: the sidecar does 2.9µs of JS work per
request vs Fastify's ~10µs. The Zig loop handles HTTP, SQLite, and
response encoding at native speed. Combined: 57K default mix vs
Fastify's 38K (+52%).

## Final benchmark (2-core, 64 connections, fresh servers)

| Operation | Tiger | Fastify | Delta |
|---|---|---|---|
| get_product | 98K | 78K | +25% |
| list_products | 48K | 39K | +22% |
| create_product | 59K | 38K | +57% |
| get_collection | 104K | 102K | +2% |
| list_collections | 58K | 33K | +79% |
| get_order | 113K | 97K | +16% |
| list_orders | 84K | 28K | +203% |
| create_order | 25K | 24K | +2% |
| reads_only | 59K | 40K | +48% |
| default_mix | 57K | 38K | +52% |

## What not to do

- Don't move JS arg parsing to C addon (N-API overhead > JS parsing)
- Don't use futex for sidecar wakeup (context switch overhead > polling)
- Don't use rest parameters (`...args`) in dispatch handler (V8 deopt)
- Don't share response buffer across slots without immediate copy
- Don't iterate `count_active()` for "work found" detection (O(N) per poll)
- Don't use `@dynamic-prefetch` when the SQL can be restructured (IN + json_each)

## Files

| File | Role |
|---|---|
| `annotation_scanner.zig` | SQL extraction, @param, @dynamic-prefetch, prefetch.generated.zig emitter |
| `generated/prefetch.generated.zig` | Comptime specs: SQL, mode, params, keys per operation |
| `sidecar_dispatch.zig` | 1-RT + 2-RT stage machines, direct SHM write, combined CALL/RESULT |
| `framework/server.zig` | try_dispatch_1rt, process_route_prefetch_complete, adaptive polling |
| `framework/shm_bus.zig` | get_slot_request_buf, finalize_slot_send, epoch counter, slot_delivered |
| `framework/io.zig` | Adaptive epoll timeout, shm_poll_fn returns bool |
| `storage.zig` | raw_cache_get/put (prepared statement cache) |
| `addons/shm/shm.c` | pollDispatch (C-side SHM I/O + CRC + frame parse), futexWait/spinWait |
| `adapters/call_runtime_v2_shm.ts` | dispatchHandleRender, pre-allocated buffers, prefetchKeyMap |
| `adapters/shm_client.ts` | ShmClient with region header, startWaiting/startPolling |
