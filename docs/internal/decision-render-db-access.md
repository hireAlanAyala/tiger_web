# Design 008: Render Gets Read-Only DB Access

## Problem

After a mutation commits, the handler's render phase needs to show the
result. For simple mutations (create product), the handler has the data
it wrote — it's in the request body or the prefetch cache. But for
mutations with side effects (complete order releases reserved inventory),
the affected data was never prefetched because the handler didn't know
it would need it.

Prefetch runs before handle. It can't know the mutation's side effects.
Render runs after commit. It sees stale prefetch data.

### Alternatives explored

**`then` as annotation** — `[handle followup=page_load_dashboard]`.
Static, can't branch on outcome. Killed because the developer might
only want to refresh on success, not on validation failure.

**`then` as return value** — `{ status: "ok", writes: [...], then: "page_load_dashboard" }`.
Runtime decision, per code branch. The handler says "after me, run
page_load_dashboard." The framework defers, runs a second pipeline
next tick, sends the result as SSE events.

Problems with `then`:
- Developer traces across two handler files to understand what the user sees
- Coarse — refreshes the entire dashboard when you might only need the product list
- Two renders compete for the same SSE stream — ordering and selector conflicts
- Second pipeline run means deferred state on the connection (`FollowupState`),
  a second prefetch/commit cycle, and `process_followups` in the server tick

**Client-side refresh** — Datastar's reactive signals re-fetch after mutation.
Works but pushes server-side consistency to the client. In REST/HATEOAS,
POST returns the created resource — no second round trip.

### The bind

The prefetch/execute split means:
- Prefetch can't predict side effects (runs before handle decides)
- Handle can't query (it's pure — no IO)
- Render sees stale prefetch data (from before the mutation)

## Decision

Render receives a read-only database handle. It can query post-commit
state for data it needs to display.

```zig
// complete_order.zig
pub fn render(ctx: Context, db: anytype) []const u8 {
    // The order was just completed. Query its post-mutation state.
    const order = db.query(OrderRow,
        "SELECT ... FROM orders WHERE id = ?1;",
        .{ctx.prefetched.order.?.id},
    ) orelse return "<div class=\"error\">Order not found</div>";
    // render the confirmed/failed order...
}
```

The framework detects at comptime whether the handler's render takes
`(ctx)` or `(ctx, db)` and passes the read-only storage handle only
when the handler declares it needs one.

## Why this is safe

**Handle can't query, so prefetch can't be skipped.** A handler can't
move all reads to render because handle needs prefetched data to make
decisions (`if (ctx.prefetched.order == null) return .not_found`).
Handle's blindness forces reads into prefetch. The only data that
moves to render is data handle didn't need — which is exactly the
side-effect data this solves.

**The SM contract is intact.** Prefetch reads (IO), handle decides
(pure), commit writes (IO). Render sits outside the SM boundary.
TigerBeetle's execute is pure for consensus/replay. Our handle is
pure for the same structural reason. Render is the web equivalent
of a TigerBeetle client lookup — reading post-commit state to build
a response. The SM's guarantees are preserved.

**Single-threaded, no races.** Each connection's processing is
sequential within the tick loop:
  A: prefetch → commit → render
  B: prefetch → commit → render
A's render completes before B's prefetch starts.

**Determinism preserved.** The WAL doesn't replay render. If someone
did replay render, it would work — render's inputs (db state +
framework context) are fully determined by WAL-replayed db state.
The render read is a pure function of the committed state at that
point in time.

**Testable.** Render with db is still testable — set up a database
with known state, call render, assert the HTML. Heavier than pure
render (data in, HTML out) but the tradeoff only applies to handlers
that use the db parameter. Most handlers don't.

## What died

- `process_followups` in server.zig (deferred second pipeline)
- `FollowupState` on Connection (deferred state between ticks)
- `needs_followup()` on Operation (hardcoded followup classification)
- `then` as a concept (runtime or annotation)
- Framework-injected error fragments (handler owns all rendering)

One tick, one response, one render. No deferred state.
