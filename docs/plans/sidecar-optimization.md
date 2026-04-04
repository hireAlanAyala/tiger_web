# Sidecar optimization

## Current state (re-measured 2026-04-03)

| Mode | 1 conn (req/s) | 128 conn (req/s) | Avg latency |
|---|---|---|---|
| Native Zig | 21,978 | 29,972 | ~45µs |
| Sidecar (1 TS process) | 4,927 | 7,468 | ~200µs |
| Express (prior measurement) | — | ~2,300 | ~440µs |

**The sidecar is already 2-3× faster than Express.** The old 819µs
measurement was stale (before TS runtime optimization + framework
changes). Current overhead is ~155µs per request (200µs - 45µs native).

## Cost breakdown

| Component | Isolated cost | Source |
|---|---|---|
| Unix socket RT | ~6µs | bench-transport.ts |
| V8 serde + handler (per stage) | ~0.4µs | bench-serde.ts |
| 4 RTs × transport | ~24µs | 4 × 6µs |
| 4 RTs × V8 work | ~2µs | 4 × 0.4µs |
| **Measured overhead** | **~155µs** | 200µs - 45µs native |
| **Coordination cost** | **~129µs** | 155µs - 26µs (transport + V8) |

The ~129µs coordination cost is: frame accumulation, CRC validation,
event loop scheduling between Zig tick loop and Node event loop,
QUERY sub-protocol for prefetch.

At ~39µs per RT (155µs / 4 RTs), the overhead per crossing is modest.
Reducing RTs from 4 to 2 would save ~78µs → ~122µs per request →
~8,200 req/s. Meaningful but not transformative.

## Remaining optimization options

### 1. RT reduction (Phase 1b: server-side prefetch)

Eliminate prefetch RT for simple handlers (static SQL, id from route).
Saves ~39µs per RT eliminated + QUERY sub-protocol overhead.

- Simple handlers (get_product, list_products): 3 RT → ~161µs → ~6,200 req/s
- Dynamic handlers (create_order): still 4 RT, unchanged

### 2. Batched dispatch

Batch pending work across pipeline slots into one crossing. Under
load with N concurrent requests, amortizes coordination cost.

At batch size 4: coordination drops from ~129µs to ~32µs/req.
Total: ~77µs/req → ~13,000 req/s per sidecar.

Only helps under load (batch size 1 at low concurrency = no change).

### 3. Concurrent pipeline scaling (already done)

Add more sidecar processes. Linear scaling:

| Sidecars | Current (req/s) | With batching (req/s) |
|---|---|---|
| 1 | 7,468 | ~13,000 |
| 2 | ~15,000 | ~26,000 |
| 4 | ~30,000 | ~52,000 |

### 4. Typed schemas (Phase 3 from sidecar-shm-transport.md)

Correctness fix — typed TS interfaces from SQL annotations.
Negligible perf impact (~4µs saved) but major DX improvement.

## What we're NOT doing

- **Shared memory transport** — transport is 6µs per RT, ~3% of
  the 200µs total. Not the bottleneck.
- **V8 invoke overhead reduction** — isolated benchmarks show V8
  per-call cost is <1µs. Not the bottleneck.
- **Route RT elimination** — route function does body parsing that
  can't be expressed in annotations without a DSL.

## Priority

1. Typed schemas (correctness, DX — no perf dependency)
2. Batched dispatch (biggest perf gain under load)
3. Server-side prefetch for simple handlers (modest gain, some handlers only)
4. More sidecar processes (linear scaling, already works)

## Key learning

The original analysis (819µs, V8 overhead 375µs) was based on stale
measurements taken before the TS runtime optimization (2.8x speedup
from pre-allocated buffers). Always re-measure before optimizing.
The sidecar is already competitive — 2-3× Express without any
further optimization.
