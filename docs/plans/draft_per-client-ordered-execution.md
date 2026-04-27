# Per-Client Ordered Execution (Browser → Server → SSE)

Status: draft

## Summary

Guarantee that requests from a single client are applied in the same
order they were issued, and that server-to-client events (SSE)
reflect that same order. This preserves user intent end-to-end
without introducing cross-client coordination.

## What We Do

- **Per-client sequencing** — Each client sends a monotonically
  increasing `seq` with every request.
- **Server enforcement** — Apply requests in-order per client: buffer
  out-of-order arrivals, dedupe retries (idempotent per `seq`).
- **Deterministic execution** — Use the existing execution loop; no
  async reordering. In-order application composes with the
  single-threaded state-machine pipeline.
- **Ordered SSE** — Emit events from the deterministic loop in the
  same sequence. Each event carries its `seq`; reconnect resumes via
  `Last-Event-ID`.

## What We Don't Do

- **No cross-client ordering.** No guarantees between different
  clients.
- **No fairness / FCFS.** Arrival order across clients is "as
  observed."
- **No cross-entity / global invariants.** Keys / partitions and
  domain consistency remain the user's responsibility.
- **No distributed coordination.** Monolith scope only — no
  consensus, no replicated log.

## Real-World Gain

- Eliminates stale overwrites (search-as-you-type, filters).
- Fixes double-submit / retry glitches.
- Stabilizes autosave and rapid UI interactions (toggles, forms).
- Makes E2E tests deterministic — no flaky ordering.
- Enables coherent streaming UI — SSE matches executed order.

## Acceptance Criteria

- Requests with `seq` are applied strictly in order per client.
- Duplicate `seq` values are ignored (idempotent).
- Out-of-order requests are buffered until gaps fill, or a timeout
  policy triggers.
- SSE events carry `seq` and are emitted in-order.
- Reconnect resumes from last seen `seq` (`Last-Event-ID`).

## Server-Defined Write Semantics & Client Ordering

The server is the source of truth for what counts as a write. The
compiler derives `isWrite` per operation from server code
(`db.write` / worker dispatch). The generated client ships with that
metadata — clients never guess.

### Client behavior

- **Writes (`isWrite: true`)**
  - Assigned a per-client monotonically increasing `seq`.
  - Queued and sent in order; safe to retry — server dedupes by
    `seq`.
- **Reads (`isWrite: false`)**
  - Sent immediately, but the client waits for all prior writes from
    the same client to be acked / applied before surfacing results.
    This gives read-after-write consistency per client.

### Server behavior

- Enforce per-client ordering: apply writes strictly by `seq`, buffer
  out-of-order, drop duplicates.
- Execute inside the existing deterministic loop — no extra threads,
  no async reordering.
- Emit SSE in execution order, tagging every event with `seq`.
- Support resume via `Last-Event-ID` / last-seen `seq`.

### Per-client guarantees

- Writes are applied in intent order.
- Reads observe all prior writes from the same client.
- SSE reflects the same order → consistent UI.

### Non-goals (restated)

- No ordering or fairness across different clients or tabs.
- No cross-entity / global invariants — those stay domain
  responsibility.

### Notes

- Each tab / session is its own client stream. A new tab is a new
  client.
- Only mutations are serialized. Reads remain parallel for
  performance.

## Design Sketch (to be expanded)

Open questions — resolve before promoting out of `draft_`:

- **Client identity.** Session cookie (existing `auth.zig`) vs an
  explicit client_id header. Cookie is free; reconnects across
  cookie-clear become a new client.
- **Seq scope.** Per-session monotonic `u64` starting at 1. Reset
  rules on logout / session rotation.
- **Buffer bounds.** Max out-of-order window per client (constants in
  `framework/constants.zig`). On overflow: close the connection
  (TB: bound everything; drop is safer than unbounded queue).
- **Gap timeout.** Max wait for a missing `seq` before we decide the
  client is gone. Tie to existing idle-timeout.
- **Dedupe memory.** How long we remember applied `seq` per client
  (needs a bound — can't remember forever). Likely "last N" + a
  low-water-mark.
- **SSE resume window.** How far back `Last-Event-ID` can resume.
  Events past the window → client must reload.
- **Where the buffer lives.** Per-connection (lost on reconnect) vs
  per-session (survives reconnect). SSE resume implies per-session.
- **Interaction with WAL.** Does `seq` get persisted, or is it purely
  a transport-layer ordering primitive? If persisted, it becomes part
  of the replay contract.

## Design Principles Check (TigerBeetle six)

| Principle | Consideration |
|---|---|
| Safety | Out-of-order buffer must be bounded; overflow closes connection, never drops silently. Dedupe must not grow unbounded. |
| Determinism | Execution order is a function of `(client_id, seq)` — reproducible from a transcript. |
| Boundedness | Per-client buffer size, dedupe history length, SSE resume window — all comptime constants. |
| Fuzzable | Sim test: PRNG-driven reorder / duplicate / drop of per-client requests; assert applied order matches issue order. |
| Right primitive | `seq` is the actual primitive — a per-client counter. No wrapping in framing / envelope abstractions. |
| Explicit | `seq` is an explicit header / field on every request and SSE event — not inferred from arrival order. |

## Phases (rough)

- **Phase 1 — client_id + seq plumbing.** Session-derived client_id;
  `seq` header parsed in `codec.zig`; rejected if missing on
  sequenced routes.
- **Phase 2 — per-client ordering buffer.** Bounded reorder buffer;
  dedupe table; gap timeout tied to idle timeout.
- **Phase 3 — SSE ordering + resume.** Emit `seq` on every event;
  honor `Last-Event-ID` on reconnect; bounded resume ring.
- **Phase 4 — sim coverage.** PRNG fuzzer in `sim.zig` injects
  reorder / dup / drop; auditor oracle asserts per-client order.
- **Phase 5 — docs + guide.** User-facing writeup in `docs/guide/` —
  what the framework guarantees, what the user still owns
  (cross-entity rules).

## Notes

- This is a high-ROI primitive for most UI-driven apps.
- For cross-client correctness, users implement domain-level rules
  (keys, constraints, transactions).
