# Connection scalability — DONE

## Summary

Callback-driven execution model implemented (TB pattern). All 6
optimizations from the original plan evaluated. Zero connection
scanning in the tick loop. 202/202 tests pass.

## What was implemented

### 1. Callback-driven connections — DONE
Connections dispatch work via on_ready_fn/on_close_fn callbacks.
recv_callback → parse HTTP → dispatch pipeline immediately.
send_complete → re-submit recv (keep-alive) or do_close.
Removed: process_inbox, flush_outbox, continue_receives,
update_activity, close_dead. tick() is periodic-only.

### 2. Send fast-path — DONE
submit_send tries send_now (synchronous) before async epoll send.
Small responses complete without a kernel round-trip.

### 3. Kernel timeouts — DONE
TCP_USER_TIMEOUT (90s) handles idle HTTP connections. Removed
timeout_idle scanning. Sidecar timeouts remain tick-driven
(only scans pipeline_slots_max entries, not all connections).

### 4. Suspended connection queue — DONE
When no pipeline slot is available, connection is suspended.
resume_suspended called from tick (TB's resume_receive pattern).

### 5. Deferred callback queue — REVERTED
Tested TB's deferred queue pattern. Adds latency on epoll because
callbacks wait for the full batch to be collected. Direct callback
execution is correct for epoll (events processed sequentially).
Add back when migrating to io_uring where batch collection is
required by the kernel ring buffer model.

### 6. Zero-copy recv — SKIPPED
TB uses MessagePool for shared buffer management. Our recv_buf is
a fixed [8192]u8 embedded in the connection struct. Zero-copy would
require MessagePool which is a separate, larger change.

## Throughput (measured 2026-04-04, clean system, 200K requests)

| Mode | c=32 | c=64 | c=128 |
|---|---|---|---|
| Native Zig | 73K | 75K | 72K |
| 2 sidecars | 25K | 25K | 25K |

Callback model is 32% faster than tick model for sidecar (25K vs 19K
on clean system comparison). Native is equivalent (~72K both).

## Remaining bottleneck

>128 connections: throughput drops from connection buffer memory
pressure. Each connection embeds 270KB (8KB recv + 256KB send).
512 connections = 135MB, exceeding L3 cache.

Fix: MessagePool (TB pattern). Shared buffer pool, connections hold
pointers not arrays. TB's message_pool.zig is 343 lines, isolated
from consensus — copyable. Defer until >128 connections is needed.

## Lessons learned

1. **Orphaned processes inflate benchmarks by up to 8×.** npx spawns
   process trees. Always verify zero orphans. Process groups (pgid=0)
   prevent orphans in production. Use scripts/loadtest.sh.

2. **hey needs 200K+ requests at high concurrency.** Short runs show
   false collapse from keep-alive reconnection overhead.

3. **Deferred callbacks hurt epoll, help io_uring.** TB's pattern is
   for io_uring's batch completion model. Epoll processes events
   sequentially — deferring adds unnecessary latency.

4. **SimIO needs timestamp-based completions.** ready_at = current_tick + 1
   prevents infinite cascading when callbacks submit new IO. TB bounds
   this with packet timestamps in their packet_simulator.

5. **Query cache provides zero benefit on SQLite.** SQLite's page cache
   serves in-memory reads in microseconds. Adding a cache in front
   adds hash+compare+memcpy overhead that matches or exceeds the
   query cost.
