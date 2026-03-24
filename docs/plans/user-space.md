# User Space API

How a framework user writes handler code. One API for all languages.

## Handler phases

```
route     → parse URL, produce typed message
prefetch  → read data (read-only db)
handle    → decide + queue writes (write queue db)
render    → produce HTML (read-only db, post-commit state)
```

## route — URL pattern matching

The `[route]` annotation declares a URL pattern. The scanner reads it
and generates the routing dispatch. The route function receives parsed
params and maps them to a typed message.

```ts
// [route] .get_product
// match GET /products/:id
export function routeGetProduct(req): Route | null {
    return { operation: "get_product", id: req.params.id };
}

// [route] .vendor_redirect
// match GET /go/:slug
export function routeVendorRedirect(req): Route | null {
    return { operation: "vendor_redirect", body: { slug: req.params.slug } };
}

// [route] .list_products
// match GET /products
export function routeListProducts(req): Route | null {
    return { operation: "list_products" };
}

// [route] .complete_order
// match POST /orders/:id/complete
export function routeCompleteOrder(req): Route | null {
    return { operation: "complete_order", id: req.params.id };
}
```

```zig
// [route] .get_product
// match GET /products/:id
pub fn route(method: t.http.Method, raw_path: []const u8, body: []const u8) ?t.Message {
    // Framework already matched method + path and extracted :id
    // The function maps params to a typed message
    return t.Message.init(.get_product, req.params.id, 0, {});
}
```

The `// match` annotation declares:
- HTTP method (GET, POST, PUT, DELETE)
- URL pattern with named params (`:id`, `:slug`)

The scanner reads the pattern and generates routing dispatch. The
route function receives pre-matched params. Manual URL parsing
(`split_path`, regex) is replaced by the pattern declaration.

For handlers that need complex matching (query params, conditional
logic), the route function can still do custom parsing — the match
annotation is optional sugar.

## handle — decide + queue writes

Handle receives a write queue disguised as `db`. Calling `db.execute`
doesn't execute SQL — it records the SQL + params into a queue. The
framework drains the queue after handle returns, inside the transaction.

```zig
pub fn handle(ctx: Context, db: anytype) Status {
    if (ctx.data.product != null) return .version_conflict;
    db.execute("INSERT INTO products VALUES (:id, :name, :price_cents)", ctx.body);
    return .ok;
}
```

```ts
export function handle(ctx, db): Status {
    if (ctx.data.product !== null) return "version_conflict";
    db.execute("INSERT INTO products VALUES (:id, :name, :price_cents)", ctx.body);
    return "ok";
}
```

### What db.execute does per path

- **Zig-native**: records SQL + params into a fixed-size write queue
- **Sidecar**: records SQL + params, serialized back over the binary protocol

After handle returns, the framework:
1. Checks the status — if handle didn't queue anything, nothing to apply
2. Drains the queue — executes each SQL statement inside the transaction
3. Commits the batch

### Why a queue, not direct execution

- **Handle stays deterministic.** Same context → same queue + same status.
  No IO during handle. The queue is output, not side effect.
- **Framework owns transactions.** All writes in a tick share one
  begin_batch/commit_batch. The framework controls when SQL runs.
- **Uniform API.** Zig-native and sidecar handlers write the same code.
  `db.execute` everywhere. The framework decides when it actually runs.
- **Testable via outcomes.** End-to-end tests (prefetch → handle → drain →
  query result) validate behavior. Nobody unit-tests the writes array —
  the fuzz/sim tests check "I created a product, can I get it back?"

### Handle is not pure

Handle has a side channel — the write queue. You can't test it by just
checking the return value. You'd also need to inspect the queue.

In practice, this doesn't matter. The real tests are end-to-end.
The queue is deterministic (same input → same queue). It's structurally
the same as returning a writes array, with better ergonomics.

### Parameter binding — named params from structs

```zig
db.execute("INSERT INTO products VALUES (:id, :name, :price_cents)", ctx.body);
```

The framework matches `:id` to `body.id` at comptime (Zig) or runtime (TS).
You write real SQL. The binding is just less typing. If a param name doesn't
match a struct field, compile error (Zig) or build error (TS).

## Handle return — just the status

Handle returns a status. Nothing else.

```zig
fn handle(ctx: Context, db: anytype) Status
```

```ts
function handle(ctx, db): Status
```

No writes array. No session field. No response wrapper.
Session changes are writes — `db.execute("INSERT INTO sessions ...")`.
The framework reads session state from the database, not from handle's
return value.

## render — produce HTML with post-commit db access

Render sees the committed state. It can query the database (read-only)
for post-mutation data that handle didn't prefetch.

```zig
pub fn render(ctx: Context, db: anytype) []const u8 {
    return switch (ctx.status) {
        .ok => render_product(ctx, db),
        .version_conflict => "<div class=\"error\">Already exists</div>",
    };
}
```

See decisions/render-db-access.md for the full reasoning.

## prefetch — read-only db

Prefetch loads data for handle to decide on. Read-only — no writes.

```zig
pub fn prefetch(db: anytype, msg: *const Message) ?Prefetch {
    return .{
        .product = db.query(ProductRow,
            "SELECT id, name, price_cents FROM products WHERE id = :id",
            msg),
    };
}
```

## Per-handler status — scanner-generated

The scanner extracts status literals from handle() return statements
and generates a per-handler Status enum. The compiler enforces that
render handles every status exhaustively.

See docs/plans/scanner-status-enum.md for the full plan.

## Worker — external API calls without await

The framework is single-threaded. External API calls (Stripe, Auth0,
entitlements APIs) can't block the tick loop. The worker provides
non-blocking external IO in prefetch and post-commit hooks in handle.

**No await. No async. No promises. No callbacks.**

The developer writes sequential code. The framework retries until
the external data arrives. This is the same mechanism as storage busy —
prefetch returns null, retry next tick.

### Worker in prefetch — external data needed for queries

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
The developer checks for null and returns null — that's it. The retry
loop is invisible. `worker.fetch` caches per-connection so the
external request fires once, not every tick.

### Worker in prefetch — multiple external sources

```ts
export function prefetchVendorRedirect(db, worker, msg) {
    const vendor = db.query("SELECT * FROM vendors WHERE slug = :slug", msg);

    // Non-blocking — starts request, returns null until ready
    const entitlements = worker.fetch("https://api.esm.com/entitlements", {
        headers: { Authorization: `Bearer ${msg.identity.token}` }
    });
    if (!entitlements) return null;

    const pages = db.query_all("SELECT * FROM vendor_pages WHERE vendor = :vendor", vendor);
    return { vendor, entitlements, pages };
}
```

`db.query` is immediate (local database). `worker.fetch` is async
(external API). The developer mixes them naturally. The framework
retries until the async results are ready. Local queries re-execute
each tick — they're fast (prepared statements, in-memory).

### Worker after commit — fire-and-forget external calls

```ts
export function handleCompleteOrder(ctx, db) {
    if (!ctx.data.order) return "not_found";
    db.execute("UPDATE orders SET status = 'confirmed', payment_status = 'pending' WHERE id = :id",
        ctx.data.order);

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
Tick 1:  handle queues db.execute + after_commit callback
         framework drains queue → executes SQL → commits transaction
         framework fires after_commit → starts async Stripe call
         render runs → client gets response IMMEDIATELY
         Stripe call is in-flight, client already has their page

Tick N:  Stripe responds → worker posts result back as new HTTP request
         complete_payment handler commits the Stripe result
```

The client never waits for Stripe. The database tracks payment state:
`payment_status = 'pending'` → worker succeeds → `payment_status = 'paid'`.
If Stripe fails, the worker retries. If it keeps failing, the worker
posts a failure → handler sets `payment_status = 'failed'`.

The database is always the source of truth. External calls are
eventually consistent. The framework doesn't undo commits — the
worker handles its own retries.

### Why await is never needed

The tick model eliminates async/await:

- **Storage busy** → prefetch returns null, retry next tick
- **Worker pending** → prefetch returns null, retry next tick
- **Post-commit side effect** → fires after client has response

Same mechanism for all three. The developer writes sequential code
with null checks. The framework retries. No async, no await, no
callback hell, no promise chains. The single-threaded event loop
does the scheduling.

## What dies

- `Write` tagged union in state_machine.zig
- `apply_write` dispatch
- `writes` field on handler response
- `session_action` field on handler response
- `HandlerResponse` struct (replaced by bare Status return)
- `ExecuteResult` struct (replaced by Status + queue)

## Summary

```
route:     (request)                    → Message
prefetch:  (read-only db, worker, msg)  → Data (or null = retry)
handle:    (ctx, write-queue)           → Status
render:    (ctx, read-only db)          → HTML
```

Four functions. Each gets exactly the access it needs.
The framework calls them in order, manages transactions, retries
on null, wraps output. No async. No await. No callbacks.
