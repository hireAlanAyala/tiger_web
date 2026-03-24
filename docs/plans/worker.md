# Worker — External IO Without Await

The framework is single-threaded. External API calls (Stripe, Auth0,
entitlements APIs) can't block the tick loop. The worker provides
non-blocking external IO that fits into the prefetch/handle/render
pipeline without async, await, promises, or callbacks.

## Principle

**The tick model eliminates async/await.**

The developer queues declarations. The framework resolves them across
ticks and calls the next phase when everything is ready. The developer
never sees pending state, never returns null, never manages retries.

## Worker in prefetch — declare what you need

`worker.fetch` is the same pattern as `db.query` — a queued declaration.
The framework resolves all of them before calling handle.

```ts
// [prefetch] .get_profile
export function prefetch(db, worker, msg) {
    db.query("local_user", "SELECT * FROM users WHERE id = :id", msg);
    worker.fetch("auth_profile", "https://api.auth0.com/users/" + msg.id);
}
// handle gets ctx.data.local_user and ctx.data.auth_profile
```

What happens per tick:

```
Tick 1:  framework runs prefetch
         db.query("local_user") → immediate, resolved
         worker.fetch("auth_profile") → starts request, pending
         framework sees pending → skips, processes other connections

Tick 2:  worker.fetch("auth_profile") → checks cache, still pending → skip

Tick N:  worker.fetch("auth_profile") → response arrived, resolved
         all resolved → populates ctx.data → handle runs
```

The developer wrote two declarations. The framework handled resolution,
retry, and aggregation. No null checks. No return value.

## Mixing local and external sources

```ts
// [prefetch] .vendor_redirect
export function prefetch(db, worker, msg) {
    db.query("vendor", "SELECT * FROM vendors WHERE slug = :slug", msg);
    db.query_all("pages", "SELECT * FROM vendor_pages");
    worker.fetch("entitlements", "https://api.esm.com/entitlements");
}
// handle gets ctx.data.vendor, ctx.data.pages, ctx.data.entitlements
```

`db.query` is immediate (local database). `worker.fetch` is async
(external API). The developer doesn't distinguish between them.
The framework resolves everything before calling handle.

## Multiple external calls

```ts
// [prefetch] .dashboard
export function prefetch(db, worker, msg) {
    db.query_all("products", "SELECT * FROM products WHERE active = 1");
    worker.fetch("weather", "https://api.weather.com/current");
    worker.fetch("exchange", "https://api.forex.com/rates/usd");
}
```

Both fetches start on tick 1. They resolve independently. The
framework calls handle when all three are ready. No sequential
waiting — both are in-flight concurrently.

## Worker after commit — fire-and-forget

When an external API needs to be called after a mutation commits
(payment processing, notifications, webhooks), use `db.after_commit`:

```ts
// [handle] .complete_order
export function handle(ctx, db) {
    if (!ctx.data.order) return "not_found";
    db.execute(
        "UPDATE orders SET status = 'confirmed', payment_status = 'pending' WHERE id = :id",
        ctx.data.order
    );

    db.after_commit(() => {
        worker.post("https://api.stripe.com/charges", {
            body: { order_id: ctx.data.order.id, amount: ctx.data.order.total }
        });
    });

    return "ok";
}
```

What happens:

```
Tick 1:  handle queues SQL + after_commit callback
         framework drains queue → executes SQL → commits transaction
         framework fires after_commit → starts async Stripe call
         render runs → CLIENT GETS RESPONSE IMMEDIATELY
         Stripe call is in-flight, client already has their page

Tick N:  Stripe responds → worker posts result back as new HTTP request
         complete_payment handler commits the result
```

The client never waits for Stripe.

## Failure handling

### Worker fails in prefetch

If the external API times out or errors, the framework populates
`ctx.data` with an error value for that key. Handle decides what
to do:

```ts
export function handle(ctx, db) {
    if (ctx.data.auth_profile.error) return "service_unavailable";
    // ... normal logic ...
}
```

The connection times out if the external API never responds
(same as any connection timeout in the framework).

### Worker fails after commit

The client already has their response. The order is confirmed in the
database. Stripe failed. The database tracks the state:

```
payment_status = 'pending'   → worker calls Stripe
                             → success → 'paid'
                             → failure → worker retries
                             → keeps failing → 'failed'
```

The database is always the source of truth. External calls are
eventually consistent. The framework doesn't undo commits — the
worker handles its own retries.

## Why await is never needed

Await blocks the current execution context until the promise resolves.
In a single-threaded server, that blocks everything.

The declaration model replaces await entirely:

| Traditional            | Declaration model                    |
|------------------------|--------------------------------------|
| `await fetch(...)`     | `worker.fetch("key", url)`           |
| Promise.all([a, b])    | Two `worker.fetch` declarations      |
| try/catch on await     | Check `ctx.data.key.error` in handle |
| async/await chains     | Declarations, framework resolves     |
| return null + retry    | Not needed — framework handles retry |

The developer declares what data they need. The framework fetches it.
No scheduling logic in user code.

## No chaining in prefetch

All prefetch declarations are independent. You can't use one result
as input to another query. If external data is needed for a local
query (e.g. external user ID → local profile lookup), sync the
external data to your database via a worker job:

```ts
// Worker job syncs auth0 profiles to local db every 5 minutes
// [prefetch] .sync_auth_profiles
export function prefetch(db, worker, msg) {
    worker.fetch("users", "https://api.auth0.com/users");
}

// [handle] .sync_auth_profiles
export function handle(ctx, db) {
    for (const user of ctx.data.users) {
        db.execute("INSERT OR REPLACE INTO user_cache VALUES (:id, :ext_id)", user);
    }
    return "ok";
}
```

Then other handlers query the local cache:

```ts
// [prefetch] .get_profile
export function prefetch(db, msg) {
    db.query("user", "SELECT * FROM user_cache WHERE id = :id", msg);
}
```

Prefetch stays simple — declarations only, no dependencies.

## Current state

The worker exists as a separate process (`worker.zig`) that polls
for pending orders via HTTP and posts completions back. It exercises
the post-commit pattern but sits outside the framework.

The `worker.fetch` / `db.after_commit` APIs described here are the
target design — integrating external IO into the handler pipeline
so the developer uses the same patterns they use for database access.
