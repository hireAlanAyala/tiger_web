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

The scanner reads the pattern and validates routes. `translate()`
uses route_method/route_pattern (comptime-asserted on every handler)
to fast-skip non-matching handlers before calling route().

For handlers that need complex matching (query params, conditional
logic), the route function adds extra checks after `match_route()`.

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

### Why db.execute over a writes array

The current design returns `ExecuteResult { .response, .writes }` with
a tagged union (`Write { .put_product, .update_product, ... }`). This
looks inspectable but nobody inspects it — no test asserts on the writes
array. The fuzzer and auditor check outcomes: "I created a product, can
I get it back?" They query the database after commit.

`db.execute` with SQL replaces the tagged union with the actual mutation.
The safety comes from the same place it always did:

1. Prefetch queries state → handle asserts preconditions
2. Handle returns status → scanner verifies render handles it
3. Framework commits → state changes
4. Auditor queries again → asserts the outcome matches

Assert outcomes, not mechanics. The writes array was mechanics.
The database state after commit is the outcome. `db.execute` is
simpler to read, fewer types to maintain, and the test coverage
is identical because nobody was testing the intermediate form.

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

### Writes are optional

Read-only handlers don't call `db.execute` — they just return a status.
The framework detects an empty write queue and skips the transaction.

```ts
// Read-only — no writes, no transaction
export function handle(ctx) {
    if (ctx.prefetched.product === null) return "not_found";
    return "ok";
}

// Mutation — queues writes, framework commits
export function handle(ctx, db) {
    if (ctx.prefetched.product !== null) return "version_conflict";
    db.execute("INSERT INTO products VALUES (?1, ?2, ?3)", ctx.body);
    return "ok";
}
```

Read-only handlers don't receive `db` at all — the framework detects
the parameter count and skips the write queue. Same pattern as render
receiving an optional db parameter for post-commit queries.

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

## prefetch — aggregate and return

Prefetch queries the database, builds a typed struct, and returns it.
Handle receives the struct as `ctx.prefetched`. This is the current
pattern — it stays.

```zig
pub const Prefetch = struct {
    product: ?t.ProductRow,
};

// [prefetch] .get_product
pub fn prefetch(storage: anytype, msg: *const t.Message) ?Prefetch {
    return .{ .product = storage.query(t.ProductRow,
        "SELECT id, name, price_cents FROM products WHERE id = ?1;",
        .{msg.id}) };
}
```

```ts
// [prefetch] .get_product
export function prefetch(db, msg) {
    return { product: db.query("SELECT * FROM products WHERE id = ?", msg.id) };
}
```

### Why keep it

- **Compiler validates field names** — misspell `product` → compile error (Zig), no runtime string matching
- **The struct IS the documentation** — you see exactly what the handler needs at a glance
- **No framework magic** — the handler builds its own data, the framework just passes it through
- **Null return = storage busy** — the framework retries next tick, handler doesn't manage retries

## Per-handler status — scanner-enforced

The scanner extracts status literals from handle() and verifies
render() handles each one explicitly. No generated types — the
scanner compares two sets from source text and errors on missing
statuses. Same check for all languages. No catch-all handling.

See annotation_scanner.zig module doc for the full design.

## Worker — external API calls without await

The framework is single-threaded. External API calls (Stripe, Auth0,
entitlements APIs) can't block the tick loop. The worker provides
non-blocking external IO. See docs/plans/worker.md for the full design.

**No await. No async. No promises. No callbacks.**

Worker data in prefetch is returned as part of the Prefetch struct,
same as database queries. If the worker result is pending, prefetch
returns null → framework retries next tick.

### Post-commit external calls — worker polls, no callbacks

External calls (Stripe, Auth0) are handled by the worker process,
not by callbacks in handle. Handle commits state changes. The worker
polls for pending work and posts results back as HTTP requests.

```ts
export function handleCompleteOrder(ctx, db) {
    if (!ctx.prefetched.order) return "not_found";
    db.execute("UPDATE orders SET status = 'confirmed', payment_status = 'pending' WHERE id = :id",
        ctx.prefetched.order);
    return "ok";
    // Worker picks up pending payment, calls Stripe, posts result back
}
```

The client never waits for Stripe. The database tracks payment state:
`payment_status = 'pending'` → worker succeeds → `payment_status = 'paid'`.
If Stripe fails, the worker retries. The database is the source of truth.

See docs/plans/worker.md for the worker design.

### Why await is never needed

The tick model eliminates async/await:

- **Storage busy** → prefetch returns null, retry next tick
- **Worker pending** → prefetch returns null, retry next tick
- **Post-commit external calls** → worker polls, posts result as new request

Same mechanism. No async, no await, no callback hell, no promise chains.
The single-threaded event loop does the scheduling.

## What was killed (done)

- `Write` tagged union — handlers write SQL directly via db.execute
- `apply_write` dispatch — framework no longer interprets writes
- `HandlerResponse` struct — handle returns bare Status via HandleResult
- `ExecuteResult` struct — status is the return value, writes via WriteView
- `MemoryStorage` — replaced by SqliteStorage(:memory:) for all tests
- Manual URL parsing in routes — replaced by `// match` + `match_route`

## What stays

- Prefetch returns a typed struct — compiler validates field names
- Null-return from prefetch = storage busy → framework retries
- `session_action` on HandleResult — only logout uses it, deferred

## Current state

```
route:     (method, path, body)         → ?Message (match_route pre-filters)
prefetch:  (read-only db, msg)          → ?Prefetch (typed struct)
handle:    (ctx, write-only db)         → HandleResult (status + session_action)
render:    (ctx, read-only db)          → HTML
```

Route declares `route_method` + `route_pattern` — framework skips the
call on mismatch. Handle writes SQL directly via `db.execute` with
shared constants from `sql.zig`. Scanner enforces status exhaustiveness
across handle and render. WriteView asserts writes succeed.
