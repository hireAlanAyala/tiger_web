# Plan: Framework-provided assert — dispatch catches, sidecar stays alive

## Status: Implemented

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

Handlers throw on assertion failure. The dispatch always catches.
No dev/prod modes. No flags. One code path.

| Layer | On failure | Why |
|---|---|---|
| Handler | Throws | Handler code uses `assert()` or `throw` naturally |
| Dispatch | Catches, logs, returns error status | One bad request doesn't kill the monolith |
| Test harness | Collects failures, reports at end | Need all failures, not just the first |

The developer sees the error in the server log with operation name and
stack trace. The sidecar stays alive. Other connections are unaffected.
The developer fixes the bug and refreshes. No restart needed.

No dev mode. "Crash in dev for fast feedback" adds a mode flag and a
conditional code path for marginal value — the log gives the same
stack trace without killing other connections.

## Implementation

### Step 1: Wrap handler calls in dispatch try/catch

In `adapters/typescript.ts`, every handler call site gets a try/catch.
Currently:

```typescript
const status: string = handleFn(ctx, db);
```

After:

```typescript
let status: string;
try {
  status = handleFn(ctx, db);
} catch (e) {
  console.error(`[sidecar] ${routeOperation} handle error:`, e);
  status = "storage_error";
}
```

Same for route, prefetch, and render phases:
- **route throws:** log, return "not found" to framework (no route matched)
- **prefetch throws:** log, fail the request
- **handle throws:** log, return "storage_error" status
- **render throws:** log, return empty HTML (error page)

### Step 2: Test assert stays separate

Tests use their own assert that collects failures:

```typescript
function assert(ok: boolean, msg: string): void {
  if (ok) passed++; else { failed++; console.error("FAIL:", msg); }
}
```

This already exists. No change. Tests don't use the framework assert —
they assert on HTTP responses (the system's observable contract).

### Zig native pipeline

Not applicable. Zig handler panics are programming bugs in the
framework, not handler validation errors. Zig handlers validate inputs
and return status — they don't assert on user input. Framework bugs
should crash (TB pattern). No try/catch equivalent needed.

## What this enables

- Handler bugs don't crash the sidecar
- Developer sees full stack trace in server log
- No restart needed — fix and refresh
- Other users unaffected by one handler's bug
- One code path — no dev/prod modes, no flags

## What this does NOT change

- Framework assertions (Zig `assert()`) still crash — programming bugs
- Scanner assertions (comptime) still fire at build time
- Handler code unchanged — `assert()` and `throw` work naturally
- Test assertions unchanged — collect and report
