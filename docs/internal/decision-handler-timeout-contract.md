# Decision: Handler Timeout Contract

## The contract

Every handler has a declared timeout. The framework enforces it.
The user declares, the framework enforces. Neither side trusts
the other. Both are explicit.

All handlers get a 5s default timeout. Heavy handlers override
with `@timeout(ms)`. The scanner generates comptime constants.
The server enforces per-CALL. The compiler rejects invalid values.

```typescript
@route("POST", "/products")
export function createProduct(ctx) { ... }  // default 5s

@route("POST", "/reports/generate")
@timeout(30_000)  // heavy query, needs more time
export function generateReport(ctx) { ... }
```

No `@background` annotation — the CALL/RESULT protocol is
synchronous (every CALL gets a RESULT). Background work is a
handler that writes to a table and returns immediately. The SSE
connection pushes the result when a later CALL processes the queue.
No protocol change needed.

## Why

TB principle #3 (boundedness): put a limit on everything. This
extends boundedness from framework internals (loops, queues,
buffers) to user code. The handler IS a bounded operation.

The timeout IS the documentation. `@timeout(5000)` tells the
next developer: this handler must complete in 5 seconds. No
wiki page needed.

## Log format

Today (global 5s timeout):
```
sidecar: response timeout (500 ticks, stage=prefetch, op=create_product), terminating
```

With per-handler @timeout (future):
```
sidecar: handler "createProduct" timed out (5000ms limit, stage=prefetch, op=create_product)
```

The handler name and declared limit come from comptime constants
in handlers.generated.zig. The developer sees exactly what timed
out, what the limit was, and where in the pipeline it happened.
No "502 Bad Gateway" from three layers of proxies.

## What exists today

- Server-side 5s timeout on all request-path CALLs
  (timeout_sidecar_response in server.zig)
- Timeout log includes stage and operation (not handler name yet)
- Supervisor reaps dead processes, respawns with backoff
- Hot standby failover (no 503 during restart)

## Comptime enforcement (TB pattern)

The scanner generates comptime constants in handlers.generated.zig
— not a manifest file. The timeout is a comptime constant on the
handler. The server reads it at comptime. No manifest to get stale.
No runtime parsing. The compiler IS the enforcement. If the timeout
is missing, the code doesn't compile.

We already do this for routes — routes.generated.zig is generated
Zig, not JSON. @timeout follows the same pattern: one source of
truth, zero runtime trust.

The supervisor derives its health bound from the generated code
at comptime: `max(all handler timeouts) + grace`. No coupling to
the server — the bound is structural, not behavioral.

## What's deferred

- Per-handler `@timeout` (overriding the 5s default)
- Scanner generates timeout constants in handlers.generated.zig
- Supervisor health bound derived from generated comptime constants
- Per-CALL timeout enforcement (currently global 5s)
- See docs/plans/handler-timeout.md

## The stuck process gap

If a sidecar is stuck (can't detect closed socket), the process
stays alive but unresponsive. The supervisor sees it as running
(waitpid returns 0). No automatic recovery.

This is acceptable today because:
- Hot standby takes over immediately (no 503)
- The 5s timeout closes the connection (server recovers)
- The stuck process wastes memory but does no harm
- Operational restart handles it

When @timeout is per-handler, the supervisor can derive a health
bound: max(all timeouts) + grace. If no CALL completes within
that window, the process is stuck — kill and respawn.
