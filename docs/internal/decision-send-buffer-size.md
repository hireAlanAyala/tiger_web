# Decision: send_buf_max = 64KB

## Context

Each connection embeds a send buffer for the HTTP response. The
original size was 256KB — sized to fit 50 product cards at worst-case
HTML escaping (5x expansion on every byte of name + description).

At 128 connections, that's 34MB of send buffers alone. We investigated
whether reducing this via cursor pagination would improve throughput
and whether a MessagePool (TB pattern) was needed for connection
scaling.

## Benchmark results

All benchmarks: 128 connections, 100K requests, ReleaseSafe,
mixed workload (creates, gets, lists). Same machine, same seed.

| send_buf_max | list_max | Throughput | RSS | vs 256KB |
|---|---|---|---|---|
| 256KB | 50 | 47,904 req/s | 42MB | baseline |
| 64KB | 18 | 66,212 req/s | 17MB | +38% faster, -60% memory |
| 32KB | 9 | 72,136 req/s | 12MB | +51% faster, -71% memory |

## Why 64KB, not 32KB

32KB is 9% faster than 64KB, but forces `list_max = 9` (worst-case
product card is 3,472 bytes — only 9 fit in 32KB minus header
reserve). This is too tight:

- 9 items per page feels sparse. 10 is the conventional minimum,
  15-20 is comfortable.
- Multi-list dashboards (products + orders + collections rendered
  eagerly in one page load) need headroom beyond a single list.
- `dashboard_list_max` must be ≤ `list_max`, so 9 caps the dashboard
  too.

64KB allows `list_max = 18` — a comfortable page size with room for
dashboard views. The big win was 256KB → 64KB (38% throughput, 60%
memory). The marginal 9% from 64KB → 32KB isn't worth halving the
page size.

## Why the improvement

The server is single-threaded with SQLite in the hot path. L1 cache
(32-48KB) doesn't matter — SQLite evicts it during prefetch regardless
of buffer size. The win comes from **L2 residency**:

- At 256KB: each connection's buffers (270KB total) exceed L2
  (256KB-1MB typical). 128 connections × 270KB = 34MB stresses L3.
- At 64KB: each connection's buffers (76KB total) fit in L2. 128
  connections × 76KB = 9.5MB fits comfortably in L3.

The active connection's working set staying in L2 during the
send phase is where the throughput gain comes from.

## Connection scaling (64KB buffers, max_connections=1024)

To verify no pool is needed, we benchmarked across connection counts
with 64KB send_buf_max. All connections pre-allocated at startup
(max_connections=1024), varying how many are active.

| Connections | Throughput | RSS |
|---|---|---|
| 1 | 46,132 req/s | 86MB |
| 4 | 60,856 req/s | 87MB |
| 16 | 64,728 req/s | 87MB |
| 32 | 64,797 req/s | 87MB |
| 64 | 69,393 req/s | 88MB |
| 128 | 66,036 req/s | 86MB |
| 256 | 66,466 req/s | 87MB |
| 512 | 61,306 req/s | 86MB |
| 1024 | 64,596 req/s | 87MB |

**Findings:**

1. **RSS is flat at ~87MB regardless of active connections.** All 1024
   connection structs are allocated at startup (1024 × 76KB = 76MB +
   SQLite/stack). Memory scales with max_connections (compile-time),
   not active connections (runtime).

2. **Throughput plateaus at 16 connections (~65K req/s) and stays flat
   through 1024.** The bottleneck is SQLite (single-threaded), not
   connections or buffers. More connections just means more idle
   connections waiting for the pipeline.

3. **No throughput degradation at high connection counts.** The
   original problem (256KB buffers causing cache thrashing at 512
   connections, throughput collapsing to 6K req/s) is completely gone.

### Sidecar (TypeScript handlers, 64KB send_buf_max)

Same test with sidecar enabled (TS handlers via unix socket IPC):

| Connections | Throughput | RSS |
|---|---|---|
| 1 | 10,750 req/s | 22MB |
| 4 | 11,750 req/s | 22MB |
| 16 | 9,930 req/s | 22MB |
| 32 | 10,907 req/s | 22MB |
| 64 | 10,831 req/s | 22MB |
| 128 | 10,592 req/s | 22MB |

Same pattern: flat throughput, flat RSS. Bottleneck is IPC latency
(~6x slower than native), not buffers. No pool needed for either path.

## Why not a MessagePool

The original investigation asked: do we need TB's MessagePool pattern
(shared buffer pool, borrow/return lifecycle) for connection scaling?

**No.** Pagination solved the underlying problem. The scaling benchmark
confirms it: 1024 connections at 64KB buffers performs identically to
16 connections. No cache thrashing, no throughput collapse.

A pool adds complexity (borrow/return state machine, exhaustion
handling, progress guarantee proofs, SimIO changes) to solve a
problem that no longer exists after pagination. TB's advice applies:
don't build infrastructure for a problem that doesn't exist.

The one thing a pool would buy: reducing RSS by only allocating
buffers for active connections. At max_connections=128 this saves
nothing meaningful (87MB → ~15MB active + overhead). At
max_connections=1024 it could matter (87MB → ~15MB), but only if
you need 1024 connection slots while rarely using more than ~100.
That's a deployment question, not a design question — revisit when
real traffic data exists.

## What changed

- `send_buf_max`: 256KB → 64KB (in `framework/http.zig`)
- `list_max`: 50 → 18 (in `message.zig`)
- `query_all`: comptime check requires LIMIT in SQL (in `storage.zig`)
- `encode_response`: runtime panic with actionable message on buffer
  overflow (in `app.zig`)
- `server.zig`: imports `max_connections` from `constants.zig` (was
  hardcoded duplicate)
- HTTP buffer constants consolidated in `http.zig` as single source
  of truth (removed duplicate from `constants.zig`)
- Cursor pagination implemented in all list handlers
  (`list_products`, `list_collections`, `list_orders`): route parses
  `?cursor=<uuid>`, prefetch adds `WHERE id > ?cursor`, render appends
  Datastar load-more sentinel when page is full
- `load_driver.zig`: `--sidecar` flag spawns the TS runtime alongside
  the server for consistent native vs sidecar benchmarking

## Cursor pagination (prerequisite)

Reducing `send_buf_max` required reducing `list_max` — fewer items
per response. Cursor pagination makes this transparent to users:

- Each list response returns one page + a load-more sentinel
- Sentinel uses Datastar's `data-on-intersect` — scrolling triggers
  the next page fetch automatically
- `ListParams.cursor: u128` (already in the message type) carries the
  last item's UUID
- SQL: `WHERE id > ?cursor ORDER BY id LIMIT ?page_size`
- No server-side session state, no offset scanning, O(1) with index

See `docs/guide/pagination.md` for the user-facing pattern.
