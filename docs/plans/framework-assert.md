# Plan: Framework-provided assert — one call, context determines behavior

## Context

TB crashes on assertion failure — a database can't serve corrupt data.
A web framework can't crash on a handler bug — one bad request shouldn't
kill the monolith. But the assertion itself (documenting the invariant)
is identical. The developer writes `assert(quantity > 0)` in both systems.

Today our `assert()` in `types.generated.ts` throws unconditionally. A
throw in a handler crashes the sidecar process, killing all connections.
This is what happened with `esc(undefined)` — one handler bug took down
the entire sidecar.

## Design

One `assert` function. The context determines the response to violation:

| Context | On failure | Why |
|---|---|---|
| Test | Collect, keep running, report at end | Need all failures |
| Dev (handler) | Crash with stack trace | Fast feedback for developer |
| Prod (handler) | Log + return error status, keep serving | Blast radius = one request |

The developer never chooses between assert types. They write `assert(x)`
and the framework handles recovery based on where the code is running.

### How it works

The handler always throws on assertion failure. The **dispatch** decides
whether to catch it:

```typescript
// Dev: handler throws → propagates → sidecar crashes → developer sees stack trace
handleFn(ctx, db);

// Prod: handler throws → caught → logged → error status returned → sidecar lives
try { handleFn(ctx, db); } catch (e) { log(e); return "storage_error"; }
```

One line difference in dispatch. Zero difference in handler code.

In tests, the test harness is the dispatch. It catches and collects.
Same pattern — handler throws, surrounding context decides response.

### Not a runtime flag

Dev/prod is NOT `if (process.env.NODE_ENV === 'production')` checked
per-assert. It's structural — the dispatch either wraps in try/catch
or doesn't. The handler code is identical in both modes.

## Implementation

### Step 1: Wrap handler calls in dispatch try/catch

In `adapters/typescript.ts`, the generated dispatch calls:
```typescript
const status: string = handleFn(ctx, db);
```

Wrap with:
```typescript
let status: string;
try {
  status = handleFn(ctx, db);
} catch (e) {
  console.error(`[sidecar] handler error in ${routeOperation}:`, e);
  status = "storage_error";
}
```

Same for route, prefetch, and render phases. Every handler call site
gets a try/catch. Marks: `log.mark.warn("handler threw: {operation}")`.

### Step 2: Dev mode — don't catch

Add `--dev` flag or `DEV=1` env var to the sidecar. In dev mode, the
try/catch is skipped — throws propagate, sidecar crashes, developer
sees the full stack trace in their terminal. This is the fast feedback
loop.

### Step 3: Test assert — collect and continue

The test harness provides its own assert that doesn't throw:
```typescript
function assert(ok: boolean, msg: string): void {
  if (ok) passed++; else { failed++; console.error("FAIL:", msg); }
}
```

This already exists in the integration test. No change needed. Tests
don't use the framework assert — they use the test assert. Different
context, different behavior, same developer intent.

### Step 4: Zig-side handler resilience

The Zig native pipeline calls handlers directly. If a handler panics
(assertion failure), the server crashes. For the native pipeline:
- Dev: crash is correct (same as TB)
- Prod: Zig doesn't have try/catch for panics. Use `@import("builtin").mode`
  to detect release builds. In release, validate inputs at the boundary
  and return error status before calling handler logic. This is already
  the TB pattern — validate at the boundary, trust inside.

## What this enables

- Handler bugs don't crash the sidecar in production
- Developers get immediate crash + stack trace in dev
- Tests collect all failures and report
- One `assert` call in handler code — no assert taxonomy
- Marks let sim tests verify error paths fire correctly

## What this does NOT change

- Framework assertions (`assert(params.len <= max)`) still crash.
  These are programming errors in the framework, not handler bugs.
- Scanner assertions (comptime) still fire at build time.
- The Zig native pipeline still panics on assertion failure in dev.
