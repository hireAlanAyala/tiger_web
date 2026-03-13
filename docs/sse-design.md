# SSE Design: Real-Time UI via Go Proxy

## Problem

The web client loads static HTML from a CDN but needs real-time UI updates:
partial HTML swaps, live order status, and cross-user state synchronization.
SSE is the delivery mechanism. The state machine acts as the singleton
reducer — all state flows through it, and SSE pushes changes to browsers.

The challenge is adding SSE without compromising tiger_web's TigerBeetle-style
architecture.

## Decision

SSE lives in a separate Go proxy process. Tiger_web stays a pure
request-response message bus. The proxy holds long-lived browser
connections and translates between SSE and HTTP.

```
Browsers <--SSE--> Go Proxy <--HTTP--> Tiger_web <---> SQLite
                      |
               Cloudflare (TLS, rate limiting, DDoS)
               sits in front of everything
```

## Why SSE

SSE melts complexity out of the client. The browser receives partial HTML
and JSON signals over a single stream. No client-side polling logic, no
request orchestration, no stale-state management. The state machine is
the single source of truth, and SSE is the push mechanism that keeps
every connected browser in sync.

Real-time between users is a domain requirement — when one user creates
an order, other users see it update. SSE gives us this without WebSocket
complexity or client-side polling.

## Why Not SSE in Tiger_web

Adding SSE directly to the server would require:

- Concurrent recv+send on streaming connections (connection state machine
  assumes exclusive states today)
- A polling loop in the tick to check for entity changes (the tick loop
  is currently reactive, not proactive)
- Application state on the connection struct (breaks the clean separation
  between byte mechanics and application logic)
- Phantom message synthesis to re-query the state machine for streaming
  connections (bypasses auth, codec, HTTP parsing)
- Shared connection pool between short-lived requests and long-lived
  streams (starvation risk under load)

These changes alter the server's architectural character. SSE is a
transport concern, not a state machine concern. The TigerBeetle
principle: don't add complexity to the core to avoid complexity at
the edge.

## Architecture

### Tiger_web (unchanged)

Pure request-response. Processes `Message -> MessageResponse` through
the existing `codec -> prefetch -> execute` pipeline. No awareness of
SSE, browsers, or long-lived connections. Every request gets a response
and the connection is freed.

### Go Proxy

Three responsibilities:

1. **Forward writes.** Browser POSTs via Datastar -> proxy forwards to
   tiger_web -> gets JSON response -> wraps as Datastar SSE event
   (`mergeSignals`) -> pushes to the originating browser's SSE stream.

2. **Fan out changes.** Polls tiger_web for real-time entity state
   (e.g., `GET /orders?status=pending` on a timer). When state changes,
   pushes SSE events to all connected browsers that care.

3. **Hold connections.** Manages long-lived SSE connections to browsers.
   Browsers connect once, receive a stream of events. The proxy handles
   reconnection via the SSE spec (`retry`, `Last-Event-ID`).

The proxy never deserializes domain types. JSON from tiger_web is opaque
bytes wrapped in SSE framing. The proxy is a stateless relay — it can
crash and restart without data loss because tiger_web owns all state.

### Why Go for the Proxy

The proxy's job is I/O multiplexing — hold connections, forward bytes,
poll on a timer. Go's goroutines, `net/http`, and stdlib HTTP client
handle this in ~200 lines. The TB-style constraints (zero allocation,
deterministic execution, fuzz-tested invariants) don't apply to a
stateless relay.

No shared types needed. The proxy treats JSON as opaque bytes. The
boundary is HTTP — no shared memory, no build system coupling.

### Datastar

The client-side JS library. Receives SSE events from the proxy and
applies them to the DOM:

- `mergeSignals` — push JSON data, client-side templates render it
- `mergeFragments` — push HTML fragments, swap into the DOM
- `removeFragments` — remove DOM elements

The Datastar SDK (inspected at `../datastar-zig`) handles no auth. It
assumes the caller has already decided the request is authorized. Auth
is not an SDK concern — it's a server/infrastructure concern.

Reference: https://github.com/starfederation/datastar-zig

## Fan-Out Strategy

Start with targeted polling of specific endpoints — not a generic
changes feed. Most apps only need real-time on a small portion of data.

**Day one:** The proxy polls `GET /orders?status=pending` every 500ms.
When an order resolves, it pushes an SSE event. Everything else the
client fetches on demand via normal POSTs through the proxy.

**Scaling up:** If more entities need real-time, add more polling targets
to the proxy. No tiger_web changes required.

**Future (if needed):** A `list_changes` operation backed by an in-memory
ring buffer in the state machine. Gives the proxy a single cheap question:
"did anything change since sequence N?" Eliminates per-entity polling.

### Ring Buffer (deferred)

If the fan-out polling becomes wasteful at scale, the state machine gains
a change log:

- `ChangeEntry` type in `message.zig` (entity_id, sequence, operation)
- Fixed-size ring buffer in the state machine (in-memory, pre-allocated)
- `list_changes` operation through the normal message bus
- Writes to the ring buffer during existing execute paths

The ring buffer is in-memory, not persisted to SQLite. No write
amplification — the existing write path is untouched. On crash, the
proxy detects its cursor is invalid (tiger_web returns "cursor expired"),
does a full re-sync from the existing list endpoints, and resumes
incremental polling. The ring buffer is an optimization for incremental
delivery, not a durability guarantee. The source of truth is the actual
entities in SQLite.

This is a routine feature addition through the existing message bus.
No architectural changes to tiger_web.

## Auth and Security

### Perimeter: Cloudflare

Cloudflare sits in front of the proxy and handles the security perimeter:
TLS termination, rate limiting, DDoS protection, bot detection. It
prevents connection flooding and filters malicious traffic before it
reaches the proxy.

### Identity: JWT

Tiger_web uses real JWT auth — HMAC-SHA256 signature verification,
expiry enforcement, timing-safe comparison (`auth.zig`). The `sub`
claim identifies the user. The server rejects requests with missing,
tampered, or expired tokens (401).

The proxy does not duplicate this logic. It forwards the JWT token
to tiger_web on every request. Tiger_web is the single auth authority.

### Session Expiry

The only realistic auth failure mid-session is token expiry. The user
opened the page, the SSE connection is alive, but the JWT's `exp`
claim has passed. When the proxy's next forwarded request returns 401,
the proxy closes the SSE connection. The browser-side Datastar/EventSource
sees the stream drop. The client prompts the user to re-authenticate,
gets a fresh token, and reconnects.

No auth logic in the proxy. No auth logic in Datastar (confirmed by
inspecting the SDK — it handles no auth). Tiger_web validates at its
boundary, the proxy reacts to 401, the client handles reconnection.

### Unauthenticated Connections

If a browser connects to the proxy with an invalid or missing token,
the proxy forwards the first request, tiger_web returns 401, and the
proxy closes the SSE connection immediately. The proxy holds the
connection for one round trip at most.

At scale, an attacker could open many connections with bad tokens to
exhaust proxy resources. Cloudflare's rate limiting per IP prevents
this at the perimeter — the proxy doesn't need its own connection
flooding protection.

## Testing

### Existing (unchanged)

- `fuzz.zig` — state machine directly
- `codec_fuzz.zig` — codec translation
- `storage_fuzz.zig` — storage equivalence
- `sim.zig` — full-stack simulation with fault injection

### New

**`proxy_fuzz.zig`** — Zig integration fuzzer that tests the full
pipeline as a black box. PRNG-driven operations go through the proxy
to tiger_web, SSE events come back, the auditor validates correctness.
Catches dropped events, JSON corruption, ordering violations, and
reconnection edge cases. The Go proxy is a subprocess — the fuzzer
doesn't know or care that it's Go.

**Go unit tests** — table-driven tests for the proxy's translation
logic (JSON bytes in, SSE frame out) independent of tiger_web.

## What Changes in Tiger_web

Nothing on day one. The proxy talks to the existing HTTP API.

The ring buffer change log is deferred until polling load justifies it.
When added, it goes through the normal message bus as a routine new
operation — no architectural changes.
