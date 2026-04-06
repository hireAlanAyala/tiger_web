# Decision: 1-CALL sidecar protocol

## Context

The sidecar protocol used 4 separate CALL/RESULT exchanges per
HTTP request (route, prefetch, handle, render). Each frame costs
~2µs of CRC32 + memcpy + epoll overhead. At 10+ frames per request,
the single-threaded Zig event loop was saturated processing frames
rather than doing useful work.

## Benchmark results

128 connections, 50K requests, ReleaseSafe, mixed workload.

| Config | 4-CALL (before) | 1-CALL (after) | Change |
|---|---|---|---|
| Sidecar 1 slot | 12K req/s | 17K req/s | +42% |
| Sidecar 4 slots | 24K req/s | 32K req/s | +33% |
| Sidecar 8 slots | 30K req/s | 36K req/s | +20% |
| Fastify (reference) | 49K req/s | — | — |
| Native Zig (ceiling) | 66K req/s | — | — |

## Design

One CALL "request" per HTTP request. The TS sidecar runs route +
prefetch (with QUERY sub-calls for db.query) + handle + render
internally. Returns everything in one RESULT frame.

### Combined RESULT format

```
[operation: u8][id: 16 bytes LE][event_body_len: u16 BE][event_body]
[status_len: u16 BE][status][session_action: u8]
[write_count: u8][writes...]
[html to end of frame]
```

### Zig handler changes (sidecar_handlers.zig)

handler_route submits the single CALL and on completion parses the
combined RESULT, caching status, writes, and HTML. The other three
handlers (handler_prefetch, handler_execute, handler_render) read
from the cache — no IPC. The server's 4-stage pipeline is unchanged;
only the first stage does IPC.

### Frame count reduction

Before: 10+ frames per request (4 CALLs + 4 RESULTs + QUERY sub-RTs).
After: 2 + 2N frames per request (1 CALL + N QUERYs + N QUERY_RESULTs + 1 RESULT).
Typical request with 1 prefetch query: 4 frames (was 12).

## Remaining gap to Fastify

The 1-CALL protocol closed the gap from 40% to 26%. The remaining
overhead is:
- QUERY sub-protocol: each db.query() in TS prefetch is still a
  unix socket round trip (~10µs per query)
- 1 CALL + 1 RESULT framing: ~4µs per request
- Single-threaded event loop: more slots help but can't exceed
  one core's frame processing capacity

Future options to close further:
- TS-side SQLite reads (eliminate QUERY sub-protocol entirely)
- Native codegen from annotations (eliminate sidecar for CRUD)
- Embedded JS engine (eliminate IPC)

## Multiplexing experiment (N slots, 1 process)

Tested whether one TS process could handle multiple concurrent
requests via Node.js async interleaving, eliminating the need for
N processes.

| Config | Throughput |
|---|---|
| 1 process, 1 slot | 14K req/s |
| 1 process, 4 slots (multiplexed) | 15K req/s |
| 1 process, 8 slots (multiplexed) | 16K req/s |
| 8 processes, 8 slots | 36K req/s |

**Result: multiplexing doesn't help.** The TS process interleaves
requests at `await db.query()` points, but the Zig server processes
the resulting QUERY frames sequentially (single-threaded event loop).
Both sides are single-threaded — async interleaving on the TS side
doesn't create real parallelism.

The multi-process model wins because each TS process runs on a
separate CPU core. The TS compute (route + handle + render) happens
truly in parallel across processes. The Zig server processes their
result frames in epoll batches — sequential per frame, but the TS
work between frames happened concurrently.

Multiplexing is available via `-Dpipeline-slots=N` with
`-Dsidecar-count=1` for memory-constrained deployments (1 process
instead of N), but it trades throughput for memory savings.

**To close the remaining gap to Fastify (49K), the options are:**
- Eliminate QUERY sub-protocol (TS reads SQLite directly, no RT)
- Multi-threaded Zig server (parallelize native frame processing)
- Native codegen from annotations (eliminate sidecar for CRUD)

## What changed

- `adapters/call_runtime.ts`: new `dispatchRequest` function
- `sidecar_handlers.zig`: rewritten for 1-CALL pattern
- `sim_sidecar.zig`: `build_request_result` for test sidecar
- Protocol tests: comptime layout assertions, round-trip tests,
  parser rejection tests, content verification sim tests
