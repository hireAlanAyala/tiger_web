# Worker — External IO Without Await

The framework is single-threaded. External API calls (Stripe, Auth0,
entitlements APIs) can't block the tick loop. The worker provides
non-blocking external IO that fits into the prefetch/handle/render
pipeline without async, await, promises, or callbacks.

## Principle

**The tick model eliminates async/await.**

Three sources of "not ready yet" in the framework:

- Storage busy → prefetch returns null, retry next tick
- Worker pending → prefetch returns null, retry next tick
- Post-commit side effect → fires after client has response

Same mechanism for all three. The developer writes sequential code
with null checks. The framework retries. The single-threaded event
loop does the scheduling.

## Worker in prefetch — external data needed before handle

The most common case: prefetch needs data from an external API
before handle can make a decision.

```ts
export function prefetchGetProfile(db, worker, msg) {
    // worker.fetch — starts async request, returns null until response arrives
    const externalUser = worker.fetch("https://api.auth0.com/users/" + msg.id);
    if (!externalUser) return null; // not ready — framework retries next tick

    // Only runs once externalUser is resolved
    const profile = db.query("SELECT * FROM profiles WHERE external_id = :id", externalUser);
    return { profile };
}
```

What happens per tick:

```
Tick 1:  worker.fetch starts request → returns null
         prefetch returns null → framework skips, processes other connections

Tick 2:  worker.fetch checks cache → still pending, returns null
         prefetch returns null → skip

Tick N:  worker.fetch checks cache → response arrived, returns data
         db.query runs with resolved data → returns profile
         prefetch returns { profile } → handle runs immediately
```

The function runs multiple times. It reads like synchronous code.
`worker.fetch` caches per-connection — the external request fires once,
not every tick. Local db queries re-execute each tick (fast — prepared
statements, in-memory).

## Worker in prefetch — mixing local and external sources

```ts
export function prefetchVendorRedirect(db, worker, msg) {
    // Immediate — local database
    const vendor = db.query("SELECT * FROM vendors WHERE slug = :slug", msg);

    // Non-blocking — external API, returns null until ready
    const entitlements = worker.fetch("https://api.esm.com/entitlements", {
        headers: { Authorization: `Bearer ${msg.identity.token}` }
    });
    if (!entitlements) return null;

    // Immediate — local database, only runs after entitlements resolve
    const pages = db.query_all("SELECT * FROM vendor_pages WHERE vendor = :vendor", vendor);
    return { vendor, entitlements, pages };
}
```

Local and external sources mix naturally. The developer doesn't
distinguish between them except for the null check. The framework
handles the retry.

## Worker in prefetch — multiple external calls

```ts
export function prefetchDashboard(db, worker, msg) {
    const weather = worker.fetch("https://api.weather.com/current");
    const exchange = worker.fetch("https://api.forex.com/rates/usd");
    if (!weather || !exchange) return null; // both must resolve

    const products = db.query_all("SELECT * FROM products WHERE active = 1");
    return { weather, exchange, products };
}
```

Both fetches start on tick 1. They resolve independently. Prefetch
retries until both are cached. No sequential waiting — both are
in-flight concurrently.

## Worker after commit — fire-and-forget external calls

When an external API needs to be called after a mutation commits
(payment processing, notifications, webhooks), use `db.after_commit`:

```ts
export function handleCompleteOrder(ctx, db) {
    if (!ctx.data.order) return "not_found";
    db.execute(
        "UPDATE orders SET status = 'confirmed', payment_status = 'pending' WHERE id = :id",
        ctx.data.order
    );

    // Fires AFTER commit, non-blocking. Client gets response immediately.
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

`worker.fetch` returns null until the response arrives. If the
external API times out or errors, `worker.fetch` returns an error
value (not null). The developer handles it:

```ts
const externalUser = worker.fetch("https://api.auth0.com/users/" + msg.id);
if (!externalUser) return null;           // still pending — retry
if (externalUser.error) return { ... };   // failed — handle can decide
```

Prefetch doesn't hang. The connection times out if the external API
never responds (same as any connection timeout).

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

The tick model replaces await with retry:

| Traditional            | Tick model                    |
|------------------------|-------------------------------|
| `await fetch(...)`     | `worker.fetch(...)` + null check |
| Promise.all([a, b])    | Multiple fetches + `if (!a \|\| !b) return null` |
| try/catch on await     | Check `.error` on resolved value |
| async/await chains     | Sequential code, null returns |

The developer writes the same logic. The scheduling is different.
Instead of suspending one request, the framework processes other
requests and comes back. No coroutines, no event emitters, no
promise chains.

## Current state

The worker exists as a separate process (`worker.zig`) that polls
for pending orders via HTTP and posts completions back. It exercises
the post-commit pattern but sits outside the framework.

The `worker.fetch` / `db.after_commit` APIs described here are the
target design — integrating external IO into the handler pipeline
so the developer uses the same patterns they use for database access.
