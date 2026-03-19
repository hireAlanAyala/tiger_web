# Design 001: HTML Rendering and SSE

## Problem

Tiger_web is an ecommerce server that must serve customers and be admin-manageable.
The server returns JSON today. A Go proxy sits in front of it to translate JSON
into HTML and manage SSE connections for live order updates via Datastar.

This architecture splits correctness across two processes in two languages.
The proxy duplicates types, re-implements routing, strips request bodies to
work around protocol mismatches, and re-fetches data after every mutation
because it doesn't have the typed result. The rendered HTML is the product —
if the user sees the wrong price, it's a bug regardless of whether the state
machine computed it correctly. Rendering is not a separate concern from
correctness; it's how correctness is delivered.

The proxy was valuable as a prototype. It proved Datastar integration works,
validated the SSE event format, and established the HTML fragment patterns
that `render.zig` will produce. It stays in git history as reference.

## Decision

Remove the Go proxy and JSON encoding. The Zig server returns HTML directly.
HTML is the only wire format — there is no JSON API.

```
http.zig → codec.zig → state_machine.prefetch → state_machine.commit → render.zig
 (parse)    (decode)         (prefetch)              (execute)          (encode + frame)
```

Each module owns one direction. No module appears twice. `codec.zig` decodes
inbound requests into typed messages. `render.zig` encodes typed results into
HTML. They share `message.zig` as the common language. Neither knows about the
other's format.

## Options considered

**Keep the proxy.** Rejected — two processes, duplicated types, double routing,
protocol workarounds, re-fetch after every mutation, awkward auth forwarding.
Every new resource or field requires changes in both languages.

**Two connection pool types (HTTP + SSE).** Separate pools with a promotion
mechanism (HTTP → SSE). Rejected for now — heavy machinery for a problem we
don't have. 128 pool slots at ~43% utilization. Memory savings are ~650KB.
The design is correct and preserved here; adopt when SSE connections exceed
25% of pool utilization. See "Future" below.

**HTML encoding inside codec.zig.** Rejected — without JSON, codec becomes a
pure decoder. Adding HTML encoding re-introduces two growth axes in one file
(decoding grows with operations, HTML grows with UI). `render.zig` keeps the
pipeline directional: `codec.zig` faces inbound, `render.zig` faces outbound.

**Prefetch loads what render needs.** Each mutation would prefetch both its
domain data and the full list for rendering. Rejected — couples the state
machine to presentation. `create_product` prefetches what the operation needs
(existence check), not what the page looks like. The state machine's IO
profile should not be a function of the UI.

**Surgical fragment updates.** Render adapts to the mutation result — replace
one card, remove one card, append one card. Rejected — mutations have
cross-resource effects (deleting a product affects collections, creating an
order decrements inventory). A per-operation table mapping mutations to
affected UI sections couples the server to page layout and misses edge cases.

**Full page refresh as follow-up (chosen).** After every mutation, the server
runs a `page_load` operation next tick — same as `GET /`. Render writes SSE
fragments replacing every data section. See "Mutation follow-up" below.

## Interface contract

The server returns HTML. Always. Consumers that need structured data receive
a `<script type="application/json">` tag and parse it themselves.

### Request discrimination

| Header                     | Response                                      |
|----------------------------|-----------------------------------------------|
| (absent)                   | Full HTML page (`Content-Type: text/html`)     |
| `Datastar-Request: true`   | SSE fragments (`Content-Type: text/event-stream`)|

`GET /` returns a complete page. Datastar actions (`@post`, `@delete`, etc.)
send `Datastar-Request: true` automatically. Long-lived SSE connections
(`GET /events`) are deferred — see "Future" below.

### Full page vs fragment

Both call the same per-resource render functions. The full page wraps them in
a page shell (hardcoded in `render.zig`, no template file, no filesystem
access). Fragments wrap them in SSE framing targeting a DOM selector.

### Error rendering

| Scenario                  | Response                                        |
|---------------------------|-------------------------------------------------|
| 401 unauthorized          | HTTP 401 with HTML error page                   |
| 404 unknown route         | HTTP 404 with HTML error page                   |
| 400 validation error      | SSE fragment with error message (via follow-up)  |
| 502 storage error         | HTTP 500 with HTML error page                   |

For SSE connections, errors are delivered through the follow-up mechanism —
render includes an error message fragment alongside the data refresh. The user
always sees feedback. This fixes the proxy bug where a failed DELETE returned
nothing.

### CORS

Same-origin serving eliminates CORS entirely. The OPTIONS handler is removed.
The only cross-origin resource is the Datastar JS bundle from CDN (a script
tag, not a fetch).

### Datastar body handling

Datastar sends signal bodies on every request including GET/DELETE. `codec.zig`
ignores the body on GET/DELETE when `is_sse` is set. No stripping hack.

### Datastar version

`1.0.0-RC.7` from CDN. Version `1.0.0-beta.11` caused initialization failures.
Hardcoded in `render.zig`'s page shell.

```
https://cdn.jsdelivr.net/gh/starfederation/datastar@1.0.0-RC.7/bundles/datastar.js
```

## Connection model

One flag: **`is_sse: bool`**.

| `is_sse` | Behavior                                    |
|----------|---------------------------------------------|
| `false`  | Normal HTTP. One request, one response, keep-alive cycle. Full HTML page. |
| `true`   | Datastar action. Short-lived SSE connection. Commit, refresh next tick, close. |

Datastar opens a new SSE connection for every action. Each is independent and
short-lived — open, commit, refresh, close. Three rapid clicks = three
connections, three refreshes. At 128 pool slots and microsecond queries, this
is not a concern.

The idle timeout applies to all connections equally. SSE connections close
after the follow-up sends. If prefetch stays busy, the idle timeout kills the
connection. No special timeout logic.

`codec.zig` sets `is_sse` on the translate result — one decision in one place.
The `Datastar-Request` header is parsed by http.zig and passed to codec.zig.

### Connection struct additions

```zig
is_datastar_request: bool,    // default false — set by codec from Datastar-Request header
pending_followup: bool,       // default false — set by process_inbox for SSE mutations
followup_status: Status,      // result status from mutation, read by encode_followup
followup_operation: Operation, // original mutation op, selects error panel in render
```

## Mutation follow-up

### The prefetch/commit constraint

Prefetch reads from storage into cache (can return `busy`). Commit runs
entirely from cache, never reads storage. The cache resets after commit.
This means commit cannot fetch additional data for rendering — `create_product`
prefetched the target product, not the full product list.

### Full page refresh

After every mutation on an SSE connection — success or error — the server
sets `pending_followup = true` and sends nothing. Next tick, it runs
`page_load` — one prefetch/commit cycle that loads all three lists (products,
collections, orders). Render writes SSE fragments replacing every data section.
If the mutation failed, render includes an error message fragment.

`page_load` is the same operation as `GET /`. One operation, one prefetch, one
commit. The difference is only framing: page shell vs SSE frames.

Every SSE mutation follows one path: commit, wait one tick, refresh, close.
No branching on success vs error in the connection lifecycle — the only
difference is whether render includes an error message, and that's a render
concern.

If prefetch returns `busy`, the follow-up retries next tick. The idle timeout
bounds the retry window.

What this costs: three list queries per mutation (microseconds at current
scale), ~50KB of SSE events (within 128KB send buffer), one tick (10ms)
latency. On error the data hasn't changed, so the refresh is redundant but
harmless.

### Same-tick follow-up

Originally designed as a two-tick flow, but implemented as same-tick.
`process_followups` runs immediately after `process_inbox` within the
same `tick()` call. This works because `process_inbox` wraps all writes
in `begin_batch`/`commit_batch` (deferred), so the mutation's writes are
committed before `process_followups` opens its own batch. The follow-up
runs a fresh prefetch/commit cycle — it doesn't try to piggyback on the
mutation's cache. Same-tick saves 10ms latency with no correctness cost.

1. `process_inbox`: Prefetch → commit the mutation. Stores result status
   in `followup_status`. Sets `pending_followup = true`. Nothing is sent.

2. `process_followups` (same tick): Sees `pending_followup`. Runs
   `page_load` through prefetch → commit. Render writes SSE fragments
   into send_buf. If `followup_status` was an error, includes error
   message. Clears `pending_followup`. Connection transitions to
   `.sending`, then closes after send (SSE, Connection: close).

If prefetch returns `busy`, retries next tick. The idle timeout bounds
the retry window.

If multiple SSE mutations complete in the same tick, each gets its own
`page_load` prefetch/commit cycle reading identical data. Cost: N
microsecond queries for N concurrent mutations. Acceptable at 128 pool
slots; optimize if profiling shows otherwise.

## Server tick

```
tick:
    maybe_accept
    process_inbox       ← SSE mutations set pending_followup, send nothing
    process_followups   ← page_load prefetch → commit → render for pending follow-ups
    log_metrics
    flush_outbox
    continue_receives
    update_activity
    timeout_idle
    close_dead
```

**process_inbox**: For non-SSE requests, renders and sends as usual. For SSE
mutations, stores result status and sets `pending_followup = true`.

**process_followups**: Iterates connections with `pending_followup == true`.
Runs `page_load` (same as `GET /`). If prefetch returns `busy`, skips —
retries next tick. On commit, render writes SSE fragments. If error, includes
error message. Clears follow-up. Marks connection for closing after send.

## Module changes

### http.zig

Remove all response encoding (`encode_json_response`, `encode_options_response`,
`encode_401_response`). Add `Datastar-Request` header parsing.

### codec.zig

Remove `encode_response_json` and all JSON serialization. Add `is_sse` on
translate result. Add `page_load` operation (used by `GET /` and follow-ups).
Ignore body on GET/DELETE when `is_sse`.

### render.zig (new)

```zig
pub fn encode_response(
    send_buf: []u8,
    response: MessageResponse,
    is_sse: bool,
) u32  // returns bytes written
```

Pure function. Two jobs: full HTML page (non-SSE) and list refresh SSE
fragments with optional error (follow-ups). Page shell hardcoded as string
literals.

Fuzz strategy (same pattern as `codec_fuzz.zig`): random `MessageResponse` →
`encode_response` → assert buffer bounds, HTTP/SSE framing invariants. The
comptime assert guarantees buffer size for worst-case pagination. The fuzzer
catches field values that violate the comptime math (long names, escaping
expansion). HTML content correctness is not fuzzed.

### server.zig

Response path: `render.encode_response(&conn.send_buf, resp, conn.is_sse)`.
`json_buf` deleted. No intermediate buffer.

### connection.zig

Add `is_sse`, `pending_followup`, `followup_status`. State machine unchanged.

### message.zig

Unchanged. `orders_changed` deferred until broadcasts are needed.

## Buffer layout

```zig
pub const page_shell_max = 4 * 1024;
pub const product_card_max = 800;
pub const order_card_max = 300;
pub const collection_card_max = 900;
pub const max_items_per_page = 100;
pub const http_headers_max = 400;

pub const send_buf_max = http_headers_max + page_shell_max +
    (max_items_per_page * product_card_max);

comptime {
    assert(send_buf_max <= 128 * 1024);
}
```

Memory: 128 connections * 128KB = 16MB (up from 9MB).

## Phasing

1. **Add render.zig alongside JSON.** Wire into server.zig. Parse
   `Datastar-Request` header. Add `is_sse`. Add `GET /` → `page_load`.
2. **Migrate routes to render.** One resource at a time: products →
   collections → orders → error pages.
3. **Remove JSON.** Delete `encode_response_json`, `encode_json_response`,
   `json_buf`, OPTIONS handler.
4. **Add SSE follow-ups.** Add `pending_followup`, `followup_status`,
   `process_followups`.
5. **Remove the proxy.** Delete `proxy/`. Update `CLAUDE.md`.

## Future

### Broadcasts

Long-lived SSE connections (`GET /events`) deferred. When needed: add route,
`orders_changed` flag on `MessageResponse`, `broadcast_orders` in tick,
`heartbeat_sse` for keepalive, timeout skip for long-lived connections. Build
when there's a second order mutation or a real admin dashboard use case.

### Two pool types

Separate HTTP and SSE pools with promotion mechanism. Build when SSE
connections exceed 25% of pool utilization, memory per connection becomes a
deployment constraint, or workload shifts to many concurrent SSE clients.
Connection pool utilization is already tracked in `log_metrics`.
