# Performance regression prevention

Ensure every layer we control has a benchmark or assertion that
catches regressions before they ship.

## TB's pattern (what to adopt)

TB prevents regressions at 4 layers:

1. **Comptime** — `comptime { assert(...) }` blocks catch architectural
   violations at compile time. Constants derived from other constants
   with invariants. Change one → compile fails if invariant breaks.

2. **Dual-mode benchmarks** — same code runs as smoke test (small params,
   silent, prevents bitrot) and real benchmark (large params, prints
   results). `zig build test` runs smoke. `zig build bench` runs real.
   We already have this pattern in `state_machine_benchmark.zig`.

3. **Budget constants + runtime assertions** — `max_inflight`, `budget_max`,
   `iops_write_max`. Hot paths assert they're under budget. Prevents
   resource exhaustion and unbounded behavior.

4. **Continuous metrics** — on every merge to main, run benchmarks, store
   results in a git-backed JSON DB. Visualize trends. Detect gradual
   drift that single benchmarks miss.

## Layers we control

| Layer | Has benchmark? | Has comptime bounds? | Has budget assert? |
|---|---|---|---|
| Zig HTTP parser | ❌ | ✅ (recv_buf_max, send_buf_max) | ❌ |
| Zig SQLite layer | ✅ `zig build bench` | ❌ | ❌ |
| Zig framework tick loop | ✅ `zig build bench` | ✅ (max_connections, pipeline_slots_max) | ❌ |
| Binary protocol | ✅ fuzz smoke | ✅ (frame_max, queries_max) | ❌ |
| QUERY sub-protocol | ✅ fuzz smoke | ✅ (queries_max) | ❌ |
| Sidecar TS runtime | ✅ `--log-trace` (manual) | N/A | N/A |
| Concurrent pipeline | ✅ sim throughput assertion | ✅ (pipeline_slots_max) | ✅ handle_lock |
| Connection handling | ✅ sim tests | ✅ (max_connections) | ❌ |
| WAL recording | ✅ `zig build bench` | ✅ (entry_max) | ❌ |
| Tracer | ❌ | ❌ | ❌ |
| Annotation scanner | ❌ | N/A | N/A |
| Auth (cookie/session) | ❌ | ✅ (key_length) | ❌ |
| Render encoding | ❌ | ✅ (send_buf_max) | ❌ |

## Gaps to fill

### Missing benchmarks (add to `zig build bench`)
- [ ] HTTP parser: parse N requests, measure µs/req
- [ ] Auth: sign + verify N cookies, measure µs/op
- [ ] Render encoding: encode N responses, measure µs/op
- [ ] Tracer: start/stop N spans, measure overhead

### Missing budget assertions
- [ ] Tick loop: assert tick duration < budget (e.g., 1ms)
- [ ] process_inbox: assert connections scanned < max_connections
- [ ] wake_handle_waiters: assert waiters processed < pipeline_slots_max

### Missing CI gate
- [ ] Run `zig build bench` on every merge to main
- [ ] Store results (JSON, git-backed — TB pattern)
- [ ] Compare against previous merge baseline
- [ ] Alert on >10% regression in any metric
