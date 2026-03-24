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

## prefetch — declare what you need

Prefetch declares data requirements. It doesn't return anything.
`db.query`, `db.query_all`, and `worker.fetch` queue requests.
The framework resolves all of them and populates `ctx.data` before
calling handle. The developer never sees pending state, never
returns null, never manages retries.

```ts
// [prefetch] .get_product
export function prefetch(db, msg) {
    db.query("product", "SELECT * FROM products WHERE id = :id", msg);
}
// handle gets ctx.data.product

// [prefetch] .page_load_dashboard
export function prefetch(db, msg) {
    db.query_all("products", "SELECT * FROM products WHERE active = 1");
    db.query_all("collections", "SELECT * FROM collections WHERE active = 1");
    db.query_all("orders", "SELECT * FROM orders ORDER BY id");
}
// handle gets ctx.data.products, ctx.data.collections, ctx.data.orders

// [prefetch] .vendor_redirect
export function prefetch(db, worker, msg) {
    db.query("vendor", "SELECT * FROM vendors WHERE slug = :slug", msg);
    db.query_all("pages", "SELECT * FROM vendor_pages");
    worker.fetch("entitlements", "https://api.esm.com/entitlements");
}
// handle gets ctx.data.vendor, ctx.data.pages, ctx.data.entitlements
```

```zig
// [prefetch] .get_product
pub fn prefetch(db: anytype, msg: *const Message) void {
    db.query("product", ProductRow,
        "SELECT id, name, price_cents FROM products WHERE id = :id", msg);
}
```

### How the framework resolves prefetch

1. Runs prefetch — all queries and worker fetches are queued
2. Executes db queries immediately (local, fast)
3. Starts worker fetches (non-blocking)
4. If any worker fetch is pending → retry next tick, process other connections
5. When everything resolves → populates `ctx.data`, calls handle

The developer writes declarations. The framework handles resolution,
retry, and aggregation. No return value, no null checks, no control flow.

### Why no chaining

All prefetch declarations are independent. You can't use one query's
result in another query's params:

```ts
// NOT SUPPORTED — result of one query as input to another
worker.fetch("ext_user", "https://auth0.com/users/" + msg.id);
db.query("profile", "SELECT * FROM profiles WHERE ext_id = :id", ref("ext_user"));
```

If you need external data in a local query, sync the external data
to your database via a job (a handler triggered by the worker on a
schedule). Prefetch then queries the local cache:

```ts
// Entitlements synced to local db every 5 minutes by worker job
db.query("entitlement", "SELECT * FROM entitlement_cache WHERE user_id = :id", msg);
```

This keeps prefetch simple — declarations only, no control flow,
no dependencies between queries.

### Same pattern as handle

Prefetch queues reads. Handle queues writes. Same mechanism:

| Phase    | Queues       | Framework does after       |
|----------|--------------|----------------------------|
| prefetch | db.query, worker.fetch | resolves all, populates ctx.data |
| handle   | db.execute   | drains queue inside transaction |

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

The developer queues requests in prefetch. The framework resolves
them across ticks and calls handle when everything is ready.

### Worker in prefetch — external data alongside local queries

```ts
export function prefetch(db, worker, msg) {
    db.query("vendor", "SELECT * FROM vendors WHERE slug = :slug", msg);
    db.query_all("pages", "SELECT * FROM vendor_pages");
    worker.fetch("entitlements", "https://api.esm.com/entitlements");
}
// handle gets ctx.data.vendor, ctx.data.pages, ctx.data.entitlements
```

What happens per tick:

What happens per tick:

```
Tick 1:  framework runs prefetch
         db.query("vendor") → immediate, resolved
         db.query_all("pages") → immediate, resolved
         worker.fetch("entitlements") → starts request, pending
         framework sees pending → skips, processes other connections

Tick 2:  worker.fetch("entitlements") → checks cache, still pending → skip

Tick N:  worker.fetch("entitlements") → response arrived, resolved
         all three resolved → populates ctx.data → handle runs
```

The developer wrote three declarations. The framework handled
everything — resolution, retry, aggregation. No null checks,
no control flow, no return value.

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

Same mechanism for all three. The developer queues declarations.
The framework resolves, retries, drains. No async, no await, no
callback hell, no promise chains. The single-threaded event loop
does the scheduling.

## What dies

- `Write` tagged union in state_machine.zig
- `apply_write` dispatch
- `writes` field on handler response
- `session_action` field on handler response
- `HandlerResponse` struct (replaced by bare Status return)
- `ExecuteResult` struct (replaced by Status + queue)
- Prefetch return value (replaced by queued declarations)
- Null-return retry pattern (framework handles retry internally)

## Summary

```
route:     (request)                    → Message
prefetch:  (read-only db, worker, msg)  → void (queues declarations)
handle:    (ctx, write-queue)           → Status
render:    (ctx, read-only db)          → HTML
```

Four functions. Each queues what it needs.
The framework resolves prefetch, drains handle writes, wraps render
output. No return values for data. No async. No await. No callbacks.
