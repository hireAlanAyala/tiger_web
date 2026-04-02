# Sidecar Scaling — N+1 Compute Processes

> **Principle:** Scale by adding processes, not infrastructure.
> Handler code unchanged. Framework manages lifecycle.

## Core insight: one primitive

A sidecar is a compute unit. It runs handler code — pure functions
that take input and return output. The framework sends it work via
CALL/RESULT over a CRC-framed connection. The sidecar doesn't know
or care what triggered the work.

There is no "worker" as a separate concept. Background work (process
an order, send an email) is a CALL to a sidecar, same as an HTTP
request handler. The only difference is dispatch policy:

| Work type | Who initiates | Who waits for RESULT |
|---|---|---|
| Request-path | HTTP request → server sends CALL | HTTP client (blocks response) |
| Background | Server queues work → sends CALL | No one (fire-and-forget) |

Same bus. Same connection. Same protocol. Same supervisor. Same
process model. The dispatch policy is a server concern, not a
transport concern.

This means multi-connection bus serves all async work: N
request-path sidecars, hot standby failover, AND background
work dispatch. One primitive, not two.

## Architecture

```
HTTP → Server (1 core) → Bus (1 listen socket, N connections)
                           ├── Connection[0] → Sidecar A
                           ├── Connection[1] → Sidecar B
                           └── Connection[2] → Sidecar C
                                    ↓
                                 SQLite
```

The bus is the connection multiplexer (TB pattern). One listen
socket, one pool, N connections. The server asks the bus for the
active connection. Failover is a bus concern — the server says
"send this CALL", the bus picks the connection.

NOT N buses (each with its own pool, listen socket, accept loop).
One bus, N connections. Same as TB's MessageBus managing N replicas.

## Three stages

### Stage 1: Single sidecar — DONE

One bus, one connection, serial pipeline. 25K req/s with
TypeScript. Supervisor manages one sidecar process.

```
tiger-web -- node dispatch.js

HTTP → Server (1 core) → Bus (1 connection) → Sidecar A (1 core)
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
- SimSidecar: 10 recovery sim tests
- Supervisor unit tests: 16 state machine tests (step function)
- Bus interface: get_message, unref, send_message, is_connected,
  can_send, terminate, connect_fd, frame_header_size

### Stage 2: Hot standby (no concurrent pipeline)

Two sidecars, one active, one standby. Serial pipeline — still
one request at a time. Same throughput (25K req/s) but instant
failover on crash. Zero downtime restarts.

```
tiger-web --sidecar-count=2 -- node dispatch.js

HTTP → Server (1 core) → Bus (2 connections)
                           ├── Connection[0] → Sidecar A (active)
                           └── Connection[1] → Sidecar B (standby)
                                    ↓
                                 SQLite
```

On crash of A:
1. Bus connection[0] closes → on_close fires
2. Bus switches active to connection[1] (already READY)
3. Next request routes to B — no 503, no delay
4. Supervisor detects exit, respawns A in background
5. A connects, READY handshake, becomes new standby

**What changes from Stage 1:**

Bus (multi-connection):
- `connection` becomes `connections: [max_connections]Connection`
- `connections_ready: [max_connections]bool` (READY handshake done)
- `active: ?u8` — index of connection to dispatch to
- `tick_accept` fills next empty connection slot
- `on_close` callback includes connection index
- Pool sized for N connections: `N * (1 + send_queue_max) + 1`
- One listen socket (unchanged)

Server:
- `sidecar_bus.send_message()` routes to active connection
- `sidecar_on_close(index)` → if active crashed, switch to standby
- No array of buses, no array of clients — one bus, one client
  (client state is per-request, not per-connection)

Supervisor:
- Manages N children (array of Process)
- `--sidecar-count=N` from CLI

**What doesn't change:**
- Handler interface (same pure functions)
- Pipeline (serial, one commit_stage)
- State machine, storage, WAL, auth
- Wire format, CALL/RESULT protocol
- SidecarClientType (one client per request, not per connection)
- Fuzzers (test one connection — connection behavior is the same)
- SimSidecar tests (test one connection lifecycle)

### Stage 3: Round-robin (requires concurrent pipeline)

N sidecars, all active. Multiple requests in-flight. Dispatch
round-robin to whichever sidecar is free. Throughput scales
linearly with sidecar count. Also handles background work —
CALL "process_order" dispatched to any free sidecar.

```
tiger-web --sidecar-count=4 -- node dispatch.js

HTTP → Server (1 core) → Bus (4 connections)
         ↓               ├── Connection[0] → Sidecar A (1 core)
   N pipelines            ├── Connection[1] → Sidecar B (1 core)
         ↓               ├── Connection[2] → Sidecar C (1 core)
      SQLite              └── Connection[3] → Sidecar D (1 core)
```

| Sidecars | Throughput (TypeScript) | Cores | RAM |
|---|---|---|---|
| 1 | ~25K req/s | 2 | ~60MB |
| 2 | ~50K req/s | 3 | ~110MB |
| 4 | ~100K req/s | 5 | ~210MB |

**Requires concurrent pipeline (from network-storage.md):**
- Multiple `commit_stage` slots (one per in-flight request)
- Each pipeline slot paired with a bus connection
- SQLite transactions serial (begin/commit one at a time)
  but prefetch + render overlap across pipelines

**Dispatch strategy:**
- Round-robin: `next_index = (next_index + 1) % connected_count`
- Skip disconnected sidecars
- If all busy, request waits in .ready until a pipeline frees
- Background CALLs dispatched to any free connection

## Implementation order

1. ~~**Process spawning**~~ ✓ DONE — supervisor.zig, `--` CLI
2. ~~**Recovery sim tests**~~ ✓ DONE — 10 tests
3. **Multi-connection bus** — connections array, active index,
   pool sizing for N, tick_accept fills slots, on_close with index
4. **Hot standby failover** — on_close switches active.
   Zero downtime. Sim test: kill A, next request hits B.
5. **CLI flag** — `--sidecar-count=N`. Default 1.
6. **Concurrent pipeline** (separate plan, network-storage.md) —
   multiple commit_stage slots. Required for round-robin.
7. **Round-robin dispatch** — distribute across N sidecars.
   Background CALLs use the same dispatch.

## Why there's no "worker"

The worker was a separate concept in early design — a process that
polls for pending work. But the sidecar already IS an async compute
unit. The server sends it CALLs. Some CALLs are request-path (HTTP
handler), some are background (process order). The sidecar doesn't
know the difference. Same connection, same protocol, same supervisor.

A "worker" is just a sidecar that receives background CALLs instead
of (or in addition to) request-path CALLs. The dispatch policy
decides which CALL goes to which connection. The primitive is one:
the sidecar process on the multi-connection bus.

This eliminates: a separate worker binary, a separate connection
type, a separate supervisor, a separate testing infrastructure.
One primitive serves request handling, background jobs, and
scheduled tasks.

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
| Recovery sim tests | Stage 1 ✓ DONE |
| Multi-connection bus | Stage 2+ |
| CLI --sidecar-count | Stage 2+ |
| Concurrent pipeline (network-storage.md) | Stage 3 |

## Files affected

| File | Stage | Change |
|---|---|---|
| supervisor.zig | 1 ✓ | Spawn, reap, restart, kill stuck |
| main.zig | 1 ✓ | Supervisor wiring, `--` CLI |
| framework/server.zig | 1 ✓ | terminate_sidecar (no kill) |
| protocol.zig | 1 ✓ | READY without pid |
| sim_sidecar.zig | 1 ✓ | 10 recovery sim tests |
| framework/message_bus.zig | 2 | Multi-connection: connections array, active index, pool sizing |
| framework/server.zig | 2 | on_close with index, failover logic |
| supervisor.zig | 2 | N children |
| framework/server.zig | 3 | Multiple pipeline slots, background dispatch |
