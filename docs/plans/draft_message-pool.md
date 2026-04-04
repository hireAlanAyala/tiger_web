# MessagePool — shared buffer pool for connection scaling

## Problem

Each connection embeds 270KB of buffers:
- `recv_buf: [8192]u8` — 8KB
- `send_buf: [262144]u8` — 256KB

At 128 connections: 34MB (fits in L3).
At 256 connections: 69MB (exceeds L3, cache thrashing).
At 512 connections: 135MB (throughput collapses to 6K req/s).

Most connections are idle — only ~32-64 are actively recv/send at
any tick. Idle connections hold 270KB for nothing.

## TB's solution

TB's `message_pool.zig` (343 lines) manages a stack of pre-allocated
buffers. Connections borrow a buffer when active, return it when done.
Memory scales with concurrency (active connections), not capacity
(total connections).

**File:** `/home/walker/Documents/personal/tigerbeetle/src/message_pool.zig`

**Dependencies (all trivially replaceable):**
- `vsr.Header` → replace with our frame header or remove
- `vsr.ProcessType` → remove (we have one process type)
- `vsr.Command` → remove (not needed for buffer pool)
- `stack.zig` → copy (generic LIFO, ~50 lines)
- `constants.zig` → use our own

**The pool stores:**
- Free list: stack of available buffers
- Each buffer: fixed-size byte array (their `message_size_max`)
- Reference counting: buffers returned to pool when ref drops to 0

## Design for Tiger Web

### Pool sizing

```
pool_size = active_connections_max × 2
         = pipeline_slots_max × 2 (native)
         = pipeline_slots_max × 4 (sidecar: recv + send per slot, overlapped)
```

At `pipeline_slots_max = 2`: pool holds 8 buffers = 2MB.
512 connections share 8 buffers. Connection struct drops to ~100 bytes.
512 × 100 bytes = 50KB metadata + 2MB pool = 2.05MB total.

### Buffer types

Two pools, different sizes:
- **recv_pool**: 8KB buffers (HTTP request, small)
- **send_pool**: 256KB buffers (HTML response, large)

Or one pool with the larger size (256KB), waste 248KB per recv.
TB uses one pool (all messages are the same size). We could too
if we reduce send_buf_max to 64KB (most responses are <10KB).

### Connection changes

```zig
// Before:
recv_buf: [8192]u8,
send_buf: [262144]u8,

// After:
recv_buf: ?*[recv_buf_max]u8,  // borrowed from pool, null when idle
send_buf: ?*[send_buf_max]u8,  // borrowed from pool, null when idle
```

**Borrow points:**
- `on_accept`: borrow recv_buf, submit_recv
- `recv_callback` (data arrived): already has recv_buf
- `set_response`: borrow send_buf, start sending

**Return points:**
- `send_complete` (keep-alive): return send_buf, keep recv_buf
- `do_close`: return both buffers

**Backpressure:** If pool is exhausted (all buffers in use), new
accepts wait. `maybe_accept` checks pool availability before
accepting. This is bounded backpressure — the pool size is the
concurrency limit, not the connection count.

## Implementation steps

1. **Copy TB files:**
   ```bash
   cp /home/walker/Documents/personal/tigerbeetle/src/message_pool.zig framework/
   cp /home/walker/Documents/personal/tigerbeetle/src/stack.zig framework/stdx/
   ```
   Surgical edits: remove vsr imports, replace with our types.

2. **Add pools to Server:**
   ```zig
   recv_pool: RecvPool,
   send_pool: SendPool,
   ```
   Initialize in Server.init, pass to connections via wire_connections.

3. **Change Connection buffers to pointers:**
   Replace embedded arrays with nullable pool buffer pointers.
   Update all `conn.recv_buf[...]` to `conn.recv_buf.?[...]`.

4. **Add borrow/return calls:**
   on_accept borrows recv. set_response borrows send.
   send_complete/do_close returns.

5. **Backpressure in maybe_accept:**
   Check `recv_pool.available() > 0` before accepting.

6. **Update SimIO:**
   Sim connections need pool-allocated buffers too. Or keep embedded
   buffers in sim (pool is a production optimization, sim doesn't
   need memory efficiency).

## Verification

- All tests pass with pool-allocated buffers
- Benchmark at 128, 256, 512 connections
- Target: stable throughput up to 512+ connections
- Memory: verify pool stays within budget
