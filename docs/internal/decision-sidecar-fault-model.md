# Decision: Sidecar Fault Model

## The sidecar is a presentation layer with two states

Connected or disconnected. No partial states, no retries, no
graceful degradation of the sidecar itself. It works or it gets
killed and restarted. The hypervisor owns restart timing.

## Crash safety per pipeline stage

| Stage | Crash during | Safe to retry? | Why |
|---|---|---|---|
| .route | CALL "route" | Yes | Stateless |
| .prefetch | CALL "prefetch" | Yes | Read-only |
| .prefetch | CALL "handle" | Yes | Sidecar returns writes as DATA. Server applies them. If crash before RESULT, server never got the writes. |
| .handle | SM commit (SQL) | N/A | Synchronous, no sidecar involvement |
| .render | CALL "render" | NO | Writes already committed. Retry re-executes handle → duplicate writes. |

The ONLY dangerous crash is during `.render`. Everything before
`.handle` is safe. `.handle` is synchronous. `.render` is the one
async stage after writes.

## Render crash response

Send 200 with degraded HTML: "Operation completed. Refresh for
full page." This is correct — the operation succeeded and the
server tells the user. A 503 would be a lie (the service completed
the work). For Datastar/HTMX, the degraded HTML is swapped into
the DOM, which is better than a silent failure (no error handler
configured) or a misleading "service unavailable."

Never retry the pipeline after writes are committed.

## Binary state — no retries

The server checks `sidecar_connected` before routing. If false,
every request gets 503 "service unavailable" immediately. No retry
counter, no backoff, no queuing. The hypervisor restarts the
sidecar; the bus re-accepts via `tick_accept`; the READY handshake
completes; `sidecar_connected = true`. Requests flow again.

Why no retries: retry logic is a state space explosion (count,
backoff, mutation safety, queue management) that buys nothing if
the hypervisor restarts the sidecar in milliseconds.

## Kill on protocol violation

Corrupt frame, request_id mismatch, invalid READY frame, query
limit exceeded → SIGKILL the sidecar process using the PID from
the READY handshake. Not SIGTERM — don't trust a broken process
to clean up. The hypervisor restarts it from clean state.

A GC pause does NOT cause a protocol violation. It causes a
response timeout (separate concern). These have different kill
triggers: violation = broken code, timeout = degraded environment.

### Why SIGKILL is always correct

Every error on a unix domain socket means one of:

1. **Kernel bug / hardware fault** — machine is broken. Restart
   won't help, but SIGKILL is harmless. Hypervisor restart
   counter trips, escalates to human.

2. **Sidecar memory corruption** — V8 heap corruption (native
   addon bug, JIT bug, prototype pollution). Restart WILL help
   — fresh address space, clean heap. Not killing risks silent
   data corruption (wrong writes applied to database).

3. **Sidecar code bug** (e.g., sendFrame builds a bad frame) —
   restart won't help (same code, same bug). But SIGKILL is
   harmless — hypervisor restart counter trips after repeated
   failures, escalates to human.

You can't distinguish case 2 from case 3 without debugging.
Case 2 is the one where SIGKILL + restart IS the recovery.
The cost of unnecessary SIGKILL: 500ms-2s of 503s. The cost
of not killing a corrupted process: wrong writes applied to
the database. Safety > availability.

### Why "drop bad frame, stay connected" is impossible

We considered having the Connection survive CRC errors by
skipping the bad frame and continuing. This requires finding
the next frame boundary after a CRC failure. But the protocol
uses length-prefixed framing with no sync markers. After a CRC
failure, the declared length can't be trusted — it might be the
corrupted field. Skipping `len` bytes could land in the middle
of the next frame. Every subsequent read is garbage.

Adding sync markers (HDLC-style flag bytes between frames)
would make recovery possible but adds wire format complexity
and escape byte handling in both Zig and TS. For unix domain
sockets where CRC errors are near-impossible, the trade-off
isn't worth it.

## Handshake before routing

The sidecar sends a READY frame after connecting:
`[tag: 0x20][version: u16 BE][pid: u32 BE]`

The server validates the version and stores the PID. Only after
valid READY does `sidecar_connected = true`. This prevents the
race between restart and first request.

No startup health-check CALL needed. The first real request IS
the health check. If it fails, same recovery path: 503 + kill +
restart.

## Writes as data — trust boundary

The sidecar never touches the database. Handle() returns:
`[status][session_action][write_count][writes...]`

Each write is `[sql][params]`. The server applies them atomically
via `execute_writes()` inside a transaction. A compromised sidecar
can only produce bad write requests, which the server can validate
and reject. The WAL records what the server applied, not what the
sidecar requested.

This is the trust boundary. The sidecar is outside it. The server
+ storage are inside it.

## Writes-as-data expressiveness ceiling

The sidecar can express any SQL statement with parameters. This
covers: INSERT, UPDATE by ID, DELETE by ID, bulk UPDATE/DELETE
with WHERE clauses.

The sidecar CANNOT read results of its own writes within a single
handle() call. It cannot do "insert row, read back computed
column, use that value in next write."

For multi-step transactions: break into multiple CALL cycles.
Each is independently atomic. Chain via client requests (POST
creates resource → redirect → GET reads committed state). This
is how web apps naturally work.

Pre-generate IDs during route (UUIDs in `msg.id`). Don't depend
on auto-increment IDs that require a round-trip.

Document for users: "one CALL cycle, one atomic write set.
Pre-generate IDs during route. Chain operations via client
requests, not multi-step transactions in a single handler."

## Response timeout

5-second deadline (500 ticks at 10ms/tick). If the pipeline has
been pending (waiting for sidecar RESULT) for this long, SIGKILL
the sidecar. Checked every tick in `timeout_sidecar_response`.
Only fires when `is_handler_pending()` is true — the .handle
stage is synchronous and never triggers this.

Uses the existing recovery path: kill → on_close → disconnect →
503 or render fallback.

## Responsibility boundaries

| Component | Responsibility |
|---|---|
| Connection | Terminates on socket error (3-phase) |
| MessageBus | Re-accepts on reconnect (tick_accept) |
| SidecarClient | Protocol state machine (CALL/RESULT, request_id) |
| SidecarHandlers | Pipeline dispatch, prefetch phase sequencing |
| Server | Binary state, 503, render fallback, kill, handshake |
| Sidecar process | READY handshake, handler execution, returns data |
| Hypervisor | Restarts sidecar after SIGKILL |

## Single sidecar is acceptable

One sidecar process, one bus, one connection. The sidecar's
availability IS the system's availability for sidecar-routed
operations. Multiple instances would require routing, shared
state, distributed transactions — violates Safety, Determinism,
Boundedness simultaneously.

The hypervisor restart time is the recovery time. Keep it fast
(Node.js cold start ~500ms-2s).
