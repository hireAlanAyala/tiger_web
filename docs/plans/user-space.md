# User Space API

How a framework user writes handler code. One API for all languages.

## Handler phases

```
route     → parse URL, produce typed message
prefetch  → read data (read-only db)
handle    → decide + queue writes (write queue db)
render    → produce HTML (read-only db, post-commit state)
```

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

## What dies

- `Write` tagged union in state_machine.zig
- `apply_write` dispatch
- `writes` field on handler response
- `session_action` field on handler response
- `HandlerResponse` struct (replaced by bare Status return)
- `ExecuteResult` struct (replaced by Status + queue)

## Summary

```
route:     (request)           → Message
prefetch:  (read-only db, msg) → Data
handle:    (ctx, write-queue)  → Status
render:    (ctx, read-only db) → HTML
```

Four functions. Each gets exactly the db access it needs.
The framework calls them in order, manages transactions, wraps output.
