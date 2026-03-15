# Tiger Web

Ecommerce HTTP server built in Zig, following TigerBeetle conventions.

## Quick Reference

```bash
sh zig/download.sh          # one-time: download Zig 0.14.1

# First-time setup — create dev.env (gitignored):
cat > dev.env << 'EOF'
export SECRET_KEY="tiger-web-test-key-0123456789ab!"
export TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjEsImV4cCI6MjE0NTkxNjgwMH0.ulNOjuMyYo5tT5gG78pG6HvyCZm4Gs7azogXTvz-VgY"
EOF

source dev.env                              # load SECRET_KEY and TOKEN
./zig/zig build run                         # run the server (default port 3000)
TOKEN=$TOKEN ./zig/zig build run-worker     # run the worker (polls server)
./zig/zig build run -- --log-debug          # enable debug log output
./zig/zig build run -- --log-debug --log-trace  # per-request trace logs
./zig/zig build unit-test    # unit tests (message, state_machine, http, marks, codec)
./zig/zig build test         # simulation tests (PRNG-driven, full stack)
./zig/zig build fuzz -- state_machine              # random seed
./zig/zig build fuzz -- state_machine 12345        # specific seed
./zig/zig build fuzz -- --events-max=1000 state_machine  # with options
./zig/zig build fuzz -- smoke                      # all fuzzers, small event counts
./zig/zig build bench           # state machine benchmark (real measurements)
```

## Architecture

Single-threaded event loop using epoll. No allocations after startup. Request pipeline with prefetch/execute split:

```
http.zig → codec.zig → message.zig → state_machine.zig → storage
(parse HTTP)  (route + JSON → typed)  (types)  (prefetch + execute)  (SQLite or in-memory)
                                                     ↓
                                                render.zig
                                          (HTML page or SSE fragments)
```

| File | Role |
|---|---|
| `main.zig` | Entry point, tick loop, runtime log level filtering, CLI parsing |
| `server.zig` | `ServerType(IO, Storage)` — accepts connections, drives prefetch→execute |
| `connection.zig` | Per-connection state machine (accepting → receiving → ready → sending) |
| `http.zig` | HTTP/1.0+1.1 request parser, status lines, 401 response |
| `codec.zig` | Route parsing, JSON request → typed struct translation, UUID parsing |
| `render.zig` | HTML + SSE response renderer — body-first with Content-Length backfill (keep-alive), SSE from offset 0 (Connection: close) |
| `message.zig` | Types: Product, ProductCollection, flat Operation enum with EventType, Message, MessageResponse |
| `state_machine.zig` | `StateMachineType(Storage)` — inline dispatch in execute, flat switch in prefetch, `MemoryStorage` |
| `storage.zig` | `SqliteStorage` — SQLite backend with prepared statements, WAL mode |
| `io.zig` | epoll IO layer (real syscalls) |
| `marks.zig` | Coverage marks — links log sites to test assertions |
| `tracer.zig` | Minimal tracer — gauges, counters, span timings, trace logging. All metrics flow through `emit()` |
| `sim.zig` | `SimIO` + `MemoryStorage` with PRNG-driven fault injection |
| `fuzz_tests.zig` | Fuzz test dispatcher — single binary routing to all fuzzers, matches TB's fuzz_tests.zig |
| `fuzz_lib.zig` | Shared fuzz utilities — `FuzzArgs` struct, `random_enum_weights`, matches TB's testing/fuzz.zig |
| `fuzz.zig` | State machine fuzzer — bypasses HTTP, calls prefetch/commit directly |
| `codec_fuzz.zig` | Codec fuzzer — throws random methods/paths/JSON at codec.translate |
| `render_fuzz.zig` | Render fuzzer — random operations/results through encode_response, asserts framing and keep-alive invariants |
| `auditor.zig` | Auditor oracle — independent reference model that validates state machine responses (TB pattern) |
| `storage_fuzz.zig` | Storage equivalence fuzzer — runs MemoryStorage vs SqliteStorage vs Auditor, asserts agreement |
| `stdx.zig` | Ported from TB's stdx — `no_padding`, `equal_bytes`, `has_unique_representation` |
| `prng.zig` | Xoshiro256++ PRNG with Ratio, Combination, Reservoir — matches TigerBeetle's stdx.PRNG |
| `bench.zig` | Micro benchmarking harness — smoke/benchmark dual mode, matches TB's testing/bench.zig |
| `state_machine_benchmark.zig` | State machine benchmark — per-operation prefetch/commit throughput, regression detector |
| `flags.zig` | CLI argument parser — struct-driven `--key=value` parsing, ported from TigerBeetle's stdx/flags.zig |

## Conventions

Follow TigerBeetle style. Reference repo: `/home/walker/Documents/personal/tigerbeetle`

- **Assertions over error handling** — use `assert` for invariants, not `if/else` error paths
- **No allocations in hot paths** — all buffers are fixed-size, allocated at init
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
| `sim.zig` | — | No logging (test infrastructure) |

### Where to log

**`main.zig`** — `log.info` / `log.err`:
- Server config and listen port (startup)
- Log level and trace flag when `--log-debug` active (startup)
- `--log-trace` without `--log-debug` (err, then exit)

**`server.zig`** — `log.debug` / `log.info`:
- `accept_callback`: new connection accepted (debug), accept failed (mark.warn)
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
| `connection.zig` | `try_parse_request` unmapped request | `"unmapped request"` |
| `server.zig` | `accept_callback` failed | `"accept failed"` |
| `server.zig` | `timeout_idle` timed out | `"connection timed out"` |
| `state_machine.zig` | `MemoryStorage.fault` busy injected | `"storage: busy fault injected"` |
| `state_machine.zig` | `MemoryStorage.fault` err injected | `"storage: err fault injected"` |

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
