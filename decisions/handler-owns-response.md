# Design 009: Handler Owns the Complete Response

Supersedes: Design 001 (html-rendering-and-sse.md) for the render path.
Design 001's routing and SSE framing decisions still hold.

## Problem

The old render.zig was 1,300 lines of framework code that knew every
domain type, every HTML template, and every SSE selector. Adding a
new operation required editing render.zig (framework) in addition to
the handler. The framework and the domain were coupled at the render
boundary.

The TS sidecar didn't have this problem — its handlers returned HTML
strings, and the framework wrapped them. The Zig-native path was the
outlier.

## Decision

**The handler owns the complete response. The framework just delivers it.**

Handler `render()` returns `[]const u8` — an HTML string. The framework
wraps it in HTTP headers or SSE framing. The framework doesn't inject,
rewrite, or assemble anything.

### What the handler decides

- What HTML to produce for each status (exhaustive switch on status enum)
- What data to query in render (via read-only db access)
- Whether to return a single fragment or multiple SSE events (string vs tuple)
- Page loads: the full HTML shell (`<html>...</html>`)
- Mutations on full-page: JS to reload

### What the framework decides

- HTTP headers (Content-Type, Content-Length, Connection, Set-Cookie)
- SSE framing (Datastar event format: `event: datastar-patch-elements\ndata: elements ...\n\n`)
- Whether to use SSE or full-page (branches on `is_datastar_request`)

### Render authoring — stdlib, not framework

Evaluated three approaches for Zig HTML generation:

1. **`html.fmt()`** — bufPrint wrapper. Clean for simple cases, breaks
   on loops and conditionals. A TS developer switching to Zig would
   hit a wall on their second handler.

2. **`html.writer()`** — framework writer with `.fmt()` method. Works
   for everything but it's a framework API to learn. We asked: "should
   the developer provide their own writer?" Yes — Zig developers know
   `fixedBufferStream`. A framework writer adds nothing.

3. **Stdlib directly** — `std.fmt.bufPrint` for templates,
   `std.io.fixedBufferStream` for loops, string literals for static HTML.
   Zero framework API. The TS developer recognizes "build a string and
   return it." The Zig developer recognizes standard buffer patterns.

Chose (3). The `html.zig` module provides convenience helpers (`raw`,
`escaped`, `price`, `uuid`) but these are user space, not framework.

### No selectors in tuples

The old effects.zig tuple DSL was `{ "patch", "#selector", html, "mode" }`.
Selectors are unnecessary — Datastar resolves element placement from `id`
attributes in the HTML itself. The HTML is self-describing. Tuple form
simplified to `{ event_type, content }`.

### Error rendering — handler-owned

The old pipeline injected framework error fragments into SSE responses.
With per-handler status enums, the developer handles every error case
in render via exhaustive switch. The framework has no opinion on how
errors look. The handler knows its domain — "version conflict" means
something different for products vs orders.

### Render always runs

Both handle's response and render's HTML happen in one call. The
framework does not skip render. The developer gates on status. Zig's
exhaustive switch prevents accidental rendering on wrong status —
adding a new status to handle is a compile error until render handles it.

## What died

- `render.zig` — 1,300 lines of HTML templates and per-operation rendering
- `effects.zig` — tuple DSL with selectors, modes, verbs
- `render_fuzz.zig` — fuzz tests for the old encode_response/encode_followup
- Framework-injected error fragments
- `HtmlWriter` — replaced by stdlib buffer patterns

## Cross-language consistency

The render contract is the same shape in Zig and TS:
- TS: `render(status, ctx, db) -> string`
- Zig: `render(ctx) -> []const u8` (status on ctx, db as optional 2nd param)

A developer who starts in the TS sidecar and switches to Zig native
sees the same pattern. The annotation syntax (`[render]`) is identical.
The framework doesn't care which language produced the HTML.
