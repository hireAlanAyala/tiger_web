# Performance regression prevention

Match TigerBeetle's approach 1:1. Four layers, each catching
regressions at a different scale.

## Strategy

1. **Baseline** — benchmark every component we control, store numbers
2. **Watch** — run benchmarks on every merge, compare against baseline
3. **Alert** — >10% change in any metric = something regressed
4. **Diagnose** — enable `--trace=trace.json`, open in Perfetto, find which boundary got slower
5. **Fix** — trace shows WHERE, benchmark diff shows HOW MUCH
6. **No permanent profiling hooks** beyond the 6 boundary spans. Temporary instrumentation to diagnose, then delete.

## TB's 4 layers mapped to our codebase

### Layer 1: Comptime bounds

Catch architectural violations at compile time. Constants derived
from other constants with invariants.

**We have:**
- max_connections, pipeline_slots_max, frame_max, queries_max
- entry_max (WAL), recv_buf_max, send_buf_max, key_length

**Gap: none.** All structural constants have comptime assertions.

### Layer 2: Dual-mode benchmarks

Same code runs as smoke test (small params, silent, bitrot prevention)
and real benchmark (large params, prints results).

**We have:**
- `state_machine_benchmark.zig` — per-operation µs/op (get, list, update)
- `sim_sidecar.zig` throughput test — asserts dual_tpr < single_tpr
- Fuzz smoke — all fuzzers with small event counts

**Gaps:**

| Missing benchmark | What it measures |
|---|---|
| HTTP parser | µs/req to parse N requests |
| Auth (cookie sign+verify) | µs/op for HMAC-SHA256 |
| Render encoding | µs/op to encode N responses |
| Tracer overhead | µs/op for start/stop/emit |
| Frame build/parse | µs/op for binary protocol encoding |
| Sidecar full pipeline | µs/req end-to-end with real V8 sidecar |

### Layer 3: Budget assertions

Runtime assertions that bound resource usage. Hot paths assert
they're under budget. Prevents unbounded behavior.

**We have:**
- handle_lock — exclusive write serialization
- pipeline_reset lock assertion — slot can't hold lock when reset
- connection_dispatched — prevents double dispatch
- invariants() per tick — structural cross-checks

**Gaps:**

| Missing budget | Where |
|---|---|
| Tick duration < 1ms | server.tick() |
| Connections scanned per tick < max_connections | process_inbox |
| Waiters processed per wake < pipeline_slots_max | wake_handle_waiters |

### Layer 4: Continuous metrics

Benchmarks on every merge to main. Store results in git-backed
JSON. Compare against baseline. Detect gradual drift.

**We have:** Nothing. Benchmarks run manually.

**Gap: entire layer missing.** Need:
- CI step to run `zig build bench` on merge to main
- JSON output format: `{timestamp, commit, metrics: [{name, unit, value}]}`
- Git-backed storage (TB uses a separate `devhubdb` repo)
- Week-over-week comparison (TB: `|recent_mean - baseline_mean| / baseline_mean`)
- Visualization (line charts per metric over time)

## Trace infrastructure (Perfetto-compatible)

TB outputs Chrome Tracing JSON (Perfetto/Spall/chrome://tracing).
We output text logs. Trace is the diagnostic tool — when a benchmark
regresses, trace shows which boundary got slower.

### Current state

| Feature | TB | Us |
|---|---|---|
| Timing aggregation (min/max/sum/count) | ✅ | ✅ |
| Debug log output (`--log-trace`) | ✅ | ✅ |
| Chrome Tracing JSON (`--trace=file.json`) | ✅ | ❌ |
| Perfetto timeline visualization | ✅ | ❌ |
| Typed events with args | ✅ (27 events) | ❌ (2 span enums) |
| aggregate_only (high-frequency events) | ✅ | ❌ |
| StatsD emission | ✅ | ❌ |

### TB reference files (copied verbatim)

`framework/trace/*_tb.zig` — 2,274 lines, 5 files. Not integrated
into the build. Reference for porting.

### 6 boundary events to implement

Trace boundary crossings — where work leaves our code and enters
another system. The span duration reveals the other system's cost.

| Event | Crosses to | aggregate_only? |
|---|---|---|
| tick | — (total per-tick work) | Yes |
| pipeline_stage (route, prefetch, handle, render) | handler execution | No |
| sidecar_call (CALL→RESULT) | sidecar runtime (V8/Go/Rust) | No |
| storage_op (query, write) | storage backend (SQLite/Postgres) | No |
| handle_lock_wait | another slot's write | No |
| wal_append | filesystem | No |

**Decisions:**
- **Trace boundaries, not interiors.** The span duration IS the measurement.
- **aggregate_only for tick.** Fires every 10ms. JSON per tick would explode the trace file.
- **storage_op, not "sqlite_query".** Storage-agnostic — same span for SQLite and Postgres.
- **sidecar_call, not per-CALL-type.** One span per round-trip, args carry the function name (route/prefetch/handle/render).
- **No IO idle span.** Tick duration already reveals server load (tick time - work time = idle).
- **No HTTP recv/send span.** Client network speed is not our boundary.
- **No per-SQL-statement span.** Too granular. Pipeline stage span already reveals total storage cost.

**Existing CallTiming (sidecar.zig) merges into sidecar_call event.**
One system, not two. CallTiming fields become event args.

## Implementation phases

### Phase 1: Trace output (Chrome Tracing JSON)

Port TB's trace.zig output format. Our tracer already captures
timing — this phase adds the JSON serialization.

- [ ] Add `--trace=<file.json>` CLI flag
- [ ] Write Chrome Tracing JSON on start/stop (Perfetto compatible)
- [ ] Add `aggregate_only` support (tick event: timing yes, JSON no)
- [ ] Define 6 boundary events as typed enum with args
- [ ] Replace current span enums (prefetch, execute) with boundary events
- [ ] Merge CallTiming into sidecar_call event
- [ ] Verify: open trace.json in ui.perfetto.dev, see pipeline timeline

### Phase 1b: Remove old timing infrastructure

The new tracer replaces three separate timing systems. Remove them
to avoid confusion — one system, not three.

| Remove | Where | Replaced by |
|---|---|---|
| Old `tracer.zig` span enums (prefetch, execute) | `framework/tracer.zig` | Boundary events (pipeline_stage, sidecar_call) |
| CallTiming struct | `sidecar.zig` | sidecar_call event |
| `log_call_timing()` calls | `sidecar_handlers.zig` | sidecar_call trace span |
| `sm.tracer.start/stop(.prefetch/.execute)` | `framework/server.zig` | `trace.start(.{.pipeline_stage = ...})` |
| `sm.tracer.trace_log()` | `framework/server.zig` | Chrome Tracing JSON (automatic) |
| `sm.tracer.count_status()` | `framework/server.zig` | `trace.count(.requests_ok)` |
| `sm.tracer.gauge()` | `framework/server.zig` | `trace.gauge(.connections_active, N)` |
| `sm.tracer.emit()` | `framework/server.zig` | `trace.emit_metrics()` |
| Per-slot `started[span][slot_idx]` arrays | `framework/tracer.zig` | Per-event `events_started[stack]` (TB pattern) |
| `_tb.zig` reference files | `framework/trace/` | Replaced by real implementation |

After cleanup: one tracer, one output format, one set of events.
No legacy timing code.

### Phase 2: Missing benchmarks

Add dual-mode benchmarks for framework components without coverage.

- [ ] HTTP parser benchmark (µs/req)
- [ ] Auth sign+verify benchmark (µs/op)
- [ ] Render encoding benchmark (µs/op)
- [ ] Tracer overhead benchmark (µs/op)
- [ ] Frame build/parse benchmark (µs/op)
- [ ] Sidecar end-to-end benchmark (µs/req with real V8)

Each: smoke mode in `zig build unit-test`, real mode in `zig build bench`.

### Phase 3: Budget assertions

Runtime assertions on hot path resource usage.

- [ ] Tick duration budget assertion
- [ ] process_inbox scan bound
- [ ] wake_handle_waiters bound

### Phase 4: Continuous metrics (CI)

Benchmark on every merge, store results, detect drift.

- [ ] CI step: run `zig build bench`, capture output
- [ ] JSON format: `{timestamp, commit, metrics: [{name, unit, value}]}`
- [ ] Git-backed storage (separate repo or branch)
- [ ] Baseline comparison: week-over-week mean
- [ ] Alert on >10% regression
- [ ] Visualization: line chart per metric over time

## Verification

After all phases:
- Every layer we control has a benchmark ✅
- Every benchmark runs in CI ✅
- Regressions detected automatically ✅
- `--trace=trace.json` opens in Perfetto with 6 boundary spans ✅
- No permanent profiling beyond 6 spans ✅
