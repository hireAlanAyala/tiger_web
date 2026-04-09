# Active plans

1. **Simulation testing** — `docs/plans/simulation-testing.md`
   User-space domain verification via `[sim:*]` annotations.
   Reference model, assert callbacks, invariants, shared predicates.
   Phase 1: bolt onto fuzz.zig (Zig-native). Phase 2: scanner.
   Phase 3: TS sidecar sim.

2. **Worker system** — DONE
   Full worker implementation: WAL dispatch, SHM transport, tick loop,
   scanner [worker]+[handle]+[render] chain, QUERY sub-protocol.
   See `docs/internal/decision-worker-architecture.md`.

   **Remaining items:**
   - TS worker SHM client: wire `db` parameter (QUERY frame exchange).
     Zig side handles QUERY in poll_completions. TS side needs
     `db.query()` → QUERY frame → wait for QUERY_RESULT → resolve Promise.
   - TS `worker.xxx(id, body)` dispatch: update from positional args
     to `(id, body_object)` wrapping into `ctx = { id, body }`.
   - Fire-and-forget workers: `[worker]` without `[handle]`/`[render]`.
     Framework auto-generates no-op completion (resolve pending, done).
   - TIGER_STYLE naming pass: `slot_idx` → `slot_index`, `shm_fd` →
     `shm_file_descriptor`, `buf` → `buffer`, `len` → `length` throughout
     worker files. Comment punctuation (capital, period).
   - `wal.init` is 127 lines (TB limit: 70). Split into init + recover +
     verify_root + scan_entries. Pre-existing — not worker-specific.
   - `wal.init` heap allocation (page_allocator.alignedAlloc). TB wants
     static allocation. Pre-existing.
   - Worker fuzz main is 164 lines — decompose into action functions.
   - Parallel arrays in fuzzer (`dispatched_ops` / `dispatched_request_ids`)
     — replace with struct array.
   - Three copies of RESULT-frame builder across test files — consolidate.
   - Sidecar sim test for full worker lifecycle (handler dispatches worker
     → sidecar processes → completion fires). Currently only unit/integration
     tests exercise the worker path.

3. **Session as writes** — DEFERRED
   Remove session_action from HandleResult. Session changes via
   db.execute on a sessions table. Only logout uses session_action.

4. **SimSidecar sim tests** — DONE
   11 sim tests + 4 concurrent dispatch tests in sim_sidecar.zig.
   Throughput benchmark: 2x scaling with 2 slots (32→16 ticks/req).

5. **Non-blocking sidecar frame IO** — DONE (message bus)

6. **Concurrent pipeline (Stage 3)** — DONE
   PipelineSlot, per-slot handlers, handle_lock, round-robin dispatch.
   SM pure services (no handlers, no per-request state). Per-slot tracer.
   All connections active (no standby concept). Tested + benchmarked.

12. **Tracer port (TB pattern)** — DONE
   Copied TB's trace.zig + surgical edits. Time vtable (TimeSim/TimeReal),
   7 boundary events, EventTracing (concurrent stacks), EventTiming
   (aggregate by work type), EventMetric (gauge/count). Chrome Tracing
   JSON output. Server owns tracer (not SM). cancel_slot for concurrent
   pipeline. constants.zig as single source of truth. Old tracer deleted.
   4 boundary events defined but not yet instrumented (matches TB pattern).

7. **Sidecar transport optimization** — `docs/plans/sidecar-shm-transport.md`
   Committed: Phase 3 (typed schemas), Phase 1 (RT reduction),
   Phase 1b (server-side prefetch — thin sidecar).
   Future (measure-driven): request batching, QUERY batching, shm.

8. **Batch SQLite transactions per tick** — DEFERRED
   begin_batch before first .handle in a tick, commit_batch after
   last. All writes in one tick share one SQLite transaction.
   Reduces fsyncs from N to 1 under concurrent dispatch.
   Currently each .handle does its own begin/commit_batch.

9. **Adapter lifecycle flags** — DEFERRED
   READY handshake flags byte for runtime-specific kill semantics
   (process group kill for npx/poetry). See decision doc:
   `docs/internal/decision-sidecar-lifecycle.md`.
   Defer until second adapter (Python/Go) is added.

10. **E2e test handler failures** — 8 handler logic bugs
   update/search/dashboard rendering failures in sidecar mode.
   Not transport issues — handler TS code needs fixes.
   See: `examples/ecommerce-ts/test.ts` (67/75 pass).

11. **Supervisor integration test** — real spawn/waitpid/restart cycle
   The supervisor state machine (backoff, restart) is unit tested, but
   the real spawn → waitpid → restart path is never exercised. This
   gap hid two bugs:
   - `collect_sidecar_argv` returned a slice into a stack-local buffer
     (use-after-return — the supervisor read garbage argv on respawn)
   - `page_allocator` used for `Child.spawn` dupeZ wasted 4KB per
     small string, causing OOM on the second sidecar process
   Neither bug was caught by sim tests because sim mocks the spawn.
   Fix: integration test that spawns a real trivial binary (e.g.
   `sleep 0.1`), verifies the supervisor detects exit via waitpid,
   and respawns with correct argv. Not a sim test — real processes.

12. **Runtime trace toggle** — DONE
   `tiger-web start --trace --trace-max=50mb` for startup tracing.
   `tiger-web trace --max=50mb :3000` for runtime toggle via admin socket.
   Bounded, auto-named, size limit enforced, RunState struct (no globals).
   Budget assertions in benchmark (smoke mode, ~10x actual values).

13. **Delete legacy storage methods** — cleanup, prerequisite for query cache
   All native handlers use query()/query_all()/execute(). Legacy methods
   (get/put/update/delete/list/search + per-entity variants) have zero
   external callers — only storage.zig's own tests use them. Delete:
   - 24 prepared statement fields + init + finalize (~170 lines)
   - 20 legacy methods (~500 lines)
   - 5 legacy helpers (bind_uuid, bind_ok, read_product, read_collection,
     read_order_item) (~90 lines)
   - 3 dead tests (roundtrip max u32, list filters, order insertion order)
   - 10 ReadView delegation methods (~40 lines)
   Total: ~800 lines deleted. Compiler-driven — remove fields, fix errors.
   After: storage has 3 read methods (query, query_all, query_raw) and
   1 write method (execute, execute_raw). Cache wraps these uniformly.

14. **Event-driven resume_suspended** — optimization
   resume_suspended is called unconditionally every tick. TB calls
   resume_receive only when a resource frees (journal slot, repair slot).
   We should call resume_suspended only when a pipeline slot frees
   (from pipeline_reset) instead of every tick. At 128 connections
   with 0-2 suspended, the scan is trivial — defer until connection
   count grows.

15. **MessagePool for >128 connection scaling** — future
   Each connection embeds 270KB (8KB recv + 256KB send). 512
   connections = 135MB, exceeding L3 cache. TB's message_pool.zig
   (343 lines, isolated from consensus) provides shared buffer pools.
   Copy via `cp` when >128 connections is needed. Connections would
   hold pool buffer pointers instead of embedded arrays.

16. **Extract admin socket from main.zig** — cleanup (trigger: second admin command)
   AdminSocket struct + trace toggle logic inline in main.zig.
   Fine for one command. Extract when a second admin command is added.

14. **Delete dead protocol code** — DONE
   Protocol frame functions already deleted in prior session.
   `io.readable()`, async `accept()`, and SimIO/TestIO equivalents
   deleted. Op enums cleaned up across IO, SimIO, TestIO.

---

# Tickets

## 1: JSON parser rejects whitespace around colons

`{"name" : "Widget"}` silently fails. Today only Datastar's
JSON.stringify() produces JSON (compact), so doesn't fire.

Fix: skip optional spaces before and after `:` in all extractors.

## 2: JSON string parser truncates escaped quotes

`"name":"Widget \"Pro\""` parses as `Widget \`.

Fix: walk byte-by-byte, skip `\"` when looking for closing quote.

## 3: Price parsing bug

Sent `"price_cents":999` but response shows `price_cents:9`.
Possible Datastar serializer nesting or Content-Length truncation.

## Observability translator — document the split, not build the tool

The framework already emits all the data a user needs. Three primitives,
three time horizons, three output formats:

| Primitive | Source | Horizon | Format | Answers |
|-----------|--------|---------|--------|---------|
| Metric logs | `tracer.emit_metrics()` → stderr | Live / last N min | Structured text, periodic (~100s) | Rate, errors, health |
| Trace JSON | `--trace=trace.json` | Debugging session | Chrome Tracing JSON (Perfetto) | Per-request stage breakdown |
| WAL | `wal.append_writes()` → `.wal` file | All time | Binary, replay via `replay.zig` | Audit, recovery, replay |

**What each metric covers:**
- `requests_by_operation` (count): which operations are hot
- `requests_by_status` (count): what's failing and why
- `pipeline_stage` timing (min/max/avg/count): per-stage latency (route/prefetch/handle/render)
- `connections_*` gauges: server health

**The gap:** timing is per-stage, not per-operation. "Prefetch averages
200us" but not "create_product prefetch vs list_products prefetch."
Per-operation × per-stage timing would need 5 × N slots (multiplicative).
Instead: periodic metrics answer "what's slow" (which stage), trace.json
answers "where exactly" (which operation × which stage). Two tools,
two granularities.

**What the user does:** pipe stderr metric lines to their monitoring
(Prometheus, DataDog, Grafana). Each emit window = one data point.
count ÷ window = rate. Compare windows = trends. When something looks
off, enable `--trace`, open Perfetto, find the specific operation.

**Framework's job:** emit correct, structured, bounded data. Not build
a dashboard. Document the output format so translators are trivial.

---

# Storage boundary gaps (from audit)

High priority:
- Assert bind parameter count matches SQL placeholders (1 line)
- Assert bind return codes `rc == SQLITE_OK` (~10 lines)

Medium priority:
- Assert column names match struct field names on first row (~15 lines)

Low priority:
- Retry cap on busy (storage can retry forever)
- query/query_all error discrimination (interface change)
- query_all truncation detection (documentation or comptime)
- Write failure model: panics (TB) vs returned errors (web) — decide

## WAL filename derived from database path

The application-level WAL filename is hardcoded to `tiger_web.wal`.
Every server instance (dev, load test, perf script) writes to the same
file, corrupting each other's replay chain.

Fix: derive from `--db` path. `--db=tiger_web.db` → `tiger_web.db.wal`.
Same convention as SQLite's own WAL (`tiger_web.db-wal`). The WAL
file lives next to the database, obvious pairing, no conflicts.

Change in `main.zig`: replace `"tiger_web.wal"` with
`db_path ++ ".wal"`. Load test and perf script cleanup already
delete the db file — the paired WAL deletes with it.

## SHM transport: unified wait (explore, not urgent)

HTTP recv/send now uses io_uring (TB's linux.zig). SHM signaling
still uses busy-poll with adaptive sleep. This is correct — the
SHM check is a single atomic load in userspace, no syscall. io_uring
can't make a memory read faster. Under load the poll always finds
work; when idle the adaptive threshold sleeps.

Explored approaches and findings:
- IORING_OP_FUTEX_WAIT: not supported on all kernels (probe shows
  flags=0x0). futex2 syscalls (454-456) also return EINVAL.
- eventfd via io_uring READ: works intra-process, but eventfd is
  per-process — can't write to it from the sidecar without fd passing.
- SCM_RIGHTS fd passing: correct but adds protocol complexity to the
  READY handshake for marginal gain (SHM poll is already ~3µs).
- Tick-based polling (1ms): 6K req/s vs 87K busy-poll. Too slow.

Conclusion: busy-poll is the right primitive for cross-process SHM
signaling at our scale. The only real issue is 100% idle CPU, which
the adaptive threshold already mitigates. If 1-core starvation
becomes a production issue, lower the threshold or use cgroups.

Future: if IORING_OP_FUTEX_WAIT becomes universally available, it
would be the clean solution (one ring waits for everything). Monitor
kernel support.

## Status-to-HTTP-code mapping — handler returns domain status, framework owns the code

Handlers return a domain status string (`"ok"`, `"not_found"`, `"version_conflict"`).
The framework maps it to an HTTP status code. The handler author never thinks in codes.

The invariant: if handle returns `"ok"`, the response is 200. Everything else is a
non-200 derived from the status. The mapping is a compile-time table — exhaustive,
scanner-enforced, no missing cases.

```
ok                     → 200
not_found              → 404
version_conflict       → 409
insufficient_inventory → 409
order_expired          → 410
invalid_code           → 422
code_expired           → 422
storage_error          → 500
```

Two audiences, two channels, one return value:
- **Transport status** (is the server working?) — for load balancers, monitoring, retry
  logic. Derived automatically. The handler author doesn't think about it.
- **Domain status** (what happened?) — for the application. A bounded enum, scanner-enforced
  exhaustive, compile-time known. The handler author only thinks about this.

For HTML: status code is informational, page renders the domain status visually.
For JSON: `{"status": "version_conflict", "data": {...}}` + HTTP 409. Client switches
on `status` field, not the code. The code is for infrastructure.

This replaces the always-200 model for API responses while keeping the handler interface
unchanged. Same handler serves HTML and JSON — the framework picks the encoding.

Right primitive: the developer states what happened, the framework handles the protocol.

## Native read-only fast path (0-RT) — skip sidecar for trivial operations

For get/list operations where the Zig handler can render HTML directly,
skip the SHM round trip entirely. Saves ~5µs IPC cost per request.
get_product would go from 98K to ~160K (native Zig is 80K without
sidecar overhead). Requires: Zig-native render templates for handlers
that opt in. The native handlers already exist — just need to wire them
into the 1-RT dispatch as a "0-RT" path when the operation has a native
renderer.

## Typed schemas — type-safe TS interfaces from SQL schema

Generate TypeScript interfaces from the SQLite schema so
`ctx.prefetched.product` has typed fields instead of `any`. The
annotation scanner already knows column names from the SQL. Emit
`.d.ts` files with `{ id: string; name: string; price_cents: number; ... }`.
Correctness fix (catch typos at build time), not perf.

## Remote auth via worker pattern

Auth strategies requiring remote validation (JWT JWKS, API key sync,
revocation lists, user/permission sync) can't resolve in the
single-threaded pipeline — no outbound HTTP client. Pattern: worker
fetches periodically, keeps local storage current, state machine
resolves per-request from local data. Already works for login codes.
Generalize when a second auth strategy is needed.

# current
look in the project for illegal posix and other syscalls that are not simulation friendly

# Backlog

- ensure the srver is compatble with http 2/3
- Component benchmarks: HTTP parser, auth sign+verify, render encoding,
  tracer overhead, frame build/parse, sidecar e2e (µs/op). Add as
  dual-mode in bench.zig when touching those components.
- CI benchmark tracking: run `zig build bench` on merge, store JSON,
  week-over-week comparison. TB does this manually — defer until
  automated CI is set up.

- design a system for deriving docs from the code, and documenting the bible, architecture, and docs separately
- TS sidecar render: effects array instead of single string
- Cross-platform support (currently Linux only, epoll)
- CI: run test-adapter, integration tests against /examples
- Login code delivery via worker (not server logging)
- Storage retry cap on busy
- SDK: assert no panic in prod
- Plugin API for adapters + packaged addons
- SSE fan-out to all users on a page
- Compiler/runtime output file for AI consumption
- WAL: track prod vs local origin
- CLI scaffolding (`tiger init`, `tiger add operation`)
- Marketing: fuzz test counter in repo, open-source counter program, coverage CLI with branching
- rotate github pad code, we leaked it in claude
- figure out a webscraping + html assertion flow
- figure out how to ingest large payloads from post like images etc, without passing the heavy data through the tick and passing a reference instead (local object storage, but auto hidden frm user)
- add a way to inspect the start/stop time for all annotations/features and read trends so you can see when things are getting slow.
- some things are tested against /examples for regression/performance we might want to isolate some of these tests into more user space agnostic code to protect them from example churn
- worst case json allocation in message should probably be configurable in case a framework user needs to up the value
- is ci/cd tracking benchmarks/loadtest/perf?
- annotation settings should start with @ so they're obvious special syntax
- ensure all errors absorbed by the framework like, db, network, worker, etc. are logged correctly for debugging.
- change prefetch from epoll to io_uring to 15x if a user uses a network db as the db interface postgres would go from 2k to 50k req/s (copy linux.zig from og tb, it has everything cleanly isolated)
- assert the args passed to the sidecar functions are not directly mutated like ctx.something = ""
- if storage is a network db, commit will probably need to be async, right now it blocks

# clean up
- ensure we use cli/program defaults very carefully. i like no defaults or few defaults over heavy defaults
- think about 10 years from now, what parts of the user space would have likely been violated? we should pull back a primitive for these.

# plugins
potential pulled at runtime? or compiled with the server's binary?
should they not allocate after init?
I think for sure zig only as the language
Should they pin their zig version and then be packaged as a binary of handles? so we can communicate to it isolated through binary?
render should be vanilla html and js only
plugins should copy into your binary, so you can inspect nad debug them



Theres a pattern of annotations needing settings
[worker]
interval 5s
timeout 3m
it's probably best to collapse this to
[worker]
settings: interval 5s, timeout 3m, etc..
====
So we can enforce settings sitting directly under the annotation and we can keep the space between annotation and function super tight


Questions:
what would happen if the server crashed? what are our avenues of recovery? how do they compare to hot cloud trends for high availability
Explore open source repos and see if they use ai


Try a table sync pattern:
microservices should have a local table of the data, write to it, and from from it.
where theres a background job that syncs changes to the real service
Claude said:
  The irony: the "microservice architecture done right" looks like a monolith with async workers. Which is what Tiger is. The industry spent a decade distributing systems that should have    
  stayed on one machine, then spent another decade building tools to cope with the distribution. Tiger skips both decades.                                                                     

# industries capped by language speed
shopify liquid
wordpress websites
jamstack tooling

They cant serve as many req/s or load as fast as they need to due to the stuck ecosystem
