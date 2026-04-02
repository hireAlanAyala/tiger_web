# Background Dispatch — @timeout + @background

> Handler timeout contract: the user declares limits, the
> framework enforces them, the supervisor recovers from violations.

## What this is

Per-handler `@timeout` annotation. `@background` annotation for
work that doesn't block the HTTP response. Scanner-enforced at
build time. Server-enforced per-CALL at runtime.

## The contract

**Route handlers** are pure functions (read DB, compute, return).
Framework provides default timeout (5s). Overridable with `@timeout`.

**Background handlers** do arbitrary work (image processing, API
calls, report generation). `@timeout` is mandatory — scanner
rejects `@background` without it.

```typescript
@route("POST", "/products")
export function createProduct(ctx) { ... }  // default 5s

@background
@timeout(300_000)  // mandatory — scanner rejects without this
export function generateReport(ctx) { ... }
```

## Comptime enforcement (TB pattern)

Scanner generates comptime constants in handlers.generated.zig
— not a manifest file. The timeout is a comptime constant on the
handler. The server reads it at comptime. The compiler IS the
enforcement. If the timeout is missing, the code doesn't compile.

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
5. `@background` annotation + background CALL dispatch
6. Supervisor health bound from max(all timeouts)

## Dependencies

| Dependency | Required for |
|---|---|
| Annotation scanner @timeout | All |
| handlers.generated.zig timeout constants | Server enforcement |
| Background dispatch in server | @background annotation |
| Supervisor health check | Stuck process recovery |

## Related

- docs/internal/decision-handler-timeout-contract.md
- docs/internal/architecture-sidecar-seams.md
