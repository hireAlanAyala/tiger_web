# Tiger Web

Ecommerce HTTP server built in Zig, following TigerBeetle conventions.

**Philosophy:** Build the foundation correctly, then ship confidently. Every layer trusts the one below it because every layer was built to be trusted. Infrastructure isn't overhead — it's the product. Assertions, comptime checks, and round-trip tests are guarantees that compound. Cut corners in the foundation and every layer above inherits the doubt.

When faced with decisions always take the most correct approach never the simplest approach. We are shooting for safety and reliability.

**Porting from TigerBeetle — cp first, trim second.** When adopting any TB primitive or module (trace, time, bench, constants, checksum, scripts), the default is: `cp` the TB file in its entirety, then each deletion or change from the original is a conscious decision that has to be justified. Do **not** write a new version "in the style of" TB's and later realign — that's the anti-pattern this rule exists to prevent.

The cost of writing fresh isn't visible at port time. It shows up later, quietly: TB makes specific decisions we don't recognize as load-bearing, we skip them, then pay for the loss months later when the missing decision would have helped. Concrete example: `framework/bench.zig` was written "in the style of" `src/testing/bench.zig` and swapped `TimeOS` + `stdx.Duration` for raw `std.time.Timer`. TB's choice presumably encoded something (monotonic-clock handling, determinism, type-safety invariant) — we don't currently feel the loss, but we also never paid the cost of understanding it. Writing fresh means we accumulate silent drift.

The discipline:

- Start from TB's file in its entirety
- Every deletion requires a named justification falling into one of three buckets:
  - **Principled** — TB's answer doesn't fit our domain (e.g., VSR client loop → HTTP client loop)
  - **Flaw fix** — TB has a known weakness we can cheaply improve (e.g., adding `assert_budget` where TB prints without enforcement)
  - **Tracked follow-up** — temporary state with a known end condition
- Every deletion that *can't* be justified reverts to TB's code
- Every surgical addition (new function, new field) gets a comment explaining why it's ours and not TB's

The "80% survival" heuristic is a *signal* that trimming is heavy, not a license to write fresh. If trimming would drop more than 80%, that's usually a sign the port is going in the wrong direction — TB's file is shaped for a concern that doesn't apply — and a fresh file is legitimate. But the default is still to start from the cp and ask "what exactly are we keeping vs trimming" before reaching for a fresh buffer.

From-scratch ports accumulate subtle deviations (wrong field order, missing self-tracing, hardcoded values instead of constants, private vs pub). Each deviation is small, but they compound. Surgical edits on the real file produce an auditable diff where every change from TB's original is intentional and documented. Reference repo: `/home/walker/Documents/personal/tigerbeetle`

## Working Habits — Lessons From Past Mistakes

Rules distilled from concrete incidents. Each one cost hours or a commit to revert. Re-read before starting work in the relevant domain.

- **Never rewrite constant tables from memory — generate, then self-test.** Hand-typed CRC/lookup tables get corrupted byte-by-byte and the bug surfaces at runtime under real traffic. Compute the table in code at init and assert a known-good checksum of it, or `comptime`-generate and assert against a fixture. A self-test on the table is non-negotiable.

- **Prebuilt artifacts drift — CI must rebuild from source.** If the repo ships a compiled artifact (native addons, WASM, codegen output) and its source can change, rebuild it every CI run. A stale addon that silently drops responses (→ 503) hides until production load. An integration test that exercises the artifact is the backstop.

- **Bisect before rearchitecting a performance regression.** When throughput drops, `git bisect` or `git log -p` the suspect subsystem and find the commit that regressed it — *before* designing a new mechanism. A regression from a 4-line tick-loop edit is not a reason to add io_uring FUTEX_WAIT. The simplest explanation is almost always a recent unrelated change.

- **For new platforms, diagnose comprehensively in one commit — not iteratively.** Do not push single-flag diagnostic commits (`errno`, `--log-debug`, `O_RDWR` vs `O_RDONLY`) one at a time against CI. In one commit collect: errno at every syscall, environment dump, flag matrix, strace-equivalent, and the timeline of events. One-by-one guessing on CI wastes the feedback loop and pollutes history with 10 diagnostic commits that all get reverted.

- **Don't delete plan files without checking every phase.** "Phase 1 done" ≠ "plan done." Before `rm docs/plans/*.md`, grep for `- [ ]` or Phase markers in the file. Deferred phases are work — deleting the plan loses the roadmap. If a phase was intentionally dropped, move it to `todo.md` with justification.

- **Audit in one deep pass, not in rounds.** If doing a TB/safety audit, produce the full checklist up front — TB's six principles, assertion anatomy, bounded loops, pair assertions, boundary vs inner trust, mark coverage. Walk every file once against the full criteria. Commit messages like "second audit", "deeper audit", "final audit", "remaining audit items" indicate the first pass had no structure — and each round re-reads the same code.

- **Don't ship known-throwaway code.** If a commit message contains "to be replaced by" or "placeholder until", don't commit it — wait for the real implementation in the same session. Shell scripts, Dockerfiles, or CLIs shipped knowing they'll be deleted in hours are pure churn and confuse history.

- **Check memory/ before acting in a domain with prior guidance.** The `memory/` directory holds lessons from previous sessions. If you're about to delete plans, write a CRC table, diagnose CI, or trigger anything in `memory/MEMORY.md`, re-read the relevant entry first. Repeating a mistake that's already documented is worse than making a new one.

## Design Principles (from TigerBeetle)

TB's design goals, in order: **Safety > Performance > Developer Experience.**

These six principles are the decision framework for every design
choice. When evaluating options, check all six. If an option violates
any principle, it needs a strong justification or it's rejected.

| Principle | TB's words | What it means in practice |
|---|---|---|
| **Safety** | "It is far better to stop operating than to continue operating in an incorrect state." | Crash, don't corrupt. Assertions over error handling. The system must be provably correct, not hopefully correct. |
| **Determinism** | "Same input, same output, same physical path. Supercharges randomized testing." | Any test failure reproducible by seed. No timing-dependent behavior. No kernel-managed non-determinism in the hot path. If sim tests can't exercise it deterministically, redesign it. |
| **Boundedness** | "Put a limit on everything. All loops, all queues must have fixed upper bounds." | Static allocation. Comptime-known sizes. No unbounded waits, no unbounded queues, no dependencies on external timing. If it doesn't have a limit, it's a bug. |
| **Fuzzable** | "Assertions are a force multiplier for discovering bugs by fuzzing." | Every code path reachable by PRNG-driven tests. If adding an option doubles the state space for marginal gain, reject it. Fewer paths tested thoroughly beats more paths tested shallowly. |
| **Right primitive** | "Zero technical debt. Simplicity is the hardest revision." | Use the actual primitive, not an abstraction over it. Don't wrap futex in eventfd. Don't wrap `extern struct` in self-describing wire format. Don't send a network request for data you already have. The simplest correct implementation is usually the primitive itself. |
| **Explicit** | "Be explicit. Minimize dependence on the compiler to do the right thing for you. Always motivate, always say why." | Typed layouts over dynamic discovery. Known schemas encoded in structs, not rediscovered at runtime. Code should state what it does — `futex_wake(&addr)` not an abstraction that hides the mechanism. |

### Applying the principles

When choosing between options:
1. Check each option against all six principles
2. If an option fails one, document why and what it costs
3. If two options both pass, prefer the one with fewer moving parts
4. Never trade safety or determinism for performance — TB's priority order is explicit
5. "The best time to solve performance is in the design phase" — design for performance by choosing the right primitive, not by optimizing the wrong one

## Quick Reference

```bash
sh zig/download.sh          # one-time: download Zig 0.14.1
npm install                 # one-time: install TS dependencies

# --- Sidecar development (TypeScript handlers) ---
cd examples/ecommerce-ts && npm install  # one-time: install example dependencies
npm run build               # codegen + scan annotations + generate dispatch
npm run dev                 # start sidecar + server on port 3000

# --- Runtime commands (tiger-web binary) ---
#
# start — run the server
./zig/zig build run -- start                                # default port 3000
./zig/zig build run -- start --log-debug                    # enable debug log output
./zig/zig build run -- start --trace --trace-max=50mb       # startup tracing (bounded)
#
# trace — attach to a running server, capture a Chrome Tracing file
./zig/zig build run -- trace --max=50mb :3000               # toggle tracing via admin socket

# --- Development commands (zig build targets) ---
#
# test — prove the code is correct
./zig/zig build unit-test    # unit tests (message, state_machine, http, marks, codec)
./zig/zig build test         # simulation tests (27 full-stack scenarios + PRNG fuzz, seeded)
./zig/zig build fuzz -- state_machine              # random seed
./zig/zig build fuzz -- state_machine 12345        # specific seed
./zig/zig build fuzz -- --events-max=1000 state_machine  # with options
./zig/zig build fuzz -- smoke                      # all fuzzers, small event counts
#
# scan — validate handler annotations against the database schema
./zig/zig build scan -- examples/ecommerce-ts/handlers/  # validate annotations
#
# bench — measure how fast the internals are (per-operation µs/op, budget assertions)
./zig/zig build bench           # state machine benchmark (real measurements)
#
# benchmark — measure HTTP throughput + latency (SLA tier) [phase D of benchmark-tracking]
# ./zig-out/bin/tiger-web benchmark --port=3000 --connections=128 --requests=100000
# (subcommand not yet implemented; tracked in docs/plans/benchmark-tracking.md phase D)

# --- Profiling (requires `perf` — sudo pacman -S perf) ---
# Note: `tiger-web benchmark` (phase D) will replace the load driver this used.
./zig/zig build -Doptimize=ReleaseSafe       # build with symbols
zig-out/bin/tiger-web start --port=0 --db=bench.db >port.txt 2>/dev/null &
perf record -g --call-graph dwarf -p $! -o perf.data &
# (load generator invocation to be added here once phase D ships `tiger-web benchmark`)
kill %2; kill %1                             # stop perf, stop server
perf report -i perf.data --stdio --no-children -g none -s dso,symbol --percent-limit=0.5
```

**Benchmarking safety:** Always verify zero orphaned processes before
AND after each benchmark run. `npx tsx` spawns process trees that
survive `pkill`. Use: `ps aux | grep -E "tiger-web|call_runtime" | grep -v grep | wc -l`
and kill by PID if non-zero. Orphaned processes inflate throughput
measurements by up to 8×. The supervisor uses process groups
(`pgid=0`) to kill entire trees on shutdown.

## Documentation Structure

Three directories, two audiences:

| Directory | Audience | What goes here | Lifespan |
|---|---|---|---|
| `docs/internal/` | Framework developers | Architecture, decisions, findings, checklists, TB patterns. Everything needed to understand, maintain, and improve the framework itself. Decisions prefixed with `decision-`. | Permanent |
| `docs/guide/` | Framework users | How to build apps on the framework. Recipes, patterns, tutorials. Written from the user's perspective, not the implementor's. | Permanent |
| `docs/plans/` | Framework developers | What we're going to build. Checklists, design proposals, roadmap. **Deleted after implementation.** | Temporary |

**Rule:** If you learned it or decided it, put it in `internal/`. If it teaches a user how to do something, put it in `guide/`. If it's work to be done, put it in `plans/`. Plans are disposable. Knowledge is not.

## Architecture

Single-threaded event loop using epoll. No allocations after startup. Request pipeline with prefetch/execute split:

```
http.zig → codec.zig → message.zig → state_machine.zig → storage
(parse HTTP)  (route + JSON → typed)  (types)  (prefetch + execute)  (SQLite or in-memory)
                                                     ↓
                                                render.zig
                                          (HTML page or SSE fragments)
```

With `--sidecar`, the TypeScript sidecar handles routing and rendering:
```
http.zig → sidecar (route) → state_machine.zig → sidecar (handle + render)
                                (prefetch + native commit)
```

The sidecar communicates over a unix socket using a binary protocol.
Native commit handles storage, auth, WAL. Sidecar provides HTML.

### Sidecar files

| File | Role |
|---|---|
| `annotation_scanner.zig` | Scans annotations, validates status exhaustiveness + SQL read/write |
| `sidecar.zig` | Unix socket client — 3-RT binary protocol exchange |
| `protocol.zig` | Self-describing binary row format, frame IO, type tags |
| `adapters/typescript.ts` | Reads manifest, generates handler dispatch + workerFunctions |
| `adapters/call_runtime_shm.ts` | SHM sidecar runtime — 1-RT/2-RT dispatch, worker proxy, worker SHM client |
| `generated/types.generated.ts` | Hand-written TS SDK (handler types + enum mappings) |
| `generated/serde.ts` | Hand-written TS binary row reader + param writer |
| `examples/ecommerce-ts/handlers/*.ts` | Developer's annotated handler functions |

### Framework (`framework/`) — domain-free, parameterized on App

No framework file imports from the app root except via comptime generics (e.g. `ServerType(App, IO, Storage)`) or `../trace.zig` (trace references domain types — same as TB's `trace/event.zig` importing from `tigerbeetle.zig`).

| File | Role |
|---|---|
| `framework/server.zig` | `ServerType(App, IO, Storage)` — tick loop, connection pool, accepts, prefetch→execute orchestration |
| `framework/connection.zig` | `ConnectionType(IO, FollowupState)` — per-connection state machine (accepting → receiving → ready → sending) |
| `framework/http.zig` | HTTP/1.0+1.1 request parser (pure parser, no response encoding — see decisions/always-200.md) |
| `framework/io.zig` | epoll IO layer (real syscalls), `try_accept` for synchronous non-blocking accept |
| `framework/wal.zig` | `WalType(Operation)` — SQL-write WAL + worker dispatch queue, completion/dead entries, pending index recovery |
| `framework/wire.zig` | CALL/RESULT binary frame primitives — shared between ShmBus and WorkerDispatch |
| `framework/worker_dispatch.zig` | `WorkerDispatchType(max_entries)` — concurrent CALL/RESULT over separate SHM region for workers |
| `framework/pending_dispatch.zig` | `PendingIndexType(max)` — in-memory pending dispatch index, rebuilt from WAL on recovery |
| `framework/message_bus.zig` | `MessageBusType(IO, options)` — sidecar Unix socket transport, connection pool, direct `accept()` per tick |
| `framework/auth.zig` | Cookie signing/verification (HMAC-SHA256), session management |
| `framework/marks.zig` | Coverage marks — links log sites to test assertions |
| `framework/stdx.zig` | Ported from TB's stdx — `no_padding`, `equal_bytes`, `maybe`, `format_u32`, `parse_uuid` |
| `framework/checksum.zig` | Aegis128L checksum — zero-key MAC, matches TB's vsr/checksum.zig |
| `framework/prng.zig` | Xoshiro256++ PRNG with Ratio, Combination, Reservoir — matches TigerBeetle's stdx.PRNG |
| `framework/time.zig` | Wall-clock time (real + simulated) |
| `framework/constants.zig` | Cross-module constants — pipeline_slots_max, max_connections, frame limits, timeouts |
| `framework/flags.zig` | CLI argument parser — struct-driven `--key=value` parsing, ported from TigerBeetle's stdx/flags.zig |
| `framework/bench.zig` | Micro benchmarking harness — smoke/benchmark dual mode, matches TB's testing/bench.zig |

### Application (root) — domain types, handlers, templates

The root-level ecommerce app is the **native Zig reference implementation**. `handlers/*.zig` is its handler set, scanned into `generated/manifest.json` + `generated/routes.generated.zig` by the canonical CI scan. It doubles as the reference for benchmarks and simulation tests.

`examples/ecommerce-ts/handlers/*.ts` is a **parallel implementation of the same domain** over the TypeScript sidecar, used to exercise the 1-RT/2-RT SHM dispatch path. It scans via `focus build` into its own `focus/` directory — it does not touch `generated/`.

Both handler sets implement the same operations and render the same HTML shapes. Keep them in sync when adding operations.

| File | Role |
|---|---|
| `app.zig` | App binding — wires domain modules to the framework's comptime interface |
| `main.zig` | Entry point, GPA for init, CLI subcommands (start/trace), RunState event loop, admin socket, runtime log level filtering |
| `trace.zig` | Trace engine — start/stop/cancel spans, gauge/count metrics, Chrome Tracing JSON output. Copied from TB's `src/trace.zig` with surgical edits |
| `trace_event.zig` | Trace event definitions — 7 boundary events, EventTracing (concurrent stacks), EventTiming (aggregate), EventMetric (per-operation/per-status). Imports domain types (Operation, Status) directly, same as TB's `trace/event.zig` |
| `message.zig` | Types: Product, ProductCollection, flat Operation enum with EventType, Message (extern struct, WAL-writable), MessageResponse |
| `codec.zig` | Route parsing, JSON request → typed struct translation, UUID parsing |
| `render.zig` | HTML + SSE response renderer — always 200, body-first with Content-Length backfill (keep-alive), SSE from offset 0 (Connection: close), Set-Cookie for new visitors |
| `state_machine.zig` | `StateMachineType(Storage, Handlers)` — prefetch/commit pipeline, HandleResult, transaction boundaries |
| `storage.zig` | `SqliteStorage` — SQLite backend with ReadView (prefetch) and WriteView (handle), prepared statements, WAL mode |
| `sql.zig` | Shared SQL constants — single source of truth for write statements (INSERT/UPDATE per table) |
| `sim.zig` | Simulation tests (addTest) — `SimIO` + `SqliteStorage(:memory:)` with PRNG-driven fault injection, seeded via `from_seed_testing()` |
| `fuzz_tests.zig` | Fuzz test dispatcher — single binary routing to all fuzzers, matches TB's fuzz_tests.zig |
| `fuzz_lib.zig` | Shared fuzz utilities — `FuzzArgs` struct, `random_enum_weights`, matches TB's testing/fuzz.zig |
| `fuzz.zig` | State machine fuzzer — bypasses HTTP, calls prefetch/commit directly |
| `codec_fuzz.zig` | Codec fuzzer — throws random methods/paths/JSON at codec.translate |
| `render_fuzz.zig` | Render fuzzer — random operations/results through encode_response, asserts framing and keep-alive invariants |
| `auditor.zig` | Auditor oracle — independent reference model that validates state machine responses (TB pattern) |
| `storage_fuzz.zig` | Storage equivalence fuzzer — runs SqliteStorage(:memory:) vs Auditor, asserts agreement |
| `replay.zig` | WAL replay tool — verify, inspect, query, replay operations |
| `replay_fuzz.zig` | Replay round-trip fuzzer — WAL serialization boundary verification |
| `state_machine_benchmark.zig` | State machine benchmark — per-operation prefetch/commit throughput, regression detector |
| `worker_dispatch_fuzz.zig` | Worker dispatch boundary fuzzer — malformed RESULTs, bad CRC, wrong request_ids |
| `sidecar_dispatch.zig` | `SidecarDispatchType(Bus)` — SHM 1-RT/2-RT pipeline, parse RESULT, stage machine |
| `sim_sidecar.zig` | Sidecar simulation — builds CALL/RESULT frames in Zig for sim tests |
| `wal_test.zig` | WAL integration tests — instantiates WalType with domain types |

## Conventions

Follow TigerBeetle style. Reference repo: `/home/walker/Documents/personal/tigerbeetle`

- **Assertions over error handling** — use `assert` for invariants, not `if/else` error paths
- **No allocations in hot paths** — all buffers are fixed-size, allocated at init
- **GPA for init, page_allocator only for thread-safe contexts** — `page_allocator` wastes 4KB per small alloc (`dupeZ` on "node" = full page). Use `GeneralPurposeAllocator` for all init-time allocations (Server, Tracer, Supervisor, wire_sidecar). `page_allocator` is only correct when thread safety is required and alloc sizes are page-aligned. One GPA in `main.zig`, passed to everything that allocates at startup
- **No `std.fmt` in hot paths** — use hand-rolled formatters (see `format_u32`, `crc32_hex`)
- **IO callbacks only update state** — they never call into the application; the server tick drives transitions
- **PRNG-driven fuzz tests** — use `splitmix64`, not `std.testing.fuzz`; deterministic seeds for reproducibility
- **Sim tests exercise the full stack** — `sim.zig` uses `SimIO` to inject faults (partial sends, disconnects) through the real connection/server code
- **`comptime` over runtime** — prefer compile-time computation where possible
- **Flat module structure** — no subdirectories, each `.zig` file is a self-contained module

## Assertion Anatomy (TigerBeetle Style)

Three primitives:
- **`assert()`** — programming invariant; if this fails, our code has a bug
- **`@panic(msg)`** — unrecoverable corruption; crash immediately (checksum failures, data corruption)
- **`unreachable`** — code path the type system or control flow guarantees is dead (exhaustive switches, infallible syscalls)

`maybe()` is the dual of `assert`: documents that a condition is non-deterministic (sometimes true, sometimes false) and that's fine. Pure documentation, compiles to a tautology.

### Assertion Placement — Validate at the Boundary, Trust Inside

Three layers, each with a different trust model:

1. **Boundary (public entry)** — assert/validate all inputs. This is the gate. `execute()` asserts `key.len > 0`, `value.len <= value_max`, `prefetched.slot < capacity`.
2. **Inner (private)** — trust the boundary. Only assert **stored data integrity** from a different code path (pair assertions that catch corruption). `execute_get` asserts `entry.key_len > 0` because that checks data written by `execute_put`, not the input it just received.
3. **IO layer** — pure mechanics. No input validation. Trusts the caller owns the fd/buffer. Asserts only completion lifecycle (`operation == .none` before submit).

**Never re-check what the caller or callee just proved.** If `encode_response` asserts `buf.len >= send_buf_max`, the caller doesn't re-assert `send_len <= send_buf.len`. If `execute()` proved `value.len > 0`, `execute_put` doesn't re-assert `entry.value_len > 0` after writing it.

**Pair assertions are the exception** — they check the same property from a *different data path*. `on_accept` asserts `fd > 0` (where fds are born), `close_dead` asserts `fd > 0` (where fds die). `execute_put` writes entries, `execute_get` asserts they're valid. These catch corruption that flows between code paths.

### Practices

- **2+ assertions per function** on average
- **Split compound assertions** — `assert(a); assert(b);` not `assert(a and b);`
- **Assert both positive and negative space** — what should hold AND what shouldn't
- **Single-line implication assertions** — `if (a) assert(b);`
- **Pair assertions** — enforce the same property from two different code paths
- **`comptime { assert(...) }` blocks** for config/constant validation
- **`defer self.invariants()`** in tick loops to cross-check structural invariants after every tick
- **IO callbacks assert expected state** before updating it

## Logging (TigerBeetle Style)

Use `std.log.scoped(.module_name)` per file. Log at **boundaries** (init, shutdown, state transitions, errors), never in hot paths. If a hot path needs visibility, batch and aggregate — log the count after the loop.

Format: `"{}: context: message"` — prefix with an identifier, then function name, then human-readable detail. Free-form strings, not structured key=value.

Levels: ~70% debug (invisible by default), ~20% warn (recoverable operational issues), ~5% info (state transitions), ~5% err (unrecoverable). Compiled at `.debug` so nothing is stripped; filtered at runtime via `log_level_runtime` + custom `logFn` in `main.zig` (TB pattern). `--log-debug` enables debug output, `--log-trace` enables per-request trace logs (requires `--log-debug`).

**Assertions and logs never overlap.** If something is wrong enough to assert, crash — don't log. If it's expected-but-noteworthy, log — don't assert.

**Marks** (`marks.wrap_log`) link production code paths to tests. `log.mark.warn("message", ...)` records a hit; tests call `marks.check("message")` then `mark.expect_hit()`. Compiled away in non-test builds. See Marks section below.

### Scopes

| File | Scope | Notes |
|------|-------|-------|
| `main.zig` | `.main` | Startup, shutdown, signal handling |
| `server.zig` | `.server` | Accept/close/timeout lifecycle |
| `connection.zig` | `.connection` | State transitions, errors |
| `io.zig` | `.io` | Listener bind, epoll errors |
| `tracer.zig` | `.tracer` | Gauges, counters, timing metrics, per-request trace logs |
| `state_machine.zig` | `.state_machine` | Storage fault marks |
| `storage.zig` | `.storage` | SQLite init/errors |
| `http.zig` | — | No logging (pure parser, no side effects) |
| `message.zig` | — | No logging (types only) |
| `marks.zig` | — | No logging (test infrastructure) |
| `sim.zig` | — | No logging (test infrastructure, log_level set to .err) |

### Where to log

**`main.zig`** — `log.info` / `log.err`:
- Server config and listen port (startup)
- Log level and trace flag when `--log-debug` active (startup)
- `--log-trace` without `--log-debug` (err, then exit)

**`server.zig`** — `log.debug` / `log.info`:
- `maybe_accept`: new connection accepted (debug)
- `close_dead`: connection closed with fd (debug)
- `timeout_idle`: connection timed out (mark.debug)
- `log_metrics`: pushes connection pool gauges into tracer, calls `tracer.emit()`

**`tracer.zig`** — `log.debug` / `log.info`:
- `emit`: gauges, counters, per-span per-operation timing (info)
- `trace_log`: per-request prefetch/execute/total duration, status, fd (debug, guarded by `log_trace`)

**`connection.zig`** — `log.debug` / `log.warn`:
- `on_accept`: connection fd assigned (debug)
- `recv_callback`: peer closed / recv error (mark.debug)
- `send_callback`: send error (mark.debug)
- `try_parse_request`: invalid HTTP → closing (mark.warn)
- `try_parse_request`: unmapped request → closing (mark.warn)

**`io.zig`** — `log.info`:
- `open_listener`: bound to address (info)

**`state_machine.zig`** — marks only (test infrastructure):
- `MemoryStorage.fault`: busy/err fault injected (mark.debug)

### Never log (hot paths)

These run every tick or every byte boundary — no logging:
- `tick`, `flush_outbox`, `continue_receives`, `update_activity`
- `process_inbox` (delegates trace logging to tracer, guarded by `log_trace` bool)
- `submit_recv`, `submit_send`, `continue_recv`
- `try_parse_request` (except the error/closing branches)
- `invariants` (both server and connection)
- `recv_callback` / `send_callback` (except error branches)
- All `http.zig` functions (pure parsing)

## Marks (Coverage Marks)

`marks.zig` follows TigerBeetle's `src/testing/marks.zig`. Every file wraps its logger:

```zig
const marks = @import("marks.zig");
const log = marks.wrap_log(std.log.scoped(.module_name));
```

This gives two calling conventions:
- **`log.warn(...)`** — plain log, no mark tracking
- **`log.mark.warn(...)`** — records a hit when a mark is active, then logs normally

In non-test builds, `log.mark` aliases the base logger directly — zero overhead.

### When to use `log.mark.*`

Use `log.mark.*` for **testable decision boundaries** — code paths the sim fuzzer exercises. These are error/edge-case branches where a test should prove the path fires:

| File | Log site | Mark substring |
|------|----------|----------------|
| `connection.zig` | `recv_callback` peer closed | `"recv: peer closed"` |
| `connection.zig` | `send_callback` error | `"send: error"` |
| `connection.zig` | `try_parse_request` invalid HTTP | `"invalid HTTP"` |
| `server.zig` | `process_inbox` unmapped request | `"unmapped request"` |
| `server.zig` | `process_inbox` SSE mutation deferred | `"SSE mutation: deferring to follow-up"` |
| `app.zig` | prefetch fault injection busy | `"storage: busy fault injected"` |

### When NOT to use `log.mark.*`

Keep plain `log.*` for one-time events that aren't testable decision boundaries:
- Startup/shutdown messages (`main.zig`)
- Listener bound (`io.zig`)
- Connection accepted/closed (happy path in `server.zig`)

### Test side

```zig
const marks = @import("marks.zig");

// Activate a mark, run the code, assert it fired.
const mark = marks.check("recv: peer closed");
// ... trigger the code path ...
try mark.expect_hit();

// Or assert a path was NOT taken.
const mark2 = marks.check("something");
// ... run code that should NOT hit this path ...
try mark2.expect_not_hit();
```

Rules:
- Only one mark active at a time (`check` asserts no mark is already active)
- Always call `expect_hit()` or `expect_not_hit()` — they reset the global state
- Match is substring: `check("recv: peer closed")` matches `"recv: peer closed or error fd=5 result=-1"`
