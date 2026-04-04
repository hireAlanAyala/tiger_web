# Sidecar optimization

## Current state (measured 2026-04-04, clean system, 200K requests)

| Mode | c=32 | c=64 | c=128 |
|---|---|---|---|
| Native Zig | 73K | 75K | 72K |
| 1 sidecar | 8.5K | 8.6K | 10K |
| 2 sidecars | 25K | 25K | 25K |
| Express | — | — | ~2.3K |

**11× faster than Express.** Callback model is 32% faster than tick
model for sidecar (25K vs 19K on clean system). Native: 72K stable
across all concurrency levels with 200K requests per run.

**Bottleneck:** perf shows 58% CPU in HTTP string matching for native.
Sidecar bottleneck is 4 protocol round-trips (~33µs coordination/RT).
SQLite is not the bottleneck (OS page cache serves in-memory reads).

**IMPORTANT:** Earlier measurements of 55K-140K were inflated by
orphaned Node.js processes (63 leaked across benchmark runs).
Always use `scripts/loadtest.sh` or verify zero orphans manually.

## Cost breakdown (isolated benchmarks)

| Component | Cost | Method |
|---|---|---|
| Unix socket RT (Node↔Node) | 6µs | bench-transport.ts |
| V8 serde + handler per stage | 0.4µs | bench-serde.ts |
| 4 RTs × transport | ~24µs | 4 × 6µs |
| 4 RTs × V8 work | ~2µs | 4 × 0.4µs |
| Coordination (frame/CRC/scheduling) | ~132µs | 158µs - 26µs |
| **Total sidecar overhead** | **~158µs** | |

The coordination cost (~132µs, ~33µs/RT) is frame accumulation, CRC
validation, and event loop scheduling between Zig tick and Node event
loop. Not transport, not V8.

## Scaling behavior

1 sidecar is the bottleneck at high concurrency — single-threaded
Node.js processes one request at a time. Adding sidecars scales
linearly until the Zig server (HTTP/SQL/epoll) saturates.

| Sidecars | 128 conn (req/s) | % of native | vs Express |
|---|---|---|---|
| 1 | 6,853 | 13% | 3× |
| 2 | 45,089 | 83% | 19× |
| 4 (projected) | ~54,000 | ~99% | ~23× |

With 2 sidecars, the Zig server becomes the bottleneck at 128 conn
(45K vs 54K native ceiling). Adding more sidecars yields diminishing
returns — the server's single-threaded tick loop saturates.

## Where optimization matters

**High concurrency: solved.** 2 sidecars + concurrent pipeline =
83% of native. Adding a third sidecar would approach 100%.

**Low concurrency (serial): still 3× slower than native.** 268µs vs
110µs. The 158µs overhead is the coordination cost of 4 RTs. This
is where RT reduction or batching helps:

| Optimization | Serial latency | Serial req/s |
|---|---|---|
| Current (4 RT) | 268µs | 3,725 |
| 3 RT (remove prefetch RT) | ~228µs | ~4,400 |
| 2 RT (hypothetical) | ~188µs | ~5,300 |
| Batching (no help at c=1) | 268µs | 3,725 |

RT reduction improves serial latency. Batching only helps under load.
Neither is urgent — the system is already competitive.

## Remaining options (prioritized)

### 1. Typed schemas (Phase 3 from sidecar-shm-transport.md)
Correctness and DX fix, not perf. Typed TS interfaces from SQL
annotations. Negligible perf impact. High value.

### 2. Server-side prefetch for simple handlers
Eliminates 1 RT for static-SQL handlers (get_product, list_products).
Saves ~40µs/req serial latency. Moderate implementation effort.

### 3. Third sidecar process
Zero implementation effort. Approaches native throughput ceiling.
Costs one more Node.js process (~50MB RSS).

### 4. Batched dispatch
Amortizes coordination overhead under load. Most benefit at high
concurrency where we're already at 83% of native. Low priority
given scaling already works.

## What we're NOT doing

- **Shared memory transport** — transport is 6µs/RT, 4% of overhead
- **V8 invoke overhead reduction** — V8 per-call cost is <1µs
- **Route RT elimination** — route does body parsing, can't move to Zig
- **Further optimization** — 2 sidecars already deliver 19× Express

## Query result cache (next step)

perf profile shows ~70% of CPU in libsqlite3. The framework ceiling
without SQLite is ~200K req/s. A per-query cache at the storage
boundary would skip SQLite on repeated reads:

- Cache sits on ReadView — transparent to handlers
- Key: `(sql_ptr, param_bytes)` — comptime SQL pointer + runtime params
- Invalidation: any WriteView.execute() clears all entries
  (table-level invalidation possible later via comptime SQL analysis)
- Fixed-size bounded hash map, no allocation after init
- Both native and sidecar paths benefit (ReadView.query for native,
  ReadView.query_raw for sidecar)

Design decision: per-query (at storage level) vs per-response (at
server level). Per-query is the right primitive — it's reusable
across operations, and the storage boundary is where the cost is.
Per-response would skip the entire pipeline but requires handling
per-request headers (cookies) which complicates caching.

## Key learning

1. Always re-measure before optimizing. The old 819µs was stale.
2. V8 JIT warmup matters enormously — cold: 7.5K, warm: 45K req/s.
3. Concurrent pipeline (N sidecars) is the most effective optimization
   — it multiplies throughput without reducing per-request overhead.
4. The coordination cost (~33µs/RT) is the real overhead, not V8 or
   transport. But at 83% of native with 2 sidecars, it's acceptable.
