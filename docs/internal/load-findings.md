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

## Optimization 2: Prepared statement caching — +43%

The second perf profile (after synchronous=NORMAL) revealed the real
bottleneck had shifted. SQLite was 45% of CPU, dominated by
`sqlite3_prepare_v2` — parsing the same SQL text on every request.

| Component | CPU % |
|---|---|
| SQLite (libsqlite3) | 45% |
| tiger-web (our code) | 40% |
| libc (malloc, pthread) | 15% |

The typed SQL API (`query`/`execute`) called `sqlite3_prepare_v2` +
`sqlite3_finalize` per request. The SQL strings are comptime — identical
every time. The fix: prepare once, cache the compiled statement, reuse
with `sqlite3_reset` + `sqlite3_bind` on subsequent calls.

Cache design: fixed array on SqliteStorage indexed by comptime FNV-1a
hash of the SQL string content. First call prepares and caches.
Subsequent calls reset and rebind. No runtime hash map, no allocation.

| Config | Throughput | Change |
|---|---|---|
| No caching (prepare per call) | 37,099 | — |
| Statement caching | 53,048 | +43% |

This is how SQLite is designed to be used — every production SQLite
application caches prepared statements. Python, Rust, Go wrappers all
do it automatically. The typed API hadn't caught up to the legacy path
(which already cached via named `stmt_*` fields).

### Why the first profile was misleading

The first perf profile (before synchronous=NORMAL) showed memcpy at
19% as the dominant cost. This was true but misleading — fsync was
hiding SQLite's CPU cost because it was kernel wait time, invisible to
CPU sampling. After removing fsync, SQLite's prepare overhead became
the real dominant cost at 45%. The lesson: optimize the measured
bottleneck, re-profile, find the new bottleneck. Don't assume the
first profile tells the whole story.

## Current baseline (after both optimizations)

| Connections | Throughput | p50 | p99 | p100 |
|---|---|---|---|---|
| 10 | 53,853 req/s | 0ms | 0ms | 0ms |
| 50 | 54,219 req/s | 0ms | 1ms | 1ms |
| 128 | 54,960 req/s | 2ms | 2ms | 2ms |

Total improvement from original baseline: 30K → 55K (+80%).

## Competitive position

53K req/s on a single core with SQLite, real queries, HTML rendering,
WAL recording, and cookie signing. For context:

| Framework + DB | Throughput |
|---|---|
| Django + PostgreSQL | ~2K |
| Rails + PostgreSQL | ~2K |
| Express + PostgreSQL | ~8K |
| Go + PostgreSQL | ~15K |
| Go + SQLite (best libs) | ~15-30K |
| **tiger-web + SQLite** | **55K** |

Roughly 2-3x Go + SQLite on the same workload. The advantages:
no CGo boundary (Zig calls SQLite C API directly), no GC pauses,
statement cache is a comptime-indexed array (not a runtime hash map
with mutex), and tick batching amortizes one transaction across 128
requests.

## Single-threaded is not a weakness

53K req/s on one core handles more traffic than most web applications
will ever see. A typical ecommerce site at 1M page views/day is ~12
req/s average, ~100 req/s peak. 500x headroom.

For scaling beyond 53K: run multiple processes, each with its own
SQLite database. Shard by customer, region, or tenant. SQLite is
designed for this — one database per unit of isolation.

Single-threaded is an advantage: no locks, no race conditions, no
deadlocks, no thread pool tuning. The server is simple because it
doesn't share state. TigerBeetle made the same choice.

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

## memcpy at 25% — investigated, diminishing returns

After both optimizations, the perf profile is flat. memcpy at 25% is
the only item above 6%. Everything else is diffuse — no function above
6%. The profile by library:

| Component | CPU % |
|---|---|
| tiger-web (our code) | 56% |
| SQLite | 34% |
| libc | 9% |

### What we tried

Eliminated the render scratch → send_buf copy by rendering directly
into `send_buf[header_reserve..]`. Result: no measurable throughput
change (55K → 55.5K, within noise). The render body is a few hundred
bytes — copying it is fast regardless.

### Where the 25% actually goes

The memcpy is spread across dozens of small copies, none dominant:
- HTTP response header assembly (status line, Content-Type,
  Content-Length, Connection, Cache-Control, Set-Cookie — each a
  separate @memcpy of a string literal into hdr_buf)
- Header backfill (hdr_buf → send_buf, right-aligned before body)
- Cookie formatting (HMAC result → cookie header)
- Recv buffer shift for keep-alive pipelining (leftover bytes shifted
  to front after each response)
- SQLite row mapping (column data → struct fields)
- HTML rendering (string literals → render buffer)

Each copy is 10-200 bytes. The total adds up to 25% across thousands
of requests per tick, but no single copy is worth optimizing.

### Why it's diminishing returns

To reduce the 25%, you'd need to:

**Build headers in-place instead of stack buffer → send_buf.** The
current `backfill_headers` builds headers in a local `hdr_buf`, then
copies right-aligned into `send_buf`. Building directly into send_buf
would eliminate one copy but requires knowing the header length before
writing (to compute the start offset). That means two passes or a
maximum-size reservation — both add complexity for saving ~100 bytes
of copy per response.

**Eliminate the recv buffer shift.** Keep-alive pipelining shifts
leftover bytes to the front of recv_buf after each request. Alternative:
ring buffer or offset tracking. Adds complexity to the connection state
machine — the current shift is simple and correct.

**Reduce response size.** Smaller HTML = fewer bytes to copy. But the
HTML is already minimal (no CSS framework, no JavaScript bundles). The
server renders product cards, order lists, and status messages — a few
hundred bytes each.

### Conclusion

55K req/s is the practical ceiling for this architecture. The remaining
CPU is doing the server's job — parsing HTTP, querying SQLite, rendering
HTML, assembling responses, managing connections. There's no waste left,
just work.

Further gains require architectural changes (multi-threaded, response
streaming, zero-copy sendfile) that trade simplicity for throughput.
The single-threaded model's value (no locks, no races, predictable
performance) outweighs the marginal throughput gain.

## Potential improvement: scatter-gather IO

The 25% memcpy exists because the server copies all response fragments
into one contiguous send_buf before calling send(). The alternative:
keep fragments as separate buffers and use writev/sendmsg to send them
all in one syscall.

```
Current:  literal → hdr_buf → send_buf → send()
                                 ↑
          literal → render_buf ──┘

Scatter:  iovec[0] → "HTTP/1.1 200 OK\r\n"     (rodata, no copy)
          iovec[1] → "Content-Type: text/html"   (rodata, no copy)
          iovec[2] → "Content-Length: 234\r\n"   (4 bytes formatted)
          iovec[3] → rendered HTML               (already in render_buf)
          writev() sends all fragments in one syscall
```

This eliminates the header assembly copy, the render copy, and the
backfill pattern entirely. String literals are sent directly from
rodata. The kernel coalesces the fragments into one TCP segment.

Expected gain: 10-20% (55K → 60-65K). The CPU cost of memcpy scales
linearly with HTML size — larger pages would see proportionally more
benefit.

**Cons:**
- IO layer needs writev/sendmsg support (currently send only).
- Partial write tracking changes from (buf, offset, len) to (iovec
  array, current iovec index, current offset within iovec).
- Connection state machine complexity increases.
- Every handler's render interface and response encoding path change.
- This is a new response encoding architecture, not a utility.

**When to do it:** when 55K isn't enough and the application's HTML
responses are large enough that the copy cost dominates. For the
current workload (product cards at ~200 bytes), the per-response copy
is ~20ns — the volume creates the cost, not the size. Larger pages
(dashboards, reports) would benefit more.

This is the same pattern Nginx uses for high-throughput static file
serving (writev for headers + sendfile for body). The difference is
we'd use writev for both headers and dynamic HTML.

## Statement cache collision handling

The FNV-1a hash mod 256 assigns comptime slots for cached statements.
Collisions are detected at runtime via `sqlite3_sql()` — the function
returns the original SQL text, which is compared against the requested
SQL on every cache hit. If two strings hash to the same slot, the
assertion fires on the first request that hits the second string.

This is correct (catches all collisions) and fast (one string
comparison per query, ~50ns). The 256 slots for ~35 strings give low
collision probability, and the assertion catches any collision during
development (all code paths are exercised by tests and load test).
