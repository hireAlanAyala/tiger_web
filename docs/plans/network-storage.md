# Network Storage — Concurrent Pipeline for Remote Databases

> **Context:** This plan documents the architectural path from local
> SQLite to network storage (PostgreSQL, CockroachDB, etc.). It is
> not planned for implementation now. It exists to ensure that
> decisions made today (message bus, storage split, pipeline design)
> don't close this door.

## Why this matters

With SQLite in-memory, the server is CPU-bound at 55K req/s.
Every query completes in ~10-100μs (no network, no disk wait).
The serial pipeline (one request at a time) is correct because
there's no IO latency to hide.

With network storage, the profile flips. A PostgreSQL query on a
separate server takes ~500μs-5ms (network round-trip + PG query
execution). The server becomes IO-bound — it sends a query and
sits idle waiting for the response:

```
Serial pipeline with network storage:

Request A: [parse][send SQL ── wait 500μs ── recv result][render][respond]
Request B:                                                       [parse][send SQL ── wait ...
                   ↑ server idle for 500μs per query
```

Throughput ceiling: ~1/(500μs) = ~2K req/s. Down from 55K. The
CPU is 98% idle.

## The solution: concurrent pipeline

TigerBeetle solves this exact problem. Their replication round-
trips take milliseconds. They pipeline up to 8 requests,
overlapping the IO wait:

```
Concurrent pipeline with network storage:

Request A: [parse][send SQL ── wait 500μs ── recv][render][respond]
Request B:   [parse][send SQL ── wait 500μs ── recv][render]
Request C:      [parse][send SQL ── wait 500μs ── recv]
                       ↑ 3 queries in-flight, no idle time
```

Throughput with pipeline depth N: ~N × 2K req/s. With depth 8:
~16K req/s. The IO latency is hidden because while request A
waits for its query result, requests B-H are already in-flight.

### Key insight from TB

TB pipelines the IO-heavy phase (WAL writes + replication) but
serializes the execution phase (state machine commit). This
preserves determinism: same input order → same output order.
Commits execute in strict FIFO, even though prepares overlap.

For us, the mapping is:
- **Prefetch** (IO-heavy) → send SQL query, wait for result.
  This is what we'd pipeline — multiple prefetches in-flight.
- **Commit** (CPU, sequential) → execute handler logic, write
  results. This stays serial — same FIFO order, deterministic.
- **Render** (CPU, may have IO for sidecar) → stays serial.

```
Pipelined prefetch, serial commit:

Req A: [prefetch ── query IO ──][commit][render][respond]
Req B:    [prefetch ── query IO ──][commit][render]
Req C:       [prefetch ── query IO ──][ commit ]
                                      ↑ serial
```

## What changes

### 1. Storage interface becomes async

Today, `ReadView.query()` returns `?T` synchronously. With
network storage, it must be asynchronous:

```zig
// Today (SQLite — synchronous):
const product = storage.read_view.query(Product, sql, args);
// product is available immediately.

// Network storage (asynchronous):
storage.read_view.query_async(Product, sql, args, callback);
// callback fires when result arrives from network.
```

The storage interface (defined by comptime duck typing per
storage-split.md) gains async variants. `SqliteStorage` can
implement them as "call sync, invoke callback immediately" —
no behavioral change for SQLite. `PostgresStorage` submits
the query over the network and invokes the callback when the
response arrives.

This is the same pattern as the Connection's `on_frame_fn`:
submit IO, get callback when complete. The state machine's
`prefetch` already works this way — it returns `.pending` and
gets a callback. The async storage plugs into that mechanism.

### 2. Pipeline becomes concurrent

Today, `commit_stage` is a single enum — one request in the
pipeline at a time. With concurrent prefetch:

```zig
// Today:
commit_stage: CommitStage,  // one slot
commit_connection: ?*Connection,
commit_msg: ?Message,

// Concurrent:
pipeline: [pipeline_depth_max]PipelineSlot,
pipeline_count: u32,

const PipelineSlot = struct {
    stage: CommitStage,
    connection: *Connection,
    msg: Message,
    prefetch_cache: ?Cache,
};
```

`pipeline_depth_max` is a comptime parameter. Each slot holds
one in-flight request. Prefetches run concurrently (multiple
queries in-flight). Commits execute FIFO from the head of
the pipeline — slot 0 commits first, then slot 1, etc.

**Ordering guarantee:** prefetch may complete out-of-order (PG
responses arrive whenever), but commits execute in submission
order. The pipeline sorts this naturally — the head of the
array is always the oldest request.

### 3. Connection pool for PG

Multiple TCP connections to PostgreSQL, each handling one query
at a time. The message bus pattern applies: `ConnectionType(IO)`
for the PG wire protocol, `MessageBusType` for connection
lifecycle. A `PgPool` above the bus manages N connections and
dispatches queries to available ones.

This is the same pool/dispatcher extension point documented in
message-bus.md, applied to the storage layer instead of the
sidecar layer.

### 4. IO layer: epoll vs io_uring

**epoll is sufficient.** The throughput unlock comes from the
concurrent pipeline (overlapping IO waits), not from the IO
submission mechanism. Benchmarks show that at 55K req/s with
SQLite, IO syscall overhead is <1% of CPU. Even with network
storage, the bottleneck is the 500μs network round-trip, not
the ~2μs epoll overhead.

**io_uring helps marginally.** Batched submissions save ~1-2μs
per query. With 8 concurrent queries, that's ~10-16μs per tick
vs epoll's ~20-30μs. On a 500μs query round-trip, this is ~3%
improvement. Not enough to justify the complexity.

**When io_uring matters:** thousands of concurrent connections
with sub-100μs queries (in-memory Redis, not PostgreSQL). Or
async file IO (O_DIRECT to NVMe). Neither is our use case.

## What doesn't change

- **Message bus (message_bus.md)** — Connection and MessageBus
  types are IO-parameterized. Network PG connections use the
  same ConnectionType with a PG wire protocol consumer. No bus
  changes needed.

- **Sidecar** — the sidecar protocol is between the server and
  the TS runtime, not between the server and storage. Sidecar
  CALL/RESULT flows through the message bus regardless of
  whether storage is local or remote.

- **Handler code** — handlers call `storage.query(T, sql, args)`.
  The storage backend is invisible. `SqliteStorage` returns
  synchronously. `PostgresStorage` returns asynchronously. The
  state machine's prefetch/commit split handles the difference.

- **WAL** — records SQL operations, not storage results. WAL
  replay calls `execute_raw` on whatever storage backend is
  configured. Works with any backend.

- **Simulation** — SimIO already intercepts all IO. A
  `SimPgStorage` would return PRNG-delayed query results,
  matching SimSidecar's pattern. Deterministic via seed.

## Decisions made today that preserve this path

| Decision | Why it matters for network storage |
|---|---|
| Storage interface via comptime duck typing (storage-split.md) | PG backend implements same methods. One-line change in app.zig. |
| Prefetch returns `.pending` with callback | Already async. PG query submits and callbacks when result arrives. |
| ConnectionType separated from MessageBusType | PG wire protocol is another ConnectionType consumer. Same transport, different protocol. |
| Comptime pipeline parameterization | `pipeline_depth_max` is a comptime option, like `send_queue_max`. |
| IO layer parameterized on type | Swap epoll → io_uring without touching bus, storage, or handlers. |
| Serial commit after concurrent prefetch | Determinism preserved. Same pattern as TB. |

## Decisions deferred (build when needed)

| Decision | Why defer |
|---|---|
| Concurrent pipeline slots | No IO latency to hide with SQLite. Adds complexity (per-slot state, FIFO ordering) for zero benefit today. |
| PG connection pool | No PG backend. Pool is a server-level component built alongside the concurrent pipeline. |
| io_uring IO layer | Epoll is sufficient. <1% CPU on IO syscalls at 55K req/s. Even with network storage, the pipeline depth matters more than submission batching. |
| Async storage interface | SQLite is synchronous. Async variants add noise to the interface for a backend that doesn't need them. Add when PG backend is built. |

## Estimated throughput with network storage

| Configuration | Throughput | Limiting factor |
|---|---|---|
| Serial pipeline, SQLite in-memory | 55K req/s | CPU (parsing, rendering, SQLite) |
| Serial pipeline, PG over network | ~2K req/s | Single query round-trip (~500μs) |
| Pipeline depth 4, PG over network | ~8K req/s | 4 concurrent queries |
| Pipeline depth 8, PG over network | ~16K req/s | 8 concurrent queries |
| Pipeline depth 8, PG + io_uring | ~16.5K req/s | ~3% io_uring gain, still query-limited |
| Pipeline depth 8, PG, 4 processes | ~64K req/s | Multi-process scaling (4 × 16K) |

The pipeline depth is the multiplier. io_uring is noise.
Multi-process scaling (existing strategy from scaling.md)
compounds with pipeline depth.

## Dependencies

```
storage-split.md        (separate interface from SQLite)
    ↓
message-bus.md          (ConnectionType for PG wire protocol)
    ↓
network-storage.md      (this plan — concurrent pipeline + PG backend)
```

Storage split is prerequisite — clean interface boundary before
adding a second backend. Message bus provides the transport
primitive for PG connections. This plan builds on both.
