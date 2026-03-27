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

## Architectural decisions resolved during implementation

### Monotonic counters, not decrement-on-error

The original design decremented `requests_sent` in error paths to
"undo" a failed request. This created underflow risk, made state
relationships hard to reason about, and required manual counter
management in every callback. The root issue: the request lifecycle
wasn't clean. A clean lifecycle has one path forward — dispatch → send
→ recv → complete. Errors reconnect and go idle. `dispatch_all` on the
next tick re-activates the connection with a fresh request. Counters
only increment. The invariant is simple: `requests_completed <=
requests_dispatched`, and the gap reflects lost requests.

### Per-request state belongs on Connection, not LoadGen

The first implementation stored `last_created_id` on the LoadGen
struct. Multiple connections interleave via callbacks — connection A
formats a request (sets last_created_id), connection B formats a
request (overwrites last_created_id), connection A's response arrives
(reads B's ID). The fix: `created_id` lives on the Connection. The
connection that formats the request owns the ID through to completion.
No shared mutable state between connections.

### Stdout readiness signal, not stderr log parsing

The first implementation parsed "listening on port N" from stderr logs
with a retry loop. Two bugs: `readAll` on a pipe hangs when the port
number is fewer bytes than the buffer size (the server never closes
stdout), and the retry loop masked a missing readiness signal. The
fix: server writes the port to stdout as a bare number + newline.
Driver reads stdout with `read()` (returns on first data). One
mechanism, deterministic.

### Per-connection PRNG derived from parent, not XOR

`seed ^ connection_index` produces correlated xoshiro256 sequences
for seeds differing by one bit. The correct pattern (matching TB):
create a parent PRNG from the seed, derive each connection's PRNG by
consuming `parent_prng.int(u64)`. Independently distributed sequences.

### Format fuzzer validates sizing, not comptime constants

The first implementation had hand-calculated worst-case body sizes
(`product_body_max = 114`) with comptime assertions that they fit in
`send_buf_max`. These were parallel truth — if someone added a field
to `fmt_create_product`, the constant wouldn't update and the
assertion would still pass. The fuzzer (90,000 random inputs across
all 9 operations) is the real validation. The runtime assert in
`fmt_post` catches overflow. Together they prove the buffer never
overflows without maintaining a second source of truth.

### WAL buffer aliasing was a server bug, not a load test issue

The load test's first POST request crashed the server with `@memcpy
arguments alias`. The server's `wal_record_buf` pointed to the same
buffer as `wal_scratch` — WriteView recorded SQL writes into the
same memory that `append_writes` used to assemble the WAL entry.
Fixed by adding a separate `wal_record_scratch` buffer. The load test
proved its value before it finished — it found a real server bug that
affected all mutations.

## Next optimization target

Reduce memcpy in the response encoding path. The render scratch buffer
→ send buffer copy in `app.commit_and_encode` accounts for the majority
of the 19% memcpy cost. Rendering directly into the send buffer at the
header-reserved offset would eliminate this copy.
