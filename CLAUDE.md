# Tiger Web

Ecommerce HTTP server built in Zig, following TigerBeetle conventions.

**Philosophy:** Build the foundation correctly, then ship confidently. Every layer trusts the one below it because every layer was built to be trusted. Infrastructure isn't overhead — it's the product. Assertions, comptime checks, and round-trip tests are guarantees that compound. Cut corners in the foundation and every layer above inherits the doubt.

When faced with decisions always take the most correct approach never the simplest approach. We are shooting for safety and reliability.

**Porting from TigerBeetle:** When adopting a TB primitive (trace, time, bench, constants), `cp` the TB file and make surgical edits — don't rewrite from memory. Copying is more faithful. A from-scratch port accumulates subtle deviations (wrong field order, missing self-tracing, hardcoded values instead of constants, private vs pub). Each deviation is small, but they compound. Surgical edits on the real file produce an auditable diff where every change from TB's original is intentional and documented. Reference repo: `/home/walker/Documents/personal/tigerbeetle`

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
# load — measure how many requests the server handles under real traffic
./zig/zig build load -Doptimize=ReleaseSafe -- --connections=128 --requests=100000
./zig/zig build load -- --port=3000          # against existing server
./zig/zig build load -- --ops=create_product:80,list_products:20  # custom weights
#
# loadtest — full throughput benchmark with orphan safety (native + sidecar)
sh scripts/loadtest.sh              # native only
sh scripts/loadtest.sh sidecar      # native + 1 sidecar + 2 sidecars

# --- Profiling (requires `perf` — sudo pacman -S perf) ---
./zig/zig build -Doptimize=ReleaseSafe       # build with symbols
zig-out/bin/tiger-web start --port=0 --db=bench.db >port.txt 2>/dev/null &
perf record -g --call-graph dwarf -p $! -o perf.data &
zig-out/bin/tiger-load --port=$(cat port.txt) --connections=128 --requests=100000
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
| `adapters/typescript.ts` | Reads manifest, generates binary dispatch |
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
| `framework/wal.zig` | `WalType(Message, root_fn)` — append-only replay log, writes Message entries after commit(), no fsync |
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
| `worker.zig` | Worker process — polls server for pending orders, simulates external API calls |
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
