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

The bus gains multi-connection support. It is a dumb pool — no
routing policy, no "active" concept. TB pattern: the bus manages
connections, the consumer (server) manages routing.

```zig
// connections array replaces single connection field
connections: [max_connections]Connection,
connections_count: u8,  // from options, set at init

// Pool sized for N connections:
// N recv messages + N * send_queue_max + 1 burst
const messages_max = connections_count * (1 + send_queue_max) + 1;
```

**Callback signatures gain connection index:**
```zig
// Before (single connection):
on_frame_fn: *const fn (*anyopaque, []const u8) void,
on_close_fn: ?*const fn (*anyopaque, CloseReason) void,

// After (N connections):
on_frame_fn: *const fn (*anyopaque, u8, []const u8) void,
on_close_fn: ?*const fn (*anyopaque, u8, CloseReason) void,
```

The connection index tells the server which connection sent the
frame or closed. Without this, READY handshake per-connection
and failover routing are impossible.

**tick_accept fills ALL empty slots:**
```zig
fn tick_accept(self: *Self) void {
    for (self.connections[0..self.connections_count]) |*conn, i| {
        if (conn.state == .closed and !self.accept_pending[i]) {
            self.accept_pending[i] = true;
            self.io.accept(self.listen_fd, &self.accept_completions[i], ...);
        }
    }
}
```

Current bus accepts one connection at a time. With N slots, multiple
sidecars might connect on the same tick (e.g., supervisor spawns 2).

**Bus interface additions:**
```zig
pub fn is_connection_ready(self, index: u8) bool;
pub fn send_to_connection(self, index: u8, msg, len) void;
pub fn terminate_connection(self, index: u8) void;
pub fn get_message(self) *Message;  // unchanged (shared pool)
pub fn unref(self, msg) void;       // unchanged
```

Stage 1 compatibility: `is_connected()`, `send_message()` etc.
delegate to connection[0] when connections_count == 1. No breaking
change for single-connection usage.

#### Server changes (routing + failover)

The server owns routing and failover. The bus doesn't know what
"active" means.

```zig
// Replace single bool with per-connection + active tracking
sidecar_active: ?u8 = null,           // which connection to dispatch to
sidecar_connections_ready: [max]bool,  // READY handshake complete per slot
```

**sidecar_on_frame(ctx, connection_index, frame):**
```zig
fn sidecar_on_frame(ctx, index: u8, frame: []const u8) void {
    if (!server.sidecar_connections_ready[index]) {
        // READY handshake for THIS connection
        validate_ready(frame) → sidecar_connections_ready[index] = true;
        if (server.sidecar_active == null) {
            server.sidecar_active = index;  // first ready = active
        }
        return;
    }
    // Normal frame: route to sidecar client
    handlers.process_sidecar_frame(frame, storage);
}
```

**sidecar_on_close(ctx, connection_index, reason):**
```zig
fn sidecar_on_close(ctx, index: u8, reason) void {
    server.sidecar_connections_ready[index] = false;
    if (server.sidecar_active == index) {
        // Active connection crashed — find standby
        server.sidecar_active = find_next_ready(server);
        // If null: no ready connections, 503 until reconnect
    }
    // Pipeline recovery: same as Stage 1
    if (commit_stage == .render) render_crash_fallback();
    else if (commit_stage != .idle) pipeline_reset();
}
```

#### SidecarClient per-connection pairing

The SidecarClient has one `call_state` — it tracks one in-flight
CALL at a time (serial pipeline). With N connections, the client
must know WHICH connection the CALL was sent on.

```zig
// Add to SidecarClient:
active_connection_index: ?u8 = null,
```

`call_submit` stores the index. `on_frame` validates the frame
came from the expected connection. `on_close` resets if the closed
connection was the one with the in-flight CALL.

One client is sufficient for Stage 2 (serial pipeline — one CALL
at a time). Stage 3 (concurrent pipeline) needs N clients.

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
4. **Multi-connection bus** — connections array, per-slot accept,
   pool sizing for N, send_to_connection(index), terminate_connection(index)
5. **Server per-connection state** — sidecar_connections_ready[N],
   sidecar_active index, sidecar_on_frame/on_close with index
6. **SidecarClient connection pairing** — active_connection_index
   field, reset on disconnect of paired connection
7. **Supervisor N children** — processes array, --sidecar-count
8. **Hot standby failover** — on_close switches active to standby.
   Sim test: kill A, next request hits B without 503.
9. **Concurrent pipeline** (separate plan) — Stage 3
10. **Round-robin dispatch** — Stage 3

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
