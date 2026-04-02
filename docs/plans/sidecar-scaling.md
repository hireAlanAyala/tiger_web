# Sidecar Scaling — N+1 Process Strategy

> **Principle:** Scale by adding processes, not infrastructure.
> Handler code unchanged. Framework manages lifecycle.

## What this is

The supervisor spawns and manages N sidecar processes. Each connects
via unix socket, completes the READY handshake, and serves
requests. The handler author writes pure functions once. Scaling
is a CLI flag: `--sidecar-count=2`.

## Three stages

### Stage 1: Single sidecar — DONE

One bus, one connection, serial pipeline. 25K req/s with
TypeScript. Supervisor manages one sidecar process.

```
tiger-web -- node dispatch.js

HTTP → Server (1 core) → Bus → Sidecar A (1 core)
                           ↓
                        SQLite
```

**What exists:**
- Supervisor (supervisor.zig): spawn, reap (waitpid WNOHANG),
  restart with exponential backoff, kill stuck after grace period
- CLI: `tiger-web -- node dispatch.js` (any runtime, `--` separator)
- Server: terminate_sidecar (connection only, no process kill)
- main.zig wiring: server.sidecar_connected → supervisor.request_restart /
  notify_connected. No cross-references.
- READY frame: [tag][version] — no pid (supervisor has Child.id)
- SimSidecar: basic test passing (connect, CALL/RESULT, 200)
- Supervisor unit tests: 16 state machine tests (step function)

### Stage 2: Hot standby (no concurrent pipeline)

Two sidecars, one active, one standby. Serial pipeline — still
one request at a time. Same throughput (25K req/s) but instant
failover on crash. Zero downtime restarts.

```
tiger-web --sidecar-count=2 -- node dispatch.js

HTTP → Server (1 core) → Bus[0] → Sidecar A (active)
                          Bus[1] → Sidecar B (standby)
                            ↓
                         SQLite
```

On crash of A:
1. Bus[0].on_close fires → sidecar_connected[0] = false
2. Server switches active_sidecar to Bus[1] (already connected)
3. Next request routes to B — no 503, no delay
4. Supervisor detects exit, respawns A in background
5. A connects, READY handshake, becomes new standby

**What changes from Stage 1:**
- `sidecar_bus` becomes `sidecar_buses: [max_sidecars]SidecarBus`
- `sidecar_client` becomes `sidecar_clients: [max_sidecars]SidecarClient`
- `sidecar_connected` becomes `sidecar_connected: [max_sidecars]bool`
- Supervisor manages N children (array of Process)
- `active_sidecar: u8` — index of the bus to dispatch to
- `sidecar_count: u8` — from CLI `--sidecar-count`
- `wire_sidecar` becomes `wire_sidecar_at(index)`
- `tick_accept` loops over all buses
- Handlers receive a pointer to the active bus/client
- `sidecar_on_close` checks which bus disconnected, switches active
- READY frame adds sidecar_index for bus correlation

**What doesn't change:**
- Handler interface (same pure functions)
- Pipeline (serial, one commit_stage)
- State machine, SM, storage, WAL, auth
- Wire format, CALL/RESULT protocol
- Fuzzers (test one connection — connection behavior is the same)

### Stage 3: Round-robin (requires concurrent pipeline)

N sidecars, all active. Multiple requests in-flight. Dispatch
round-robin to whichever sidecar is free. Throughput scales
linearly with sidecar count.

```
tiger-web --sidecar-count=4 -- node dispatch.js

HTTP → Server (1 core) → Bus[0] → Sidecar A (1 core)
         ↓               Bus[1] → Sidecar B (1 core)
   N pipelines            Bus[2] → Sidecar C (1 core)
         ↓               Bus[3] → Sidecar D (1 core)
      SQLite
```

| Sidecars | Throughput (TypeScript) | Cores | RAM |
|---|---|---|---|
| 1 | ~25K req/s | 2 | ~60MB |
| 2 | ~50K req/s | 3 | ~110MB |
| 4 | ~100K req/s | 5 | ~210MB |

**Requires concurrent pipeline (from network-storage.md):**
- Multiple `commit_stage` slots (one per in-flight request)
- Multiple `commit_connection` / `commit_msg` / etc.
- Process_inbox dispatches to any free pipeline slot
- Each pipeline slot is paired with a sidecar bus
- SQLite transactions are serial (begin/commit still one at a time)
  but prefetch + render overlap across pipelines

**Dispatch strategy:**
- Round-robin: `next_index = (next_index + 1) % connected_count`
- Skip disconnected sidecars
- If all busy, request waits in .ready until a pipeline frees

**What changes from Stage 2:**
- `commit_stage` becomes array of pipeline slots
- `process_inbox` iterates connections AND free pipeline slots
- Each pipeline slot owns its commit_msg, commit_cache, etc.
- `commit_dispatch` takes a pipeline index
- Sidecar callbacks (on_frame, on_close) route to correct pipeline
- Transaction batching: multiple pipelines share one SQLite transaction
  per tick (begin_batch / commit_batch wraps all pipelines)

## Implementation order

1. ~~**Process spawning**~~ ✓ DONE — supervisor.zig, `--` CLI
2. **Recovery sim tests** — disconnect → 503 → reconnect → 200,
   render crash fallback, timeout, protocol violations (Phase 4 step 5)
3. **Supervisor integration test** — test sidecar binary (Zig),
   real spawn/crash/respawn cycle (Phase 4.5)
4. **Multi-bus** — array of buses, accept on each, READY per
   connection. `active_sidecar` index for dispatch.
5. **Hot standby failover** — on_close switches active index.
   Zero downtime. Verify with e2e test (kill A, request hits B).
6. **CLI flag** — `--sidecar-count=N`. Default 1 (current behavior).
7. **Concurrent pipeline** (separate plan, network-storage.md) —
   multiple commit_stage slots. Required for round-robin.
8. **Round-robin dispatch** — distribute requests across N sidecars.
   Verify throughput scales linearly.

## Resource comparison

### Tiger_web N+1 sidecars vs industry N+1 servers

| | Tiger_web (4 sidecars) | Industry (4 Node servers) |
|---|---|---|
| RAM | ~210MB | ~2.1GB |
| Cores | 5 | 8 (4 servers + PG + Redis + Nginx + PgBouncer) |
| Throughput | ~100K req/s | ~20K req/s |
| Tools | 1 binary + 4 node | 7 services |
| Failover | <1ms (already connected) | 5-30s (health check + drain) |
| State sharing | None (SQLite local) | Redis + PostgreSQL |
| Deploy | `--sidecar-count=4` | Kubernetes manifest |
| Handler changes | None | None |
| Infra changes | None | PG replicas, Redis cluster, LB config |

### Why it works

Handler functions are pure — no shared mutable state, no globals,
no sockets, no file handles. The framework owns all IO. Duplicating
a function executor (sidecar) is cheap. Duplicating an application
server (Node + Express + PG pool + Redis + middleware) is expensive.

The scaling primitive is the process, not the server. Add a process,
get more compute. The industry scales by adding servers, which means
adding infrastructure. Tiger_web scales by adding compute only.

## Dependencies

| Dependency | Required for |
|---|---|
| Supervisor (supervisor.zig) | All stages ✓ DONE |
| Recovery sim tests | Stage 1 verification |
| Supervisor integration test | Stage 1 e2e verification |
| Multi-bus array | Stage 2+ |
| CLI --sidecar-count | Stage 2+ |
| Concurrent pipeline (network-storage.md) | Stage 3 |

## Files affected

| File | Stage | Change |
|---|---|---|
| supervisor.zig | 1 ✓ | Spawn, reap, restart, kill stuck |
| main.zig | 1 ✓ | Supervisor wiring, `--` CLI |
| framework/server.zig | 1 ✓ | terminate_sidecar (no kill) |
| protocol.zig | 1 ✓ | READY without pid |
| sim_sidecar.zig | 1 ✓ | SimSidecar basic test |
| framework/server.zig | 2 | Multi-bus array, active index, failover |
| sidecar_handlers.zig | 2 | Handlers receive active bus/client |
| framework/server.zig | 3 | Multiple pipeline slots |
| app.zig | 2 | --sidecar-count CLI arg |
