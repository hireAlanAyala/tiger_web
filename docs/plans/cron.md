# Cron — Scheduled Handlers

> **TODO:** Stop and ask TigerBeetle for critiques. This plan needs to
> be refined.

A cron is a handle triggered by a schedule instead of an HTTP request.
It has prefetch, it has handle, it can dispatch workers. The only new
annotation is `[cron]` with `every`. No new concepts.

## Implementation checklist

### 1. Annotation scanner — `[cron]` phase

- [ ] Add `cron` to the scanner's Phase enum.
- [ ] Parse `[cron] .name` — operation name.
- [ ] Parse `every <duration>` — interval directive (`5s`, `10m`, `1h`).
  Must be present and parseable.
- [ ] Validate prefetch SQL is valid.
- [ ] Validate handle exists for this cron.
- [ ] Validate any `worker.*` calls in handle reference workers that
  exist.
- [ ] A cron has no `[route]` and no `[render]` — no HTTP request, no
  client to respond to.

### 2. Timer in server tick loop

- [ ] For each `[cron]` annotation, track `last_run` timestamp.
- [ ] On each tick, check if `interval` has elapsed since `last_run`.
- [ ] When elapsed: run the cron through the same pipeline as any
  request — prefetch reads the database, handle makes decisions and
  dispatches workers, the transaction commits.
- [ ] Update `last_run` after commit.

### 3. Codegen — manifest

- [ ] Include cron annotations in the manifest alongside routes and
  workers.
- [ ] Cron entries: operation name, interval, prefetch SQL.

### 4. Pipeline integration

- [ ] Cron goes through the standard prefetch → handle path.
- [ ] No route (not triggered by HTTP).
- [ ] No render (no client to respond to).
- [ ] Workers dispatched from a cron go into `_worker_queue` same as
  workers dispatched from a route. Failure chain intact —
  `ctx.worker_failed` enforced on the completion handler regardless of
  dispatch source.
- [ ] Cron handle runs inside a transaction. If it rolls back, worker
  dispatch rows disappear.

### 5. Testing

- [ ] Cron handlers are exercisable by the existing state machine
  fuzzer — they are just operations with prefetch and handle.
- [ ] Sim tests can trigger crons by advancing simulated time past the
  interval threshold.

---

## Design decisions

These decisions are documented to prevent regression — each was
explored and resolved during design. They are not implementation steps.

### Why cron instead of delayed dispatch

Frameworks like Laravel offer `dispatch(Job)->delay("24h")` — schedule a
job to run after a delay. This hides state in the queue infrastructure.
The delayed job is not queryable, not cancellable without queue-specific
tooling, and not visible in the database.

A cron is simpler and more powerful. Instead of telling the framework
"do this in 24 hours," the developer writes the condition in SQL —
"find everything that's due." The data lives in a domain table the
developer controls. The cron checks it on a schedule. The developer
owns the query, the table, and the logic.

Examples:
- Delayed email: `email_followups` table with `send_at`. Cron every
  10m, query `WHERE send_at <= now() AND sent = 0`.
- Order expiration: cron every 1h, query orders still pending after
  24 hours.
- Payment retry: cron every 5m, query failed payments with < 3
  attempts.

### Syntax

```typescript
// [cron] .check_pending_emails
// every 10m
// [prefetch] SELECT * FROM email_followups WHERE send_at <= now() AND sent = 0
// [handle] .check_pending_emails
export function handle(ctx: HandleContext, db: WriteDb) {
  for (const email of ctx.data.emails) {
    worker.send_email(email.id, email.to, email.body);
  }
}
```

```typescript
// [cron] .expire_stale_orders
// every 1h
// [prefetch] SELECT * FROM orders WHERE status = 'pending' AND created_at < strftime('%s', 'now') - 86400
// [handle] .expire_stale_orders
export function handle(ctx: HandleContext, db: WriteDb) {
  for (const order of ctx.data.orders) {
    db.execute("UPDATE orders SET status = 'expired' WHERE id = ?", order.id);
  }
}
```

```typescript
// [cron] .retry_failed_payments
// every 5m
// [prefetch] SELECT * FROM orders WHERE payment_status = 'failed' AND payment_attempts < 3
// [handle] .retry_failed_payments
export function handle(ctx: HandleContext, db: WriteDb) {
  for (const order of ctx.data.orders) {
    db.execute("UPDATE orders SET payment_attempts = payment_attempts + 1 WHERE id = ?", order.id);
    worker.charge_payment(order.id, order.amount);
  }
}
```

### Why no route and no render

A cron has no HTTP request — there is no client. It has no render —
there is no response to send. It has prefetch and handle because it
reads data and acts on it. Same pipeline, fewer phases.

### The full annotation set

```
[route]     — triggered by HTTP request
[cron]      — triggered by schedule
[worker]    — triggered by dispatch
[prefetch]  — read data
[handle]    — write data
[render]    — return HTML
```

Six annotations. Every feature — user requests, background jobs,
scheduled tasks, failure handling — is a different combination of the
same building blocks.
