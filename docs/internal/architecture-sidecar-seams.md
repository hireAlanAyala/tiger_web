# Sidecar Architecture — Responsibility Seams

## One primitive

A sidecar is a compute unit. It runs handler code — pure functions
that take input and return output. The framework sends it work via
CALL/RESULT over a CRC-framed connection. The sidecar doesn't know
or care what triggered the work.

There is no "worker" as a separate concept. Background work is a
CALL to a sidecar, same as a request-path handler. The difference
is dispatch policy (server concern), not the primitive.

## Architecture

```
HTTP → Server (1 core) → Bus (1 listen socket, N connections)
                           ├── Connection[0] → Sidecar A
                           ├── Connection[1] → Sidecar B
                           └── Connection[2] → Sidecar C
                                    ↓
                                 SQLite
```

## Responsibility seam

| Concern | Owner | Mechanism |
|---|---|---|
| Connection pool | Bus | connections array, accept fills slots |
| Frame delivery | Bus | on_frame_fn(context, connection_index, frame) |
| Close notification | Bus | on_close_fn(context, connection_index, reason) |
| Active routing | Server sets, Bus stores | server calls bus.set_active(index) |
| READY tracking | Server | connections_ready[N] per-connection bools |
| Failover | Server | sidecar_on_close switches active to standby |
| Request timeout | Server | 5s default, terminates connection |
| Process lifecycle | Supervisor | spawn N, reap (waitpid), respawn with backoff |
| Wiring | main.zig | reads server + supervisor state, no cross-refs |

The bus stores active but never decides its value. The server sets
active but never manages connections. main.zig never stores pointers
to either. Clean seams.

## Sidecar slot lifecycle

No cross-component state machine — each component owns its own
state (Connection, Process, pipeline). Callbacks enforce transitions.
invariants() catches violations. See decision-no-cross-component-state-machine.md.

```
  Supervisor spawns process
          ↓
  Process connects to unix socket
          ↓
  Bus accepts → connection[i].state = .connected
          ↓
  Sidecar sends READY → server: connections_ready[i] = true
          ↓
  First ready → server: bus.set_active(i)
          ↓
  Serving requests (CALL/RESULT on active connection)
          ↓
  Crash / timeout / protocol violation
          ↓
  Server: bus.terminate() → connection closes → on_close fires
          ↓
  Server: connections_ready[i] = false, find_next_ready
          ↓
  Sidecar detects closed socket → exits
          ↓
  Supervisor: waitpid reaps → schedules respawn
          ↓
  (cycle repeats)
```

## Hot standby failover

With -Dsidecar-count=2, two sidecars connect. First becomes active,
second becomes standby. On crash of active:

1. Bus connection closes → on_close_fn(ctx, index, reason) fires
2. Server: connections_ready[index] = false, find_next_ready_slot
3. Server: bus.set_active(standby_index) — standby is already READY
4. Next request routes to standby — no 503, no delay (<1ms)
5. Supervisor reaps dead process, respawns in background
6. New process connects, READY, becomes standby

The in-flight request on the crashed connection gets 503 (pipeline
reset). The NEXT request goes to the standby. Stage 3 (concurrent
pipeline) could re-dispatch to avoid even that one 503.

## Key implementation files

| File | Role |
|---|---|
| framework/message_bus.zig | Multi-connection bus, active routing, pool |
| framework/server.zig | READY tracking, failover, timeout enforcement |
| supervisor.zig | N processes, spawn/reap/respawn |
| sidecar.zig | SidecarClientType(Bus) — protocol state machine |
| sidecar_handlers.zig | SidecarHandlersType(Storage, Bus) |
| app.zig | Composition root, sidecar_enabled + sidecar_count |
| main.zig | Wiring, CLI (-- separator), supervisor lifecycle |
| sim_io.zig | SimIO (shared by sim.zig + sim_sidecar.zig) |
| sim_sidecar.zig | 11 sim tests, TestHarness |

## Related decisions

- [Sidecar is the compute primitive](decision-sidecar-primitive.md) (memory)
- [Supervisor architecture](decision-supervisor.md) (memory)
- [Handler timeout contract](decision-handler-timeout-contract.md)
- [No cross-component state machine](decision-no-cross-component-state-machine.md)
