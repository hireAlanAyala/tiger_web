# Decision: No Cross-Component State Machine

## The question

Should the relationships between server, bus, supervisor, and
sidecar be modeled as an explicit state machine?

## The answer: No

Each component already owns its own state machine:

- Connection: closed → connected → terminating → closed
- Process: idle → running → exited → stopped
- Pipeline: idle → route → prefetch → handle → render → idle
- Per-slot READY: false → true → false

The cross-component relationships are enforced by:
1. **Callback ordering** — bus calls on_close, server handles it
2. **Assertions in invariants()** — active implies ready, ready
   count ≤ connections count
3. **main.zig wiring** — reads public state, calls notify_connected

An explicit cross-component state machine would add a concept
without adding correctness. TB doesn't model cross-component
state — each component owns its own, callbacks enforce transitions,
invariants catch violations.

## What we have instead: lifecycle documentation

The lifecycle is documented (not code) so developers can trace
the flow without reading every callback:

```
Sidecar slot lifecycle:

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

## Why not a state machine

1. **Each component already has one.** Adding a cross-component
   state machine means three state machines (component, cross,
   and the implicit one from callbacks) describing the same flow.
   Two will get out of sync.

2. **TB doesn't do it.** TB's Connection, Replica, and Client each
   have their own states. The cross-component relationships are
   callback-driven. No cross-component state enum.

3. **The invariants ARE the state machine.** `invariants()` asserts
   the valid combinations after every tick. If active implies
   ready, and ready implies connected, the invalid states are
   unreachable. The assertions are cheaper to maintain than a
   state enum.

4. **A state enum hides the owner.** `SlotState.accepting` — who
   owns this transition? The bus? The server? With per-component
   states, ownership is clear: `connection.state == .connected`
   is the bus's field. `connections_ready[i]` is the server's field.
