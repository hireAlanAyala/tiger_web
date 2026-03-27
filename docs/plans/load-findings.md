# Load Test Findings

Results from implementing and running `zig build load` against the
tiger-web server. i7-14700K, single core, SQLite, Linux.

## Baseline (before optimizations)

| Connections | Throughput | p50 | p99 | p100 |
|---|---|---|---|---|
| 10 | 15,661 req/s | 0ms | 1ms | 2ms |
| 50 | 27,364 req/s | 1ms | 3ms | 4ms |
| 128 | 30,574 req/s | 4ms | 6ms | 7ms |

Throughput scales from 10→50 connections (tick batching amortizes
fsync). Plateaus at 128 — the single-threaded tick loop is saturated.
Latency increases proportionally with connections (more queuing per
tick). RSS flat at ~20MB regardless of connection count — no
per-request allocation.

## What we tested

### Tick interval: 10ms → 1ms — no change

| Connections | 10ms tick | 1ms tick |
|---|---|---|
| 10 | 15,661 | 15,170 |
| 50 | 27,364 | 27,064 |
| 128 | 30,574 | 30,929 |

The server wasn't sleeping. Under load, `epoll_wait` returns
immediately because there are always pending events. The tick interval
only matters when idle. Reverted.

### SQLite synchronous=NORMAL — +21%

| Config | Throughput | Change |
|---|---|---|
| synchronous=FULL (default) | 30,574 | — |
| synchronous=NORMAL | 37,099 | +21% |

Skips fsync on regular commits. Safe against process crash (SQLite WAL
journal survives). Not safe against bare-metal power loss, but cloud
VPS storage provides power-loss durability at the hardware level.
**Kept as default.**

### Tiger-web WAL disabled — +3%

| Config | Throughput | Change |
|---|---|---|
| WAL enabled | 30,574 | — |
| WAL disabled | 31,549 | +3% |

The tiger-web WAL batches all mutations per tick into one `write()`
syscall. One write per tick is cheap — the OS page cache handles it
asynchronously. Not worth disabling. Reverted.

### SQLite cache_size=32MB — no change

Dataset (4.5MB) already fits in the default 2MB page cache after
warmup. Larger cache doesn't help. Reverted.

### SQLite mmap_size=256MB — no change

Kernel already caches the file in memory. Memory-mapping doesn't
eliminate any real disk reads. Reverted.

## perf profile (128 connections, 100K requests)

| % CPU | Function | Category |
|---|---|---|
| 19% | memcpy | Response encoding — HTML into send buffer |
| 4% | mem.eqlBytes | HTTP header matching, route matching |
| 4% | memset | Buffer zeroing |
| 4% | pthread_mutex_lock | SQLite internal locking |
| 3% | mem.indexOfPos | HTTP parsing — searching for \r\n |
| 1.5% | html.escaped | HTML entity escaping in render |
| 1.5% | read_row_mapped | SQLite row reading |
| 1% | malloc/free | SQLite internal allocation |
| 0.7% | render_product_card | HTML rendering |
| 0.7% | parse_request | HTTP request parsing |
| 0.5% | sign_cookie | HMAC-SHA256 auth cookies |
| 0.5% | sqlite3_prepare_v2 | SQL statement preparation |

## Key findings

1. **The server is CPU-bound, not IO-bound.** Disk, network, and
   sleep are not the bottleneck. The CPU spends its time processing
   requests — parsing HTTP, querying SQLite, rendering HTML, copying
   responses into buffers.

2. **memcpy at 19% is the single largest cost.** Most of it comes from
   `process_inbox` — the response encoding path where HTML is rendered
   into a scratch buffer then copied into the send buffer (header
   backfill pattern). Rendering directly into the send buffer at the
   correct offset would eliminate this copy.

3. **SQLite is not the bottleneck.** All operations (reads and writes)
   have nearly identical latency. Tick batching amortizes fsync — 128
   writes in one transaction cost almost the same as 1 write.

4. **fsync was the hidden floor.** `synchronous=NORMAL` removed the
   per-tick fsync and gained 21%. This was invisible in perf because
   fsync is a kernel wait, not CPU work.

5. **The state machine is fast.** Bench shows 12-44μs per operation.
   At 10 connections, full-stack latency is <1ms — HTTP overhead adds
   less than 1ms. The tick loop saturates because of volume, not
   per-request cost.

## Bugs found during implementation

1. **WAL buffer aliasing** — `wal_record_buf` and `wal_scratch` pointed
   to the same memory. Every mutation crashed with `@memcpy arguments
   alias`. Fixed by adding separate `wal_record_scratch` buffer.

2. **Percentile floor division** — `@divTrunc(50 * 1, 100) = 0`
   matched empty histogram buckets at p1. Fixed with ceiling division.

## New baseline (after synchronous=NORMAL)

| Connections | Throughput | p50 | p99 | p100 |
|---|---|---|---|---|
| 10 | ~36,000 req/s | 0ms | 0ms | 3ms |
| 128 | ~37,000 req/s | 3ms | 7ms | 8ms |

## Next optimization target

Reduce memcpy in the response encoding path. The render scratch buffer
→ send buffer copy in `app.commit_and_encode` accounts for the majority
of the 19% memcpy cost. Rendering directly into the send buffer at the
header-reserved offset would eliminate this copy.
