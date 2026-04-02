# Handler Timeout — @timeout

> The user declares limits, the framework enforces them,
> the supervisor recovers from violations.

## What this is

Per-handler `@timeout` annotation. Scanner-enforced at build time.
Server-enforced per-CALL at runtime. Default 5s for all handlers,
overridable per handler.

No `@background` annotation — the CALL/RESULT protocol is
synchronous (every CALL gets a RESULT). Background work is a
handler that writes to a table and returns immediately. The SSE
connection pushes the result when a later CALL processes the queue.
No protocol change needed.

## The contract

```typescript
@route("POST", "/products")
export function createProduct(ctx) { ... }  // default 5s

@route("POST", "/reports/generate")
@timeout(30_000)  // heavy query, needs more time
export function generateReport(ctx) { ... }
```

All handlers get the 5s default. Heavy handlers override with
`@timeout`. The scanner generates comptime constants. The server
enforces per-CALL. The compiler rejects invalid values.

## Comptime enforcement (TB pattern)

Scanner generates comptime constants in handlers.generated.zig
— not a manifest file. The timeout is a comptime constant on the
handler. The server reads it at comptime. The compiler IS the
enforcement.

Same pattern as routes.generated.zig — one source of truth, zero
runtime trust.

## Log format

Today (global 5s timeout):
```
sidecar: response timeout (500 ticks, stage=prefetch, op=create_product), terminating
```

With per-handler @timeout:
```
sidecar: handler "createProduct" timed out (5000ms limit, stage=prefetch, op=create_product)
```

## Supervisor health check

Derived from max(all handler timeouts) at comptime. If a process
runs longer than max_timeout + grace without any CALL completing,
supervisor kills it. No coupling to server — the bound comes from
the generated code, not a signal.

## Implementation order

1. `@timeout(ms)` annotation support in scanner
2. Scanner generates timeout_ms comptime constant per handler
3. Server reads per-handler timeout from generated code
4. Server enforces per-CALL timeout (replaces global 5s)
5. Supervisor health bound from max(all timeouts)

## Dependencies

| Dependency | Required for |
|---|---|
| Annotation scanner @timeout | All |
| handlers.generated.zig timeout constants | Server enforcement |
| Supervisor health check | Stuck process recovery |

## Related

- docs/internal/decision-handler-timeout-contract.md
- docs/internal/architecture-sidecar-seams.md
