# Plan: Worker Primitives — `db.after()` + `// [worker]`

## Context

The state machine is the pure boundary — deterministic, fuzz-tested,
no side effects. But real apps need side effects: charge payments,
send emails, call external APIs, resize images, run ML models.

Today the worker is a hand-written HTTP client (`worker.zig`). Each
new side effect requires a new worker or modifying the existing one.
No framework support, no annotations, no fuzz coverage of the
scheduling path.

## Design

Two primitives. One schedules work (inside the state machine). One
executes it (outside the state machine). Both live in the same
handler file.

### `db.after()` — schedule work from the handle phase

```typescript
// [handle] .create_order
export function handle(ctx: HandleContext, db: WriteDb): string {
  db.execute("INSERT INTO orders ...", ...);
  db.after("0s", "charge_payment", { order_id: ctx.id });
  db.after("5m", "send_confirmation", { order_id: ctx.id });
  db.after("24h", "expire_order", { order_id: ctx.id });
  return "ok";
}
```

Under the hood:
```sql
INSERT INTO _scheduled (operation, params, run_at, status)
VALUES ('charge_payment', '{"order_id":"..."}', now(), 'pending')
```

- `"0s"` = immediate (next poll cycle)
- `"5m"` = 5 minutes from now
- `"24h"` = 24 hours from now
- Recorded in WAL like every other write
- Queryable: `SELECT * FROM _scheduled WHERE status = 'pending'`
- Cancellable: `UPDATE _scheduled SET status = 'cancelled' WHERE ...`

### `// [worker]` — execute work outside the state machine

```typescript
// [worker] .charge_payment
// interval 5s
export async function charge_payment(params: { order_id: string }) {
  // Runs OUTSIDE the state machine — side effects allowed.
  const result = await stripe.charges.create({
    amount: params.amount,
    currency: "usd",
  });

  // Write result back THROUGH the state machine.
  return {
    operation: "complete_order",
    id: params.order_id,
    body: { result: result.status === "succeeded" ? "confirmed" : "failed" },
  };
}
```

The worker function:
- Receives the params from `db.after()`
- Does arbitrary async work (API calls, compute, I/O)
- Returns an operation + body → framework sends it through the state
  machine as a normal request
- The state machine validates the transition like any other request

### `// interval` — poll frequency per worker

```
// [worker] .charge_payment
// interval 5s          ← poll _scheduled every 5 seconds
```

```
// [worker] .expire_order
// interval 60s         ← poll every 60 seconds (not urgent)
```

Different workers poll at different rates. Urgent work (payments)
polls frequently. Background work (expiration, cleanup) polls rarely.

## The flow

```
1. User request → handler → db.after("0s", "charge_payment", params)
                           → INSERT INTO _scheduled (run_at = now())
                           → return "ok" to user

2. Framework worker polls: SELECT FROM _scheduled
                           WHERE run_at <= now() AND status = 'pending'

3. Framework calls:        charge_payment(params)
                           → developer code calls Stripe
                           → returns { operation, id, body }

4. Framework sends:        POST /orders/:id/complete { result: "confirmed" }
                           → state machine validates transition
                           → order status: pending → confirmed

5. Framework updates:      UPDATE _scheduled SET status = 'completed'
```

## Everything in one file

The developer writes the full lifecycle in one handler file:

```typescript
// Route: how to get here
// [route] .create_order
// match POST /orders

// Handle: pure state transition (inside state machine)
// [handle] .create_order
// → schedules side effects via db.after()

// Worker: impure execution (outside state machine)
// [worker] .charge_payment
// → calls Stripe, returns result through state machine

// Render: what the user sees
// [render] .create_order
```

The scanner sees all four annotations. The framework generates both
the HTTP dispatch AND the worker polling loop from the same file.

## What the framework enforces

| Boundary | What's allowed | What's not |
|---|---|---|
| Handle phase | db.execute(), db.after() | No async, no fetch, no I/O |
| Worker phase | async, fetch, file I/O, compute | Doesn't write to DB directly — returns operation for state machine |

The state machine is never contaminated by side effects. The worker
is never trusted to write directly — it goes through the same
validation as any user request.

## What the CFO tests

- `db.after()` calls in handle → INSERT into _scheduled → fuzz-tested
- State transitions from worker results → same as user requests → fuzz-tested
- Worker function itself → NOT fuzz-tested (it calls external APIs)
- The boundary between pure and impure → fuzz-tested

The fuzzer exercises the scheduling and the result path. The side
effect itself (Stripe, email) is outside the fuzzer's scope — that's
what integration tests cover.

## Comparison to Laravel Queue

| | Laravel Queue | Tiger Web Worker |
|---|---|---|
| Schedule work | `dispatch(Job)->delay("24h")` | `db.after("24h", "op", params)` |
| Where is state | Redis/SQS (separate system) | Database row (same system) |
| Query pending work | Can't query Redis TTLs | `SELECT FROM _scheduled` |
| Cancel scheduled work | Find and delete from Redis | `UPDATE SET status = 'cancelled'` |
| Survives crash | Maybe (Redis persistence) | Always (database + WAL) |
| Side effect isolation | Job handler does everything | Worker returns result, state machine validates |
| Fuzz coverage | None | Scheduling + transitions fuzz-tested |
| Worker code location | Separate Job class file | Same handler file, `// [worker]` annotation |
