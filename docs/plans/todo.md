# Active plans

1. **Simulation testing** — Phase 1 DONE, Phase 2-3 pending
   Phase 1 (done): sim.zig 220 tests, SimIO fault injection, PRNG-seeded
   deterministic replay. sim_sidecar.zig: 11 sidecar + 4 concurrent tests.
   Phase 2 (pending): scanner `[sim:*]` annotations — `docs/plans/simulation-testing.md`
   Phase 3 (pending): TS sidecar sim — same plan file.

2. **Worker system** — DONE
   Full worker implementation: WAL dispatch, SHM transport, tick loop,
   scanner [worker]+[handle]+[render] chain, QUERY sub-protocol.
   See `docs/internal/decision-worker-architecture.md`.

   **Remaining items:**
   - Fire-and-forget workers: `[worker]` without `[handle]`/`[render]`.
     Framework auto-generates no-op completion (resolve pending, done).
   - TIGER_STYLE naming pass: `slot_idx` → `slot_index`, `shm_fd` →
     `shm_file_descriptor`, `buf` → `buffer`, `len` → `length` throughout
     worker files. Comment punctuation (capital, period).
   - `wal.init` is 127 lines (TB limit: 70). Split into init + recover +
     verify_root + scan_entries. Pre-existing — not worker-specific.
   - `wal.init` heap allocation (page_allocator.alignedAlloc). TB wants
     static allocation. Pre-existing.
   - Consolidate RESULT-frame builder across test files (3 copies).
   - Sidecar sim test for full worker lifecycle (handler dispatches worker
     → sidecar processes → completion fires). Currently only unit/integration
     tests exercise the worker path.

   **Completed:**
   - TS worker SHM client wired: `(ctx, db)`, QUERY frame exchange.
   - `worker.xxx(id, body)` dispatch format.
   - Fuzzer decomposed to 10 action functions, struct array.
   - Protocol spec: `docs/guide/sidecar-protocol.md`.
   - SHM discovery: slot_count + frame_max in RegionHeader.
   - prefetchKeyMap codegen (no runtime fn.toString() hack).
   - Decision doc: `docs/internal/decision-worker-query-transport.md`.

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
   Copied TB's trace.zig + surgical edits. Time vtable (TimeSim/TimeOS),
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

## Tickets

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

## Storage boundary gaps (from audit)

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

## SHM transport: unified wait — EXPLORED, RESOLVED

Busy-poll with adaptive idle is the correct primitive. Explored and
rejected alternatives:

- IORING_OP_FUTEX_WAIT: kernel 6.18 DOES support it (verified with
  liburing). But TB's batched io_uring submission model means new
  futex_wait SQEs aren't flushed within completion callbacks. Under
  sustained load, futex_wait was SLOWER than busy-poll (28K vs 45K).
  See commits 5ff1088 (WIP) and 687761f (revert).
- eventfd, SCM_RIGHTS, tick-based polling: all inferior.

Current approach: run_for_ns(0) when SHM slots are in-flight (busy-
poll at CPU speed), run_for_ns(10ms) when idle. Sidecar adaptive idle
(setImmediate → setTimeout 1ms after 1000 idle ticks). 52K req/s TS,
64K Zig sidecar, 75K native.

## Focus LSP — typed handler contexts for all languages

The correct primitive for user-space type inference. Replaces the
per-language generated declaration files approach (7.8 + 7.9).

One custom LSP serves all languages:
1. Reads `focus/manifest.json` (operations, prefetch keys, statuses)
2. Reads `schema.sql` (column names and types per table)
3. Maps filename → operation (`src/list_todos.ts` → `list_todos`)
4. Provides completions + hover for `ctx.prefetched.*` and `ctx.status`

Language-aware only for type FORMATTING (struct vs interface vs class).
Type EXTRACTION is language-independent (from manifest + schema).

Works alongside existing language LSPs (tsserver, gopls, pyright) —
VS Code supports multiple LSPs per file. The focus LSP provides only
handler-specific intelligence.

Prerequisite: extend scanner to emit type information in manifest:
```json
{
  "types": {
    "list_todos": {
      "prefetch": {
        "todos": { "mode": "queryAll", "columns": [
          {"name": "id", "type": "text"},
          {"name": "title", "type": "text"},
          {"name": "done", "type": "integer"}
        ]}
      },
      "statuses": ["ok"]
    }
  }
}
```

Engineering cost: ~1 week for basic LSP (hover + completions).
Scales to all languages with zero per-language codegen.
Replaces plan items 7.8 (typed prefetch) and 7.9 (status unions).

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

## Typed schemas — SUPERSEDED by Focus LSP

Previously: generate per-language `.d.ts` / `types.go` from schema.
Now: Focus LSP reads manifest + schema.sql and provides types inline
for all languages via a single LSP server. See "Focus LSP" section above.

## Remote auth via worker pattern

Auth strategies requiring remote validation (JWT JWKS, API key sync,
revocation lists, user/permission sync) can't resolve in the
single-threaded pipeline — no outbound HTTP client. Pattern: worker
fetches periodically, keeps local storage current, state machine
resolves per-request from local data. Already works for login codes.
Generalize when a second auth strategy is needed.

## Cross-platform gaps (from macOS port audit)

- musl Linux variants: NativePlatform has glibc only. Alpine/Docker
  containers need x86_64-linux-musl + aarch64-linux-musl. TS platform
  detection needs glibcVersionRuntime check (TB pattern). Add when a
  user reports it or Docker deployment is prioritized.
- Vendored node-api-headers unversioned: copied from /usr/include/node/
  without version tracking. TB uses node-api-headers npm package (^0.0.2).
  N-API is ABI-stable so functionally equivalent, but no audit trail.
- worker_dispatch.zig SlotHeader lacks slot_state field (shm_bus.zig has
  it). Different SHM regions, different protocols — correct but needs a
  comment explaining why the layouts differ.

## Backlog

- **Render fuzz: extend to escaping/XSS once user-controlled strings flow into HTML.**
  Trigger: first feature that interpolates seller-edited or user-submitted
  text into the render output (product descriptions, reviews, search-result
  rendering of user queries). Today render emits framework-shaped HTML
  with no user-controlled content, so the wire-format checks already in
  `render_fuzz.zig` are sufficient. When the trigger fires, add a mode
  that runs random adversarial strings (`<script>`, `"><img onerror>`,
  null bytes, unicode boundary cases) through real handler render
  functions and asserts no escape gets dropped.
- **Codec fuzz: incremental/partial-recv mode.** The HTTP parser is
  documented to handle being called repeatedly with growing input
  (`.incomplete` → call again with more bytes). `codec_fuzz` only
  exercises single-shot. Trigger: real partial-recv lands on a hot
  path, OR a recv-state bug ships. Pattern: TB's `message_buffer`
  fuzzes both shot modes — match it.
- **message_bus_fuzz: per-run corruption-class selection (TB-shape).**
  Round-8 audit (2026-04-30) landed three fixes — generator
  constrained to CRC bytes only, error rate capped at 0..1/100,
  destructive-action weights capped at 1 — and verified disabled-CRC
  detection at smoke seed 123. Catch rate at the broader seed set is
  2/9: most seeds happen to inject `inject_oversized_frame` before
  `inject_corrupt_frame`, oversized terminates the connection on the
  length check, corrupt frames queued in the byte stream never
  process. This is a fundamental property of "first-rejection
  terminates" — once any malformed frame is rejected, the connection
  is dead and no other rejection path can be exercised in the same
  run. Real fix: per-run corruption-class selection (set ONE of
  inject_corrupt_frame or inject_oversized_frame to weight 0 at init,
  PRNG-chosen). Each run tests exactly one rejection path; across
  many seeds both paths get coverage. ~10 lines. Trigger: when a
  CRC regression in the wild ships through smoke despite seed 123
  catching, OR when adding a third fault category (which would make
  the n-way race even harder).
- **Tidy CI gate.** `zig build tidy` ported 1:1 from TigerBeetle but
  has ~1000 violations across the codebase (long lines, defer
  blank-line, banned `@memcpy`, `@This()`, dead-code imports). Until
  cleared, tidy is NOT in the `tiger_unit_tests.zig` aggregator and
  CI doesn't gate on it. Cleaning it up is the deepest TB-1:1
  alignment work remaining. Full plan in
  `benchmark-tracking.md` "tidy.zig codebase cleanup → CI-gating"
  entry. Path: fix one category at a time, eventually add
  `_ = @import("tidy.zig");` to the aggregator. Then delete
  `scripts/style_check.zig` (tidy subsumes it).
- **Replay fuzz: per-op `(name, args_len)` model match.** Today
  `assert_pending_matches_model` compares ops as a set + asserts
  payload-shape sanity (every recovered entry's name == "fuzz_worker"
  and args_len ≤ 32, since phase 1 is the only writer). A stronger
  check would build a per-op map in phase 1 of `(op → name, args_len)`
  and assert each recovered entry matches its specific record. Catches
  parser bugs that swap fields between dispatches but produce
  individually-valid shapes. Defer until phase 1 ever generates
  multiple worker names — currently the constant name limits the
  per-op map to a one-line entry.
- **Codec fuzz: handler-aware JSON body generators.** Most adversarial
  inputs route to `null` (only ~5% reach a typed Message at seed 42).
  The codec's JSON-to-typed-struct step is unfuzzed under random
  input. Two TB-shaped options: extend `codec_fuzz` with body
  generators per Operation, or add per-handler fuzzers. Pick when
  the body grammar starts mattering — e.g., when a JSON parser bug
  ships, or when handler bodies grow beyond trivial shapes.
- Snap testing: `framework/stdx/testing/snaptest.zig` is ported from TB
  but unused outside its own tests. Wiring it into render output (golden
  HTML for canonical operations), the scanner manifest shape, and the
  Chrome Tracing JSON skeleton would catch accidental shape drift cheaply.
  Deferred — sim tests cover render via raw byte assertions, and the
  manifest has a freshness gate. Revisit if either layer starts producing
  noisy diffs on unrelated edits, or when adding a third generated
  artifact tips the balance.
- ensure the server is compatible with http 2/3
- Component benchmarks: HTTP parser, auth sign+verify, render encoding,
  tracer overhead, frame build/parse, sidecar e2e (µs/op). Add as
  dual-mode in bench.zig when touching those components.
- CI benchmark tracking: run `zig build bench` on merge, store JSON,
  week-over-week comparison. TB does this manually — defer until
  automated CI is set up.
- **Open-loop load generator mode.** Blocking prerequisite for any
  public performance claim off the dashboard (README, marketing,
  external comparison). The failure mode is invisible by design;
  remediation is time-boxed to "before first public claim," not
  signal-driven. The current single-threaded client loop in
  `benchmark_load.zig` (H.4 shape) is a prerequisite.
- **CI observability pipeline (single bundled follow-up).** Three
  related items land together; separating them produces a stale
  dependency chain. (1) Split devhub onto its own workflow
  triggered by `workflow_run: workflows: [CI], types: [completed]`.
  Unblocks a meaningful `ci_pipeline_duration_s` (the completed-run
  record carries `updatedAt = end-of-pipeline`). (2) Restore
  `ci_pipeline_duration_s` to `scripts/devhub.zig` with TB's exact
  shape (TB:311-332). Currently deferred in-code — see comment at
  `src/scripts/devhub.zig:68,210,258`. (3) Subscribe to GitHub
  Actions runner-image deprecation announcements; annotate the
  dashboard within 24h of any switch so the resulting discontinuity
  is explicit rather than misread as a regression. ~1.5h total.
- **`pending_index_benchmark.zig` + `ring_buffer_benchmark.zig` at
  API boundary.** Add if container-choice stabilizes and we want
  regression detection. Until then, pipeline-tier bench covers them
  implicitly.
- **Per-endpoint load shapes.** Default `--ops` mix in the SLA bench
  will need tuning as domain grows.
- **Sidecar-mode SLA bench.** `tiger-web benchmark` exercises the
  HTTP → native → SQLite path only; the 1-RT SHM sidecar dispatch
  isn't covered at SLA tier. Two shapes: `--sidecar=<cmd>` flag, or
  a second bench invocation in `scripts/devhub.zig:run_sla_benchmark`
  emitting `benchmark_sidecar_*` metrics. Add when sidecar-path
  performance becomes a dashboard story.

- design a system for deriving docs from the code, and documenting the bible, architecture, and docs separately
- TS sidecar render: effects array instead of single string
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
- Rust-style error messages for scanner/compiler output: source code front-and-center, underline the problem, suggest the fix. Reference: https://blog.rust-lang.org/2016/08/10/Shape-of-errors-to-come/ — proven adoption/retention factor, especially during the learning curve. Applies to annotation validation, SQL mismatches, status exhaustiveness, type errors.
## clean up
- ensure we use cli/program defaults very carefully. i like no defaults or few defaults over heavy defaults
- think about 10 years from now, what parts of the user space would have likely been violated? we should pull back a primitive for these.

## plugins
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

## industries capped by language speed
shopify liquid
wordpress websites
jamstack tooling

They cant serve as many req/s or load as fast as they need to due to the stuck ecosystem
