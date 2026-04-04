# Sidecar optimization — batched dispatch

## Problem

The sidecar protocol uses 4 round-trips per request (route, prefetch,
handle, render). Each RT pays ~50µs transport + ~94µs V8 invoke overhead.
The V8 overhead dominates — 375µs of the 819µs total is V8 function
invocation context setup, not user logic.

Express handles requests in one V8 invocation (~440µs total). We pay
V8 invoke overhead 4× because we cross the process boundary 4 times.

## Measured breakdown (per request)

| Component | Cost | % of total |
|---|---|---|
| V8 invoke overhead (4×) | 375µs | 46% |
| Transport (4 RTs) | 281µs | 34% |
| User logic (route+prefetch+handle+render) | 163µs | 20% |
| **Total** | **819µs** | |

The user's actual code is 163µs. The framework adds 656µs of overhead.

## Solution: batched dispatch

Instead of one handler call per RT, batch all pending work across
all pipeline slots into one process boundary crossing.

Current (4 crossings per request):
```
server → sidecar: route(req1)
sidecar → server: result
server → sidecar: prefetch(req1)
sidecar → server: result
server → sidecar: handle(req1)
sidecar → server: result
server → sidecar: render(req1)
sidecar → server: result
```

Batched (1 crossing for N pending items):
```
server → sidecar: [route(req1), handle(req2), render(req3)]
sidecar → server: [result1, result2, result3]
```

V8 function calls within the same invocation are ~1µs (no re-entry
overhead). The expensive part is crossing the process boundary, not
calling JavaScript functions inside V8.

## Projected throughput

| Batch size | Invoke/req | Transport/req | Logic/req | Total/req | Req/s (1 sidecar) | vs Express |
|---|---|---|---|---|---|---|
| 1 (current) | 375µs | 281µs | 163µs | 819µs | 1,200 | 0.5× |
| 2 | 188µs | 141µs | 163µs | 492µs | 2,000 | 0.9× |
| 4 | 94µs | 70µs | 163µs | 327µs | 3,000 | 1.3× |
| 8 | 47µs | 35µs | 163µs | 245µs | 4,000 | 1.7× |
| 16 | 23µs | 18µs | 163µs | 204µs | 4,900 | 2.1× |
| ∞ | ~0 | ~0 | 163µs | 163µs | 6,100 | 2.7× |

Ceiling: ~6,100 req/s per sidecar (pure user logic). With N sidecars,
multiply by N (concurrent pipeline already done).

| Sidecars | Batch 4 | Batch 8 | Express (1 process) |
|---|---|---|---|
| 1 | 3,000 | 4,000 | 2,300 |
| 2 | 6,000 | 8,000 | — |
| 4 | 12,000 | 16,000 | — |

Beats Express at batch size 4 with one sidecar. 3.5× Express at
batch size 8 with two sidecars.

## Key property: no cost at low load

Batch size 1 = identical to current behavior. The batch is "send
what's ready NOW" — no waiting to fill the batch. Under low load,
one request is pending, batch is 1, same overhead as today. Under
high load, multiple pipeline slots have pending work across different
stages, batch grows naturally.

Same pattern as TB's commit_prepare — batch all pending work, process
in one pass. No artificial delay. The batch size is an emergent
property of load, not a configuration knob.

## How it works

Each tick, the server collects all pipeline slots that need sidecar
work:
- Slot 0 at .route → needs route()
- Slot 1 at .handle → needs handle()
- Slot 2 at .render → needs render()

Pack into one message: `[{slot:0, stage:route, data:...}, {slot:1,
stage:handle, data:...}, {slot:2, stage:render, data:...}]`

Send one CALL frame. Sidecar dispatch loop iterates the batch,
calls each handler function, collects results. Send one RESULT
frame with all results.

Server unpacks results, advances each slot's pipeline.

## Protocol change

Current: `CALL(stage, slot, payload) → RESULT(slot, payload)`
Batched: `CALL([item, item, ...]) → RESULT([result, result, ...])`

The CALL frame contains a batch header (item count) followed by
per-item payloads. Each item has a slot index, stage tag, and
stage-specific data. The RESULT frame mirrors the structure.

The QUERY sub-protocol (prefetch SQL) stays per-item within the
batch — a prefetch item may trigger QUERY round-trips before the
batch RESULT is sent.

## Interaction with RT reduction

Batching and RT reduction are complementary:

- **RT reduction** (Phase 1/1b from sidecar-shm-transport.md) reduces
  the number of stages per request (4→3 or 4→2). Fewer stages = fewer
  items per request in the batch.
- **Batching** amortizes the per-crossing overhead across requests.
  More concurrent requests = larger batch.

Both can be done. RT reduction first (simpler, predictable gain),
batching second (load-dependent gain). Or batching alone gets most
of the benefit without requiring annotation changes.

## RT reduction status

Phase 1 (eliminate route RT) was found to be harder than projected.
The route function does body parsing/validation — not just path
matching. Moving it to Zig requires either:
- Annotation DSL for body extraction (burdens the user)
- Moving validation to handle (risks querying on invalid requests
  if server-side prefetch runs before validation)

Phase 1b (server-side prefetch) works for simple handlers (static
SQL, id from route) but not dynamic handlers (create_order's loop
over items). Per-handler decision at build time.

Batching may be higher ROI than RT reduction — it helps all handlers
equally under load, requires no annotation changes, and the gain
scales with concurrency.

## What we're NOT doing

- **Waiting to fill the batch** — send what's ready, every tick.
  No artificial latency. Batch size 1 at low load.
- **Shared memory transport** — transport is <2% of cost. Batching
  addresses the 80% (V8 overhead + transport amortization).
- **Changing the handler API** — sidecar handlers are called the
  same way. The batching is invisible to the user.

## Prerequisites

- Concurrent pipeline (✅ DONE) — multiple slots provide the batch
- Message bus (✅ DONE) — frame transport
- Define batch wire format (item count + per-item payloads)
- Update dispatch.generated.ts to loop over batch items
- Update server commit_dispatch to collect and send batches

## Open questions

- Should the batch CALL wait for all items' QUERY sub-protocol
  exchanges before sending the RESULT? Or send partial results
  as items complete? (Simpler: wait for all, one RESULT.)
- Maximum batch size? Bounded by pipeline_slots_max × stages.
  With 4 slots × 4 stages = 16 items max. Already bounded.
