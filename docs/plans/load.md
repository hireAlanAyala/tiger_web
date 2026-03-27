# Load Test — Full-Stack Capacity Testing

`tiger-web load` throws real HTTP traffic at a running server and
measures throughput and latency. It answers one question: how much
traffic can this server handle?

## Usage

```
zig build load
zig build load -- --seed=42 --connections=10 --requests=10000
zig build load -- --port=3000 --requests=5000
zig build load -- --analysis
```

## Implementation checklist

### 1. File structure

- [x] `load_driver.zig` — orchestrator. Start server, delegate to load
  generator, cleanup, report sizes. Imports `load_gen.zig`.
- [x] `load_gen.zig` — workload. Generation, measurement, reporting.
- [x] Driver never imports load_gen internals. Load_gen never imports
  driver.
- [x] `build.zig` — `tiger-load` executable + `zig build load` step.

### 2. CLI parsing

- [x] `--seed` — PRNG seed. Default 42.
- [x] `--connections` — concurrent HTTP connections. Default 10.
- [x] `--requests` — total requests to send. Default 10,000.
- [x] `--ops` — `operation:weight,operation:weight`. Default: fixed weights.
- [x] `--seed-count` — entities in seed phase. Default 1,000.
- [x] `--port` — use existing server instead of starting one.
- [ ] `--batch-delay` — not yet implemented. Will be added when needed.
- [ ] `--print-batch-timings` — not yet implemented. Will be added when needed.
- [x] `--analysis` — print scaling analysis after results.
- [x] `--db` — database file path. Default `tiger_web_load.db`.
- [x] Validate incompatible args: `--db` cannot be used with `--port`.
- [x] Warn if not built with release mode.

### 3. Driver — server lifecycle

- [x] Spawn server as `std.process.Child` with `--port=0`.
- [x] Read port from stdout (readiness signal, not stderr log parsing).
- [x] Server writes port to stdout after bind+listen (`main.zig` change).
- [x] Keep stdin pipe open (close + SIGTERM for shutdown).
- [x] Set `request_resource_usage_statistics = true` before spawn.
- [x] Database file in CWD, not /tmp (real filesystem, not tmpfs).
- [x] All cleanup via defer (data file, WAL, SHM, process, allocator).
- [x] If `--port` given, skip spawn, connect to existing server.
- [x] Report RSS from child process resource usage.

### 4. Concurrent IO

- [x] Use `framework/io.zig` with epoll for N connections on one thread.
- [x] Each connection: submit send, get completion, pipeline next
  request in callback.
- [x] Blocking connect to localhost (instant), then set O_NONBLOCK for
  async send/recv. No IO abstraction bypass.

### 5. Connection lifecycle

- [x] Open N connections at startup with `Connection: keep-alive`.
- [x] Reuse connections across requests (no connect-per-request).
- [x] On server close: reconnect automatically, go idle, dispatch_all
  on next tick re-activates. No counter manipulation in error paths.
- [x] Track reconnection count as reported metric.

### 6. Seed phase (untimed)

- [x] Create `--seed-count` products + seed_count/5 collections.
- [x] Assert seed counts met (>= due to pipelining overshoot).
- [x] Report number of entities seeded.
- [x] Track created IDs on Connection (per-request state, not shared).

### 7. Warmup phase (untimed)

- [x] Run max(100, 1% of `--requests`) requests across all operations.
- [x] Discard results. Reset histograms.
- [x] Drain all in-flight before transitioning.

### 8. Load phase (timed)

- [x] Fire mixed workload across N connections — reads and writes
  interleaved per operation weights.
- [x] Select operation per request using PRNG + weights.
- [x] Serialize each payload per codec expectations: JSON body for
  POST, URL path for GET.
- [x] Record per-request latency (send to response) into per-operation
  histogram.
- [x] Callbacks pipeline: response callback immediately dispatches next
  request on that connection.
- [x] Drain all in-flight before reporting.

### 9. Request lifecycle

- [x] Monotonic counters: `requests_dispatched` and `requests_completed`
  only increment. No decrements, no undo.
- [x] Error recovery: reconnect, go idle. `dispatch_all` on next tick
  handles re-dispatch. Lost requests are reflected in the gap between
  dispatched and completed.
- [x] `invariants()` after every tick — checks counter monotonicity,
  busy connections == in-flight, pool bounds.
- [x] Event loop: `run_for_ns` → `dispatch_all` → `invariants`.

### 10. Histograms

- [x] One histogram per operation. 10,001 buckets, 1ms each. Last
  bucket is 10,000ms+.
- [x] Report when latency exceeds histogram resolution.
- [x] `percentile_from_histogram` — standalone function, ceiling
  division to avoid matching empty buckets at p1.

### 11. Assertions

- [x] `invariants()` checked after every tick (TB pattern).
- [x] Preconditions at public entries (init, run, dispatch_request,
  submit_send, submit_recv, connect_one, reconnect).
- [x] Pair assertions: dispatch sets state → callback asserts state.
  Format sets created_id → on_response_complete asserts created_id.
- [x] `assert(created_id != 0)` for creates, not a guard.
- [x] On every HTTP response: `\r\n\r\n` present, status line starts
  with `HTTP/1.`, Content-Length parsed correctly.
- [x] Zero error budget — assertion failure stops the run.

### 12. Output

- [x] Print structured results to stdout.
- [x] Include: cpu info, seed, connections, requests, seed count, batch
  delay, duration, throughput, reconnections, per-operation table, RSS,
  DB size.

### 13. Scaling analysis (behind `--analysis`)

- [x] Rule 1: write latency > 2x read latency → SQLite bottleneck.
- [x] Rule 3: p100 > 10x p99 → latency spikes.
- [x] Rule 4: reconnections > 0 → server shedding connections.
- [ ] Rule 2: throughput plateau detection (requires multiple runs).

### 14. Comptime safety

- [x] LoadOp ↔ Operation comptime assertion — every Operation must
  be in LoadOp or the explicit exclusion list. Adding an operation
  to message.zig without updating the load test is a compile error.
- [x] Format fuzzer (90,000 inputs) validates buffer bounds, HTTP
  framing, Content-Length correctness, created_id non-zero.

### 15. Server fixes discovered during implementation

- [x] `main.zig` — port=0 support via getsockname. Stdout readiness
  signal (port number) for deterministic driver startup.
- [x] `framework/server.zig` — WAL aliasing bug. `wal_record_buf` and
  `wal_scratch` pointed to the same memory, causing `@memcpy arguments
  alias` on every mutation. Added separate `wal_record_scratch` buffer.
- [x] `framework/io.zig` — listen backlog 64 → 128 to match
  max_connections.

### 16. Per-connection PRNG

- [x] Each connection's PRNG derived from parent PRNG at init time.
- [x] Operation selection and payload generation use `conn.prng`.
- [x] Deterministic per-connection workload regardless of callback
  interleaving.

### Deferred

- [ ] `--batch-delay` and `--print-batch-timings`.
- [ ] Rule 2: throughput plateau detection (requires multiple runs).

---

## Design decisions

These decisions are documented to prevent regression — each was
explored and resolved during design. They are not implementation steps.

### Why not a benchmark

The existing `zig build bench` measures per-operation nanosecond cost
in the state machine — no HTTP, no disk, no connections. That is
internal infrastructure for framework developers detecting regressions.
Framework users use `tiger-web load` to answer questions about their
app. The bench tool should not be exposed as a public CLI command.

### Why localhost

The server's ceiling does not change based on where the client is. If
the server handles 2,380 req/s on localhost, it handles 2,380 req/s
from real users — the same work either way. Network latency adds to
user-perceived latency but does not reduce server capacity. Real
traffic is lighter than a load test — users pause between requests.
The load test gives an upper bound. TigerBeetle's benchmark runs on
localhost for the same reason.

### Why mixed workload, not sequential phases

TigerBeetle runs phases sequentially (accounts, then transfers, then
queries) because their operations have strict ordering dependencies.
Web server traffic is concurrent — a GET and POST arrive on the same
tick. Mixed workload with configurable weights is the honest model.

### Why end-to-end latency includes backpressure

When the server saturates, requests queue in TCP kernel buffers. The
wait time is recorded as request latency. This is correct — it is what
the user experiences. A 200ms page load caused by server backlog is a
200ms page load. TigerBeetle measures the same way.

### Why no validation

The server always returns 200. The handle's domain status is baked into
HTML the load test cannot parse generically. The correctness boundary
lives inside the state machine. The fuzzer exercises it with typed
responses. The load test is outside that boundary. Partial checks (row
counts, headers) would give false confidence. TigerBeetle's `--validate`
works because their protocol returns typed results. Ours returns HTML.

### Why no auth

Auth adds a fixed per-request cost (HMAC-SHA256) regardless of what is
being tested. Noise without information.

### Why zero error budget

Valid data, warmed server, localhost. No reason for failure. If a
request fails, it is the finding — the server broke under load. Stop
and report.

### Why keep-alive connections

Opening a TCP connection per request measures handshake cost — noise
that real browsers avoid. The load test models real traffic: persistent
connections sending many requests.

### Why PRNG is sufficient for payloads

The bottleneck is the database. Product name content does not change
INSERT cost. Realistic access patterns (zipfian) are not needed — the
load test measures throughput ceiling, not cache behavior.

### Why tick batching matters

Under concurrent load, the server batches multiple requests per tick
into one SQLite transaction (one fsync). Throughput numbers reflect
this. It is realistic — production triggers the same batching.

### Why seed count is independent of request count

Dataset size and operation count are different questions. Small seed +
many requests = hot-path test. Large seed + few requests = cold-path
test.

### Why cooldown before measuring DB size

The server may flush WAL writes after the last response. Measuring
before full shutdown misses pending writes.

### Why the server pool size is the developer's problem

If `--connections` exceeds the pool, excess connections queue at the OS
level. High reconnection counts are the signal. The load test does not
enforce pool limits — the developer knows their configuration.

### Scaling analysis thresholds

The thresholds (2x write/read ratio, 10x p100/p99 ratio) follow from
the architecture: single-threaded, one SQLite writer lock, fsync as the
write floor. They are starting points that may be refined with
empirical data.

### Why monotonic counters (resolved during implementation)

The original design decremented `requests_sent` in error paths to
"undo" lost requests. This created underflow risk, required manual
counter management, and made invariants hard to reason about. The
correct design: counters only increment. `requests_dispatched` goes up
in `dispatch_request`. `requests_completed` goes up in
`on_response_complete`. Error recovery reconnects and goes idle —
`dispatch_all` on next tick sends a fresh request. The gap between
dispatched and completed reflects lost requests. `invariants()` after
every tick verifies the relationship.

### Why stdout readiness signal (resolved during implementation)

The original design parsed "listening on port N" from stderr logs with
a retry loop. This was fragile: `readAll` on a pipe hangs if the port
number is fewer digits than the buffer size, and the retry loop masked
a missing readiness signal. The correct design: server writes the port
to stdout after bind+listen. Driver reads stdout (blocking, returns on
first data). One mechanism, deterministic.

### Why separate WAL buffers (bug fix during implementation)

The server used `wal_scratch` for both WriteView recording and WAL
entry assembly. When `append_writes` copied the header into the same
buffer that held the writes data, `@memcpy` detected aliasing and
panicked. The fix: `wal_record_scratch` (WriteView writes here) is
separate from `wal_scratch` (WAL assembles here). Non-overlapping
sources, correct by construction.
