# Active plans

1. **Simulation testing** — `docs/plans/simulation-testing.md`
   User-space domain verification via `[sim:*]` annotations.
   Reference model, assert callbacks, invariants, shared predicates.
   Phase 1: bolt onto fuzz.zig (Zig-native). Phase 2: scanner.
   Phase 3: TS sidecar sim.

2. **Worker integration** — `docs/plans/worker.md` — DEFERRED
   worker.fetch in prefetch (framework resolves across ticks).
   Worker polls for post-commit work (no after_commit callbacks).

3. **Session as writes** — DEFERRED
   Remove session_action from HandleResult. Session changes via
   db.execute on a sessions table. Only logout uses session_action.

4. **Phase 4: SimSidecar** — NEXT
   Simulation primitive for sim tests with full sidecar pipeline.
   Exercises Server + SM + MessageBus + SidecarHandlers together.
   Recovery scenarios: disconnect → 503 → reconnect → 200.
   SimSidecar speaks CALL/RESULT frames via FuzzIO, controls
   when RESULTs arrive (PRNG-driven delays, failures).
   Same pattern as TB's SimStorage. Currently covered by:
   - Protocol fuzzer (sidecar_fuzz.zig — state machine level)
   - Transport fuzzer (message_bus_fuzz.zig — connection level)
   - Manual e2e (npm run dev + curl)
   - Integration test (examples/ecommerce-ts/test.ts — 67/75 pass)

5. **Non-blocking sidecar frame IO** — DONE (message bus replaced it)
   The old blocking `read_frame`/`write_frame` was replaced by
   MessageBusType(IO) with async recv/send in Phase 1. Dead code
   still in protocol.zig (read_frame/write_frame/recv_exact/send_exact)
   — blocked from deletion by old sidecar_fuzz.zig test. Can now be
   deleted since sidecar_fuzz.zig was rewritten.

6. **N+1 sidecar process manager** — DEFERRED
   Server spawns N sidecar processes. Each connects, handshakes,
   gets its own bus. Two modes:

   **Hot standby (simple, no concurrent pipeline):**
   Dispatch to sidecar A. If A dies, instantly switch to B
   (already connected). Zero downtime on crash. Same throughput
   (serial pipeline), double availability. `--sidecar-count=2`.

   **Round-robin (requires concurrent pipeline):**
   N in-flight pipelines, dispatch to whichever sidecar is free.
   Throughput scales linearly: 1 sidecar = 25K, 2 = 50K, 4 = 100K.
   Requires multiple `commit_stage` slots (network-storage.md).

   Hot standby first. Round-robin after concurrent pipeline.
   Handler code unchanged — pure functions, no shared state.

   Pieces that already exist:
   - MessageBus with tick_accept
   - READY handshake per connection (PID + version)
   - Binary state (connected/disconnected)
   - Pure function handlers

   Pieces needed:
   - `std.process.Child` to spawn/respawn sidecars (~30 lines)
   - Array of bus connections instead of single embedded bus
   - `next_sidecar_index` for round-robin dispatch
   - Concurrent pipeline for round-robin mode (separate plan)

7. **Adapter lifecycle flags** — DEFERRED
   READY handshake flags byte for runtime-specific kill semantics
   (process group kill for npx/poetry). See decision doc:
   `docs/internal/decision-sidecar-lifecycle.md`.
   Defer until second adapter (Python/Go) is added.

7. **E2e test handler failures** — 8 handler logic bugs
   update/search/dashboard rendering failures in sidecar mode.
   Not transport issues — handler TS code needs fixes.
   See: `examples/ecommerce-ts/test.ts` (67/75 pass).

8. **Delete dead protocol code** — cleanup
   `protocol.read_frame`, `write_frame`, `recv_exact`, `send_exact`
   are dead code (replaced by message bus). `io.readable()` has no
   callers. Can delete now that sidecar_fuzz.zig is rewritten.

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

## Sidecar: shared memory transport — `docs/plans/draft_sidecar-shm-transport.md`

Replace Unix socket with mmap + futex. Drop RT1 via manifest routing.
Typed schemas for type safety + perf. Phase 1: 2-RT protocol (17K).
Phase 2: shm + futex (25K). Phase 3: typed schemas (26K, +type safety).
From 25% of native to ~49%. Remaining gap is V8 compute — use Zig/Rust
if you need more.

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

# Backlog

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
- change prefetch from epoll to io_uring to 15x if a user uses a network db as the db interface postgres would go from 2k to 50k req/s
- assert the args passed to the sidecar functions are not directly mutated like ctx.something = ""

# clean up
- ensure we use cli/program defaults very carefully. i like no defaults or few defaults over heavy defaults
- think about 10 years from now, what parts of the user space would have likely been violated? we should pull back a primitive for these.



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
