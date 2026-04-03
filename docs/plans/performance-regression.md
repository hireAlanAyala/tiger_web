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

**CallTiming (sidecar.zig) is deleted — wrong primitive.**
It reimplements what trace event nesting gives for free.
sidecar_call is the outer span. storage_op fires when a QUERY
arrives during the CALL. The gap IS the V8 compute time —
visible in Perfetto without measuring it. No separate system.

| CallTiming field | Trace equivalent (free from nesting) |
|---|---|
| `call_ns()` | sidecar_call span duration |
| `query_total_ns` | sum of storage_op spans inside sidecar_call |
| `query_count` | count of storage_op spans inside sidecar_call |
| `sidecar_ns` | visible gap between storage_op and sidecar_call edges |

## Implementation phases

### Phase 1: Trace infrastructure (start from scratch)

Do NOT evolve the current tracer. The current timing sites are
wrong — `.execute` span crosses three stages, CallTiming is a
separate system, timing was designed for serial pipeline.

This is the first phase because all other phases depend on it:
benchmarks need the tracer for overhead measurement, budget
assertions need the tick span for duration tracking, CI metrics
need trace output for regression visualization.

**Step 1: Design events from boundaries.**

6 events. 5 boundary crossings + 1 synchronization wait.

```zig
const Event = union(enum) {
    // aggregate_only — fires every tick, too frequent for spans
    tick,

    // Pipeline stage — one span per stage per slot
    pipeline_stage: struct {
        stage: CommitStage,
        slot: u8,
        op: ?Operation,  // null at .route (operation unknown until routed)
    },

    // Sidecar CALL→RESULT — one span per round-trip
    sidecar_call: struct {
        function: enum { route, prefetch, handle, render },  // comptime-known, not string
        slot: u8,
        request_id: u32,
    },

    // Storage operation — one span per query or write
    // Fires from SidecarClient.on_frame around query_fn (per-QUERY)
    // and from server.zig around native handler storage calls
    storage_op: struct { slot: u8 },

    // Synchronization wait — time spent waiting for another slot's write
    // NOT a boundary crossing — a contention event that affects latency
    handle_lock_wait: struct { slot: u8 },

    // WAL append — disk write after commit
    wal_append: struct { op: Operation },
};
```

**Step 2: Port TB's tracer engine.**
- Chrome Tracing JSON output (`--trace=file.json`)
- aggregate_only support
- Timing aggregation (min/max/sum/count)
- Gauges and counters
- StatsD emission (log mode first, UDP later)
- `cancel_slot(slot_idx)` — cancel all open spans for a slot
  (TB uses per-event cancel; we need per-slot because concurrent
  slots mean per-event cancel would kill other slots' spans)
- Time source: injected `Time` vtable, not `std.time.Instant`
  (simulation determinism)
- Use TB reference files (`framework/trace/*_tb.zig`)

**Step 3: Wire tracer ownership.**
- Create tracer in `main.zig`, pass to server
- Server stores `*Tracer`
- SidecarClient stores `*Tracer` (like TB's Grid stores `*Tracer`)
  — for per-QUERY storage_op spans inside on_frame.
  Set during `wire_sidecar`, same pattern as sidecar_client and
  sidecar_bus pointers. No signature changes to on_frame.
- SM loses tracer field entirely (tracer is not a framework service,
  it's infrastructure owned by the server)

**Step 4: Wire events at boundary sites.**
- `trace.start(.tick)` / `defer trace.stop(.tick)` in tick()
- `trace.start(.{.pipeline_stage = ...})` at each stage entry in commit_dispatch
- `trace.start(.{.sidecar_call = ...})` in SidecarClient.call_submit
- `trace.stop(.{.sidecar_call = ...})` in SidecarClient.on_frame (.complete)
- `trace.start(.{.storage_op = ...})` in SidecarClient.on_frame before query_fn
- `trace.stop(.{.storage_op = ...})` in SidecarClient.on_frame after query_fn
- `trace.start(.{.storage_op = ...})` in server.zig around native handler_execute
- `trace.start(.{.handle_lock_wait = ...})` when slot enters .handle_wait
- `trace.stop(.{.handle_lock_wait = ...})` in wake_handle_waiters when slot resumes
- `trace.start(.{.wal_append = ...})` around wal.append_writes

**Step 5: Wire cancellation on recovery.**
Three paths cancel open spans for a slot:
- `sidecar_on_close`: `trace.cancel_slot(connection_index)`
- `timeout_idle`: `trace.cancel_slot(slot_idx)`
- `pipeline_reset`: `trace.cancel_slot(slot_idx)`
Replaces the current per-event-type switch (route → {}, prefetch →
cancel, render → cancel). One call, explicit, can't miss an event.

**Step 6: Delete old timing infrastructure.**
- Delete `framework/tracer.zig` entirely
- Delete `CallTiming` struct + `log_call_timing()` from sidecar.zig
- Delete `log_call_timing()` calls from sidecar_handlers.zig
- Delete `sm.tracer` field and `Tracer` construction from state_machine.zig
- Delete `pipeline_slots_max` param from `StateMachineType`
- Delete `framework/trace/*_tb.zig` reference files
- Update SM type in app.zig, main.zig, sim files (no slots_max param)

**Step 7: Verify.**
- `--trace=trace.json` → open in ui.perfetto.dev
- See concurrent pipeline timeline with overlapping slot spans
- See sidecar_call spans with nested storage_op spans (V8 = gap)
- See handle_lock_wait spans between slots
- Cancel paths produce valid JSON (no unclosed spans)
- SimIO tests: trace output is deterministic (same seed = same trace)
- All tests pass (unit, sim, sim-sidecar, fuzz smoke)

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

Runtime assertions on hot path resource usage. Assert bounded
COUNTS, not bounded DURATIONS — crashing under load is worse
than being slow under load.

- [ ] process_inbox: connections scanned ≤ max_connections
- [ ] wake_handle_waiters: waiters processed ≤ pipeline_slots_max
- [ ] Tick duration: measure via aggregate_only tick span, alert
      in CI metrics. Do NOT runtime-assert — ticks should take
      longer under load, not crash.

### Phase 4: Continuous metrics (CI)

Benchmark on every merge, store results, detect drift.

- [ ] CI step: run `zig build bench`, capture output
- [ ] JSON format: `{timestamp, commit, metrics: [{name, unit, value}]}`
- [ ] Git-backed storage (separate repo or branch)
- [ ] Baseline comparison: week-over-week mean
- [ ] Outlier detection: week-over-week mean comparison per metric
      (TB pattern — not a fixed 10% threshold, noisy metrics like
      p99 need wider bands than stable metrics like executable size)
- [ ] Visualization: line chart per metric over time

## Verification

After all phases:
- Every layer we control has a benchmark ✅
- Every benchmark runs in CI ✅
- Regressions detected automatically ✅
- `--trace=trace.json` opens in Perfetto with 6 boundary spans ✅
- No permanent profiling beyond 6 spans ✅
