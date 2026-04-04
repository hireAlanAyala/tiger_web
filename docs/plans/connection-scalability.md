# Connection scalability — event-driven connection handling

## Problem

Throughput caps at ~60-80K req/s and collapses above 128 connections.
The tick loop scans ALL connection slots every tick — `flush_outbox`,
`continue_receives`, `update_activity`, `timeout_idle`, `close_dead`
each iterate the full array. At 512 connections, per-tick scan overhead
dominates (4.4K req/s vs 66K at 32 connections).

TigerBeetle avoids this: callbacks process connections directly,
only active connections drive work, kernel handles timeouts. TB's
architecture scales to thousands of connections.

## Measured (2026-04-04)

| Connections | max=128 | max=512 |
|---|---|---|
| 32 | 66K | 66K |
| 64 | 66K | 66K |
| 128 | 129K* | 42K |
| 256 | — | 4.8K |
| 512 | — | 4.4K |

*128K at max=128 is artificial — hey reuses connections efficiently
against a resonant pool size. Stable throughput is 60-80K.

## TB audit findings (6 divergences)

### 1. Active connection set — skip idle connections

**TB:** Only connections with active IO operations drive events.
No "scan all" pass. Replica connections indexed by `replicas[]`
(O(1) lookup). Inbound accepts lazy — one pending at a time.

**Us:** `flush_outbox`, `continue_receives`, `timeout_idle`,
`close_dead` each iterate ALL connections regardless of state.
A `.free` connection is checked 4× per tick for nothing.

**Fix:** Track active connections in a bitfield or linked list.
Tick functions only iterate active connections. When a connection
transitions to `.free`, remove from active set. When accepted,
add to active set.

**Impact:** Eliminates O(max_connections) scan per tick. At 512
connections with 32 active, scan drops from 4×512=2048 checks
to 4×32=128.

**Complexity:** Low. Add `active_connections: u128` bitfield (or
`[max_connections/64]u64` for larger pools). Set/clear bits on
state transitions. Iterate set bits instead of full array.

### 2. Recv processing in callbacks

**TB:** `recv_callback()` drains the recv buffer immediately —
calls `recv_buffer_drain()` which extracts complete messages and
re-submits recv. No waiting for the next tick. Multiple messages
per IO event.

**Us:** `recv_callback` marks "data received." The tick calls
`continue_receives` → `try_parse_request` which parses one request.
If the connection received N bytes containing M messages, we
process 1 per tick, taking M ticks total.

**Fix:** Move HTTP parsing into `recv_callback`. When data arrives,
parse immediately. If a complete request is found, mark the
connection `.ready`. Re-submit recv for pipelined requests.

**Impact:** Reduces per-request latency by up to 10ms (one tick
interval). Under load with HTTP pipelining, processes N requests
per IO event instead of N per N ticks.

**Complexity:** Medium. Changes the invariant "all parsing happens
in tick." Need to ensure sim tests still work — SimIO controls
when callbacks fire, so determinism is preserved. The connection
state machine stays the same; only WHERE parsing happens changes.

### 3. Send fast-path (synchronous send_now loop)

**TB:** `send()` tries `send_now()` (synchronous non-blocking
sendto) in a loop, draining the entire send queue without going
through epoll. Only falls back to async send if the socket would
block. Avoids a kernel round-trip per send.

**Us:** We submit one async send via epoll and wait for the
callback. Each response requires: submit → epoll_wait → callback
→ check result. Two kernel crossings per response.

**Fix:** After rendering the response, try `posix.send()` directly.
If it succeeds (likely for small responses), the send is done —
no epoll submission, no callback, no kernel wait. Only fall back
to async send on EAGAIN.

**Impact:** Saves ~5µs per response (one kernel round-trip). At
60K req/s, that's 300ms of CPU per second. May push throughput
past 80K.

**Complexity:** Low. `IO.send_now()` already exists (used by
message bus). Add fast-path in connection send logic: try sync
first, async only on EAGAIN.

### 4. Kernel timeouts instead of tick scanning

**TB:** Uses TCP `user_timeout` (kernel-level) and `keepalive`
for idle connection detection. No application-level timeout
scanning. The kernel handles it — when a connection times out,
the next recv/send returns an error, which the callback handles.

**Us:** `timeout_idle()` iterates ALL connections every tick,
comparing `last_activity_tick` against the current tick. This is
O(max_connections) per tick for a check that fires rarely.

**Fix:** Set `TCP_USER_TIMEOUT` on accepted connections (we already
set keepalive in `set_tcp_options`). Remove `timeout_idle()` from
the tick loop. When a timed-out connection's next recv fails, the
callback handles the close.

**Impact:** Eliminates one full connection scan per tick. Combined
with #1, removes most per-tick scanning overhead.

**Complexity:** Low. Add one `setsockopt` call in `set_tcp_options`.
Remove `timeout_idle` and `update_activity` from tick. Handle
timeout errors in recv/send callbacks (already done — callbacks
close on error).

**Caveat:** Sidecar Unix sockets don't support TCP_USER_TIMEOUT.
Sidecar timeouts need a different mechanism (existing tick-based
check is fine for the small number of sidecar connections).

### 5. Deferred callback queue

**TB:** IO completions are pushed to a `self.completed` linked
list, then drained in a loop. This prevents re-entrancy — a
callback that submits new IO won't have its completion processed
mid-drain. Predictable execution order.

**Us:** Callbacks fire directly from `execute()` during `run_for_ns`.
A callback that submits new IO could have its completion processed
in the same `epoll_wait` batch. Re-entrancy is possible.

**Fix:** Queue completions during `epoll_wait`, drain after the
loop. Each completion callback runs to completion before the next
starts.

**Impact:** Prevents subtle re-entrancy bugs. No throughput change
expected, but correctness improvement.

**Complexity:** Medium. Need a completion queue (linked list of
Completion structs). Change `execute()` to push instead of
calling callback. Add drain loop after `epoll_wait`.

### 6. Zero-copy message passing

**TB:** When recv reads exactly one complete message at buffer
offset 0, the message pointer is swapped — the recv buffer
becomes the message, and a fresh buffer is assigned for the next
recv. No memcpy.

**Us:** HTTP requests are always parsed from the connection's
fixed recv_buf. The parsed data (path, body pointers) references
into this buffer. No copy needed for parsing, but we can't swap
buffers because the recv_buf is embedded in the Connection struct
(not a pointer).

**Fix:** Not applicable in current architecture. Our recv_buf is
a `[8192]u8` array field, not an allocatable buffer. Zero-copy
would require pool-allocated recv buffers (like TB's MessagePool).
This is a larger change — defer unless recv memcpy shows up in
profiling.

**Impact:** Negligible. HTTP requests are small (<8KB). The copy
is not in the hot path — parsing is.

**Complexity:** High. Requires MessagePool-style buffer management.
Not worth it for HTTP.

## Priority order

| # | Change | Impact | Complexity | Dependencies |
|---|--------|--------|------------|-------------|
| 1 | Active connection set | High | Low | None |
| 3 | Send fast-path | Medium | Low | None |
| 4 | Kernel timeouts | Medium | Low | None |
| 2 | Recv in callbacks | High | Medium | Affects sim tests |
| 5 | Deferred callback queue | Low (correctness) | Medium | None |
| 6 | Zero-copy recv | Negligible | High | MessagePool |

**Recommended order:** 1 → 3 → 4 (three low-complexity changes
that eliminate scanning and reduce syscalls). Then 2 if latency
matters. Skip 5 and 6 unless profiling shows need.

## Verification

After each change:
```bash
./zig/zig build unit-test
./zig/zig build test
./zig/zig build fuzz -- smoke
```

After all changes, re-benchmark:
```bash
# Build ReleaseSafe, test at 128 and 512 connections
# Target: stable 100K+ at 128 conn, no collapse at 512
```

## Relationship to sidecar optimization

These changes improve native throughput, which is the ceiling for
sidecar throughput. 2 sidecars reached 97% of native (55K vs 57K).
If native moves to 150K, 2 sidecars should reach ~145K.

The sidecar coordination overhead (~33µs/RT) is independent of
connection handling. These changes and sidecar optimization are
orthogonal — both can proceed independently.
