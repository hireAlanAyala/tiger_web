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
socket, one pool, N connections. The bus is transport — it doesn't
know which connection is "active." The server owns routing and
failover decisions.

## Responsibility seam (Stage 2)

| Concern | Owner | Mechanism |
|---|---|---|
| Connection pool | Bus | connections array, accept fills slots |
| Frame delivery | Bus | on_frame_fn(context, connection_index, frame) |
| Close notification | Bus | on_close_fn(context, connection_index, reason) |
| READY tracking | Server | connections_ready[N] per-connection bools |
| Active routing | Server | sidecar_active_index, dispatch policy |
| Failover | Server | sidecar_on_close switches active to standby |
| Process lifecycle | Supervisor | spawn N, reap, restart |
| Wiring | main.zig | reads server + supervisor state, no cross-refs |

The bus never decides what "active" means. The server never manages
connections. main.zig never stores pointers to either. Clean seams.

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
- Supervisor (supervisor.zig): spawn, reap, restart, kill stuck
- CLI: `tiger-web -- node dispatch.js` (`--` separator)
- Server: terminate_sidecar (connection only, no process kill)
- main.zig wiring: no cross-references
- Bus interface: get_message, unref, send_message, is_connected,
  can_send, terminate, connect_fd, frame_header_size
- SimSidecar: 10 recovery sim tests
- Supervisor: 16 state machine unit tests

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
1. Bus connection[0] closes → on_close_fn(ctx, 0, reason) fires
2. Server sees index 0 was active → switches to connection[1]
3. Next request routes to B — no 503, no delay
4. Supervisor detects exit, respawns A in background
5. A connects to bus (fills empty slot), READY handshake
6. Server marks connection slot as ready, A becomes standby

#### Bus changes (transport layer)

The bus gains multi-connection support and a default active route.
TB pattern: bus stores `replicas[N]` and routes `send_message_to_replica(N)`
to the right connection. Our equivalent: bus stores `connections[N]`
and routes `send_message()` to `connections[active]`.

The bus knows which connection is active — set by the server via
`bus.set_active(index)`. This means `send_message()` doesn't change
signature. The SidecarClient is oblivious to multi-connection.

```zig
connections: [max_connections]Connection,
connections_count: u8,       // from options, set at init
active: ?u8 = null,          // set by server, used by send_message
accept_pending: [max_connections]bool,
accept_completions: [max_connections]IO.Completion,

// Pool sized for N connections:
// N recv messages + N * send_queue_max + 1 burst
const messages_max = connections_count * (1 + send_queue_max) + 1;
```

**Why active is on the bus, not the server:**
TB's `send_message_to_replica(N)` is a bus method that routes by
index. Our `send_message()` routes by `self.active`. The client
calls `bus.send_message(msg, len)` — unchanged from Stage 1.
The bus routes internally. If active is null, send silently drops
(returns false). TB does the same: if `replicas[N]` is null,
the message is dropped with a debug log.

**Callback signatures gain connection index:**
```zig
on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
on_close_fn: ?*const fn (*anyopaque, u8, CloseReason) void,
```

**tick_accept fills ALL empty slots:**
```zig
fn tick_accept(self: *Self) void {
    for (self.connections[0..self.connections_count], 0..) |*conn, i| {
        if (conn.state == .closed and !self.accept_pending[i]) {
            self.accept_pending[i] = true;
            self.io.accept(self.listen_fd, &self.accept_completions[i], ...);
        }
    }
}
```

**Bus interface — what changes, what doesn't:**
```zig
// Unchanged (client calls these — oblivious to multi-connection):
pub fn send_message(self, msg, len) void;  // routes to connections[active]
pub fn is_connected(self) bool;            // connections[active].state == .connected
pub fn can_send(self) bool;                // connections[active] send queue
pub fn get_message(self) *Message;         // shared pool
pub fn unref(self, msg) void;              // shared pool
pub const frame_header_size;               // unchanged

// New:
pub fn set_active(self, index: ?u8) void;  // server sets after READY/failover
pub fn terminate_connection(self, index: u8) void;
pub fn connection_count(self) u8;
```

Stage 1 compatibility: `connections_count = 1`, `active = 0`.
All existing methods work unchanged.

#### Server changes (routing + failover)

The server owns READY tracking and failover decisions. The bus
owns the active route (set by server). SidecarClient is unchanged.

```zig
// Per-connection READY tracking (replaces single sidecar_connected bool)
sidecar_connections_ready: [max]bool,
```

`sidecar_connected` becomes a computed property:
`bus.active != null and sidecar_connections_ready[bus.active.?]`

**sidecar_on_frame(ctx, connection_index, frame):**
```zig
fn sidecar_on_frame(ctx, index: u8, frame: []const u8) void {
    if (!server.sidecar_connections_ready[index]) {
        // READY handshake for THIS connection
        validate_ready(frame);
        server.sidecar_connections_ready[index] = true;
        if (server.sidecar_bus.active == null) {
            server.sidecar_bus.set_active(index);  // first ready = active
        }
        return;
    }
    // Only route frames from the ACTIVE connection to the client.
    // Standby connections are connected but idle — they don't
    // send unsolicited frames. If one does, ignore it.
    if (index != server.sidecar_bus.active.?) return;

    handlers.process_sidecar_frame(frame, storage);
}
```

**sidecar_on_close(ctx, connection_index, reason):**
```zig
fn sidecar_on_close(ctx, index: u8, reason) void {
    server.sidecar_connections_ready[index] = false;

    if (server.sidecar_bus.active != null and
        server.sidecar_bus.active.? == index)
    {
        // Active connection crashed — find standby.
        const next = find_next_ready(server);
        server.sidecar_bus.set_active(next);
        // If null: no ready connections, 503 until reconnect.
    }

    // Pipeline recovery — same as Stage 1.
    // Reset client state. TB pattern: client timeout + retry.
    // Our serial pipeline just resets — the next tick re-dispatches
    // (or returns 503 if no active connection).
    handlers.on_sidecar_close();
    if (commit_stage == .render) render_crash_fallback();
    else if (commit_stage != .idle) pipeline_reset();
}
```

**In-flight CALL during failover (TB pattern):**
When the active connection dies mid-CALL:
1. `sidecar_on_close` resets client state (call_state → idle)
2. `sidecar_on_close` switches active to standby
3. `pipeline_reset` clears the pipeline
4. Next tick: `process_inbox` re-enters commit_dispatch
5. If active is non-null: re-dispatches the CALL on the standby
6. If active is null: returns 503

The SidecarClient doesn't track connections. It gets reset on
close, then reused for the next CALL on whatever connection the
bus routes to. TB's client works the same way — timeout, reset,
resend.

**No re-dispatch in Stage 2** — pipeline_reset returns 503.
The NEXT request goes to the standby. The user who hit the crash
gets 503; the next user gets 200. This is acceptable for Stage 2
(serial pipeline). Stage 3 (concurrent) could re-dispatch.

#### SidecarClient — unchanged

The client calls `bus.send_message()`. The bus routes to
`connections[active]`. The client doesn't know about connections,
indices, or failover. It's a protocol state machine: submit CALL,
process RESULT. Same code as Stage 1.

One client is sufficient for Stage 2 (serial pipeline — one CALL
at a time). Stage 3 needs N clients (one per pipeline slot).

#### Invariants

```zig
// In server.invariants():

// Active connection must be ready.
if (server.sidecar_bus.active) |active| {
    assert(server.sidecar_connections_ready[active]);
}

// Pipeline in-flight requires an active connection (or native handlers).
if (App.sidecar_enabled and server.commit_stage != .idle) {
    // Active may be null if the connection just crashed
    // and on_close hasn't run yet. This is transient.
}

// Ready count <= connections count.
var ready_count: u8 = 0;
for (server.sidecar_connections_ready[0..bus.connections_count]) |r| {
    if (r) ready_count += 1;
}
assert(ready_count <= bus.connections_count);
```

#### Supervisor changes

Manages N children instead of one:
```zig
processes: [max_processes]Process,
count: u8,  // from --sidecar-count
```

Each process is independent — own spawn, reap, backoff.
main.zig wiring loops over all processes.

**What doesn't change:**
- Handler interface (same pure functions)
- Pipeline (serial, one commit_stage)
- State machine, storage, WAL, auth
- Wire format, CALL/RESULT protocol
- Fuzzers (test one connection — behavior is the same)

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
- SQLite transactions serial but prefetch + render overlap
- N SidecarClients (one per pipeline slot)

## Implementation order

1. ~~**Process spawning**~~ ✓ DONE — supervisor.zig, `--` CLI
2. ~~**Recovery sim tests**~~ ✓ DONE — 10 tests
3. **Callback signature** — on_frame_fn and on_close_fn gain
   connection_index parameter. Single-connection callers pass 0.
   This is the foundation — everything else depends on it.
4. **Multi-connection bus** — connections array, active index,
   per-slot accept, pool sizing for N, set_active(index),
   send_message routes to connections[active]
5. **Server per-connection state** — sidecar_connections_ready[N],
   sidecar_on_frame/on_close with index, set_active on READY/failover
6. **Supervisor N children** — processes array, --sidecar-count
7. **Hot standby sim tests** — two SimSidecars on two slots.
   Kill A, next request hits B. Verify no 503 during failover.
8. **Concurrent pipeline** (separate plan) — Stage 3
9. **Round-robin dispatch** — Stage 3

Note: SidecarClient is UNCHANGED for Stage 2. It calls
bus.send_message() which routes to connections[active].
The client is a protocol state machine, not a routing layer.

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

## Resource comparison

| | Tiger_web (4 sidecars) | Industry (4 Node servers) |
|---|---|---|
| RAM | ~210MB | ~2.1GB |
| Cores | 5 | 8 (4 servers + PG + Redis + Nginx + PgBouncer) |
| Throughput | ~100K req/s | ~20K req/s |
| Tools | 1 binary + 4 node | 7 services |
| Failover | <1ms (already connected) | 5-30s (health check + drain) |
| Deploy | `--sidecar-count=4` | Kubernetes manifest |
| Handler changes | None | None |

## Dependencies

| Dependency | Required for |
|---|---|
| Supervisor | All stages ✓ DONE |
| Recovery sim tests | Stage 1 ✓ DONE |
| Callback connection index | Stage 2 (foundation) |
| Multi-connection bus | Stage 2 |
| Server per-connection state | Stage 2 |
| SidecarClient pairing | Stage 2 |
| Concurrent pipeline | Stage 3 |
