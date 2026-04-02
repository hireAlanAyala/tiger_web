# Decision: Handler Timeout Contract

## The contract

Every handler has a declared timeout. The framework enforces it.
The user declares, the framework enforces. Neither side trusts
the other. Both are explicit.

**Route handlers** are pure functions (read DB, compute, return).
The framework provides a default timeout (5 seconds). The user
doesn't need to think about it. Overridable with `@timeout`.

**Background handlers** do arbitrary work (image processing, API
calls, report generation). `@timeout` is mandatory — the
annotation scanner rejects `@background` without it.

```typescript
@route("POST", "/products")
export function createProduct(ctx) { ... }  // default 5s

@background
@timeout(300_000)  // mandatory — scanner rejects without it
export function generateReport(ctx) { ... }
```

## Why

TB principle #3 (boundedness): put a limit on everything. This
extends boundedness from framework internals (loops, queues,
buffers) to user code. The handler IS a bounded operation.

The timeout IS the documentation. `@timeout(5000)` tells the
next developer: this handler must complete in 5 seconds. No
wiki page needed.

## What exists today

- Server-side 5s timeout on all request-path CALLs
  (timeout_sidecar_response in server.zig)
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

- `@background` annotation + background dispatch
- Per-handler `@timeout` (overriding the 5s default)
- Scanner generates timeout constants in handlers.generated.zig
- Supervisor health bound derived from generated comptime constants
- Per-CALL timeout enforcement (currently global 5s)

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
