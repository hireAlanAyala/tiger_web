# Render Pipeline Design

The last shim: replace `to_legacy_response` + `render.encode_response` with
handler-owned render functions. After this, handlers own the full request
lifecycle: route -> prefetch -> handle -> render.

## Principle

**The handler owns the complete response. The framework just delivers it.**

The TS sidecar already works this way — render returns a string, the
framework wraps it in HTTP headers or SSE framing. Every decision below
follows from making Zig native match that model. The handler produces HTML.
The framework doesn't inject, rewrite, or assemble anything. It delivers.

Once the render pipeline is wired, the core architecture is complete —
route, prefetch, handle, render all flow through handlers. At that point
we tear down and rewrite the layers above: clean up dead code, remove
legacy shims, and rebuild sim/fuzz/tests against the new foundation.

## Pipeline

```
prefetch (read) -> handle (decide) -> commit (write) -> render (read + HTML) -> framework (HTTP/SSE framing)
```

Single tick. No deferred followups. Handler owns the full lifecycle.
Framework wraps the output.

## Implementation order

Each step produces a correct layer. Later steps build on earlier ones.
Intermediate states may break the layers above — that's fine.

### Step 1. Commit returns cache by value

Everything downstream needs the cache. This unblocks render.

```zig
pub const CommitOutput = struct {
    response: PipelineResponse,
    cache: Handlers.Cache,
};
```

SM's job is done — cache ownership transfers to the caller. No lingering
state, no extra lifecycle methods. The defer that nulls `prefetch_cache`
stays — the cache is copied out before the null.

### Step 2. Split render.zig into framework modules

Extract the pieces that survive before deleting the rest.

- **`framework/http_response.zig`** — header backfill, Content-Length,
  keep-alive, cookie formatting. Pure HTTP plumbing.
- **`framework/sse.zig`** — Datastar event framing. User-configurable
  in the future (swap Datastar for another SSE protocol).

Pure extraction. No behavior change. The old render.zig can still exist
alongside these until it's fully replaced.

### Step 3. Render context — status + db + render_buf

Build the render context that handlers receive. This is the contract
between the framework and the handler's render function.

Context gets:
- `status` — from handle's return value
- `prefetched` — from the cache returned in step 1
- `db` — read-only database handle, post-commit state
- `render_buf` — slice of send_buf after header reserve
- `fw` — framework context (identity, now, is_sse)

Render receives a read-only database handle for post-mutation queries.
This solves side-effect scenarios where a mutation affects data the
handler didn't prefetch.

```ts
// complete_order releases reserved inventory — render needs fresh product data
export function renderCompleteOrder(status, ctx, db) {
    if (status !== "ok") return `<div class="error">${status}</div>`;
    const products = db.query("SELECT * FROM products WHERE active = 1");
    return `<div id="inventory">${renderProducts(products)}</div>`;
}
```

Why this is safe:
- Handle can't query, so developers can't skip prefetch for data handle needs
- Prefetch is protected by handle's requirements — the architecture enforces itself
- Render reads post-commit state, single-threaded, no races
- SM contract intact: prefetch (read) -> handle (pure) -> commit (write) -> render (read)
- Determinism preserved: render is outside the SM, WAL doesn't replay render
- If someone did replay render, it works — render's inputs (db state + framework
  context) are fully determined by WAL replay

### Step 4. Render contract — string or tuple

Define what render returns. The framework dispatch must handle both at
comptime before handlers can be migrated.

Handler `render()` returns either:

- **`[]const u8`** — single HTML blob. Framework sends as one SSE event
  or full HTTP response.
- **Comptime tuple** — multiple Datastar events in one response.

```zig
// Single fragment (most handlers)
pub fn render(ctx: Context) []const u8 {
    return "<div id=\"product-list\">...</div>";
}

// Multiple events (dashboard, side-effect scenarios)
pub fn render(ctx: Context) @TypeOf(.{ .{ "patch", html } }) {
    return .{
        .{ "patch", product_html },
        .{ "patch", collection_html },
        .{ "signal", "{\"orderCount\": 5}" },
    };
}
```

Tuple elements are `{ datastar_operation, content }`. No selectors —
Datastar resolves placement from `id` attributes in the HTML itself.

No framework writer or render API. Developers use Zig stdlib:

- `std.fmt.bufPrint` for simple templates
- `std.io.fixedBufferStream` for loops/complex content
- String literals for static HTML

```zig
// Static
pub fn render(ctx: Context) []const u8 {
    _ = ctx;
    return "<div id=\"message\">Deleted</div>";
}

// Dynamic
pub fn render(ctx: Context) []const u8 {
    const p = ctx.prefetched.product.?;
    return std.fmt.bufPrint(ctx.render_buf,
        \\<div id="pd-{s}">{s} - ${d}</div>
    , .{ p.id_hex, p.name, p.price_cents / 100 }) catch unreachable;
}

// Lists
pub fn render(ctx: Context) []const u8 {
    var fbs = std.io.fixedBufferStream(ctx.render_buf);
    var w = fbs.writer();
    for (ctx.prefetched.products.slice()) |p| {
        w.print("<div>{s}</div>", .{p.name}) catch unreachable;
    }
    return fbs.getWritten();
}
```

Zero framework API to learn. `catch unreachable` is correct — the buffer
is sized to never overflow, and if it does, that's a bug worth crashing on.

### Step 5. Render dispatch + SSE/full-page framing

Wire render into the server. This replaces `to_legacy_response` +
`render.encode_response`.

App gets a `dispatch_render` that switches on operation, calls the
handler's render, and returns HTML. The framework wraps it:

- **SSE**: Datastar event framing via `sse.zig`
  (`event: datastar-patch-elements\ndata: elements ...\n\n`)
- **Full page**: HTTP response via `http_response.zig`

Framework branches on `is_datastar_request`. Handler returns the same
thing either way.

Page load handlers (`page_load_dashboard`, `page_load_login`) own the
full HTML shell — `<html><head>...</head><body>...</body></html>`.

Mutations on full-page (non-SSE) send JS to reload.

Render always runs. No framework-injected error fragments. The developer
handles every status case explicitly.

### Step 6. Kill dead code

Everything replaced by steps 1-5:

- `to_legacy_response` in app.zig
- `MessageResponse.result` union
- `render.zig` — all ~1300 lines (HTML templates, per-operation rendering)
- `effects.zig` — tuple DSL replaced by handler return values
- `process_followups` in server.zig
- `FollowupState` in message.zig
- `needs_followup()` on Operation
- `encode_followup` in app.zig

### Step 7. Per-handler status enum via scanner

Can land independently after render is wired. Handlers work with a shared
Status enum initially — this step narrows each handler to its own enum.

The annotation scanner extracts literal status values from `handle()`
return statements and generates a per-handler Status enum.

```zig
// Scanner sees:
return .{ .status = .ok, ... };
return .{ .status = .not_found, ... };
return .{ .status = .version_conflict, ... };

// Generates:
pub const Status = enum { ok, not_found, version_conflict };
```

Zig's exhaustive switch enforces that render handles every status.
Adding a new status to handle is a compile error until render handles it.

For TS: scanner generates `type Status = "ok" | "not_found" | "version_conflict"`.
For dynamic languages: runtime validation against the known set.

Self-correcting: if the scanner misses a status (developer used a variable),
the generated enum is incomplete, the compiler catches it. The failure mode
is a compile error, not a silent bug.

## Design decisions

### `then` — dead, replaced by render db access

Originally considered as a return value from handle to trigger a second
operation pipeline (e.g. refresh dashboard after mutation). Explored as
annotation (`[handle followup=page_load_dashboard]`), then runtime return
value (`{ status: "ok", writes: [...], then: "page_load_dashboard" }`).

Killed because render with db access is a better primitive:
- Developer stays in one handler — can see the complete flow in one file
- Precise — query exactly what you need, not a coarse full-page refresh
- No competing SSE events from two different renders
- No deferred second pipeline run, no `process_followups`, no `FollowupState`

The only thing `then` solved that render db access doesn't: triggering a
completely different handler's pipeline. But that's just code reuse — call
that handler's queries directly from your render since db gives you access.

### Error rendering — handler-owned

No framework-injected error fragments. The per-handler status enum forces
the developer to handle every error case in render:

```zig
return switch (ctx.status) {
    .ok => "<div id=\"order\">Completed</div>",
    .not_found => "<div id=\"error\">Not found</div>",
    .version_conflict => "<div id=\"error\">Already completed</div>",
};
```

### Cross-language consistency

The render contract is the same shape in both Zig and TS:
- TS: `render(status, ctx, db) -> string`
- Zig: `render(ctx) -> []const u8` (status and db on ctx)

A developer who starts in TS sidecar and switches to Zig native sees
the same pattern. The annotation syntax (`[render]`) is identical.
The framework doesn't care which language produced the HTML.

## Key reasoning

### Why no framework writer/render API?
Evaluated three options: `html.fmt()` (bufPrint wrapper), `html.writer()`
(framework writer), or stdlib directly. fmt breaks on loops/conditionals.
Writer works but is a framework API to learn. Stdlib means zero framework
API — bufPrint for simple cases, fixedBufferStream for loops. A TS developer
switching to Zig recognizes "build a string and return it." A Zig developer
recognizes standard buffer patterns. Nobody learns a framework-specific tool.

### Why render gets db access (TigerBeetle analysis)
The SM contract is: prefetch reads, handle decides (pure), commit writes.
Render sits outside the SM boundary — it's framework territory, not SM.
TigerBeetle's execute is pure for consensus/replay. Our handle is pure for
the same structural reason. But render is the web equivalent of a TB client
lookup — reading post-commit state to build a response. The SM's guarantees
are preserved. Determinism is preserved (WAL doesn't replay render, and if
it did, render's inputs are fully determined by WAL-replayed db state).

### Why per-handler status enum via scanner (not manual)
Manual enum works for Zig but not for dynamically typed languages. The
scanner is the universal approach: scan handle, extract status literals,
generate enum/type per target language. Self-correcting — if scanner misses
a status, the generated type is incomplete, compiler/type-checker catches it.
The convention the scanner needs (literal status in return) is already how
developers naturally write handlers.

### Why no selectors in tuples
Datastar resolves element placement from `id` attributes in the HTML itself.
The framework doesn't need to add `data: selector` lines — just wrap HTML
in SSE events. The HTML is self-describing. Simplifies the tuple form from
`{ op, selector, content }` to `{ op, content }`.

### Why followups died (HATEOAS reasoning)
In REST/HATEOAS, POST returns the created resource — no second round trip.
The mutation handler has the data it wrote. For side-effect data (e.g.
inventory released by completing an order), render queries post-commit state.
One render, one response, one tick. No deferred followup, no competing SSE
events, no `process_followups` complexity.
