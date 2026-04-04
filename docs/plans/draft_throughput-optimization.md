# Throughput optimization — per-connection performance

## Current bottleneck (perf profile, 2026-04-04)

| Component | CPU % | What it does |
|---|---|---|
| HTTP string matching | 58% | mem.eqlBytes + mem.indexOf for header parsing |
| HTTP parse_request | 4% | Frame detection + header extraction |
| find_header_value | 6% | Linear scan for Connection, Cookie, Datastar, Content-Length |
| Server tick | 4% | Periodic work (accept, metrics) |
| SQLite | <5% | In-memory reads served from OS page cache |
| Everything else | ~23% | Render, routing, epoll, syscalls |

HTTP parsing is 68% of CPU. The rest is noise. Optimizing anything
else before HTTP parsing is wasted effort.

## Options (ordered by value)

### 1. Parse headers once, cache offsets — HIGH VALUE

`find_header_value` is called 4 times per request (Connection,
Cookie, Datastar-Request, Content-Length). Each call scans the
entire header block linearly. Four O(N) scans on the same bytes.

Fix: single-pass header scan. Walk the headers once, record
offsets for all known headers. Four lookups become O(1) indexed
reads into the offset table.

```
Before: 4 × O(header_bytes) = 4 × ~200 = 800 byte comparisons
After:  1 × O(header_bytes) = 200 byte comparisons + 4 indexed reads
```

Expected impact: ~3× reduction in HTTP parsing CPU (68% → ~25%).
Throughput: ~72K → ~120K+ native.

Complexity: Medium. Change parse_request to build a header offset
table, pass it through to routing/auth/render.

### 2. SIMD header matching — MEDIUM VALUE

Replace `mem.eqlBytes` and `mem.indexOf` with SIMD-accelerated
versions. x86-64 AVX2 can compare 32 bytes per cycle. The
current scalar code compares 1 byte per cycle.

Zig's std.mem functions may already vectorize in ReleaseSafe.
Check with `-Doptimize=ReleaseFast` to see if auto-vectorization
helps before writing manual SIMD.

Expected impact: 2-4× faster string matching. If headers are
already parsed in one pass (#1), this has less impact.

Complexity: Low if auto-vectorization works. High if manual SIMD.

### 3. Connection-level header caching — MEDIUM VALUE

Keep-alive connections send similar headers on every request
(same User-Agent, same Cookie, same Accept). Cache the parsed
header offsets per connection. On the next request, verify the
header block matches the cached version (memcmp). If match,
skip parsing entirely.

Expected impact: near-zero HTTP parsing for keep-alive after the
first request. Only helps repeat clients (browsers, hey benchmark).

Complexity: Medium. Need hash of header block, cached offset table
per connection. Cache invalidation on mismatch.

### 4. Reduce send buffer size — LOW VALUE, EASY WIN

`send_buf_max = 256KB` per connection. Most responses are <10KB.
Reducing to 64KB saves 192KB per connection = 24MB at 128 conns.
Better cache utilization. TB sizes buffers to the actual workload.

Expected impact: modest (cache pressure is not the bottleneck at
128 connections). Significant at >128 connections.

Complexity: Low. Change one constant. Verify no response exceeds
the new limit.

### 5. Batched sidecar dispatch — SIDECAR ONLY

Batch all pending sidecar work into one process boundary crossing.
V8 function calls within one invocation are ~1µs. Crossing the
boundary is ~33µs. Batching amortizes the crossing cost.

See: docs/plans/sidecar-optimization.md

Expected impact: sidecar throughput scales with batch size under
load. No benefit at low concurrency (batch=1).

Complexity: High. New wire format, dispatch loop changes on both
Zig and TypeScript sides.

### 6. HTTP/2 multiplexing — LOW VALUE

Multiple requests on one TCP connection. Eliminates connection
setup overhead. But hey already uses keep-alive (1 connection, N
requests). HTTP/2 helps browsers (6 connections → 1) but doesn't
change peak throughput.

Expected impact: negligible for throughput. Helps connection count.

Complexity: Very high. Full HTTP/2 parser (HPACK, streams, flow
control). Not worth building — use a reverse proxy (Caddy, nginx).

### 7. MessagePool — CONNECTION SCALING

Shared buffer pool instead of per-connection embedded arrays.
See docs/plans/todo.md #15.

Expected impact: enables >128 connections without cache pressure.
No throughput change at ≤128 connections.

Complexity: Medium. Copy TB's message_pool.zig (343 lines).

## Recommendation

Do #1 first. It addresses 68% of CPU with a medium-complexity
change. If #1 gets throughput to ~120K, the next bottleneck
becomes visible and guides the next optimization.

Do NOT do #2 until after #1 — SIMD on a single-pass parser has
diminishing returns. Do #4 as a quick win alongside #1. Do #5
when sidecar throughput matters more than native.
