# Active plans

1. **Simulation testing** — `docs/plans/simulation-testing.md`
   User-space domain verification via `[sim:*]` annotations.
   Reference model, assert callbacks, invariants, shared predicates.
   Phase 1: bolt onto fuzz.zig (Zig-native). Phase 2: scanner.
   Phase 3: TS sidecar sim.

2. **Worker integration** — `docs/plans/worker.md` — DEFERRED
   worker.fetch in prefetch (framework resolves across ticks).
   Worker polls for post-commit work (no after_commit callbacks).

3. **Session as writes** — DEFERRED
   Remove session_action from HandleResult. Session changes via
   db.execute on a sessions table. Only logout uses session_action.

---

# Tickets

## 1: JSON parser rejects whitespace around colons

`{"name" : "Widget"}` silently fails. Today only Datastar's
JSON.stringify() produces JSON (compact), so doesn't fire.

Fix: skip optional spaces before and after `:` in all extractors.

## 2: JSON string parser truncates escaped quotes

`"name":"Widget \"Pro\""` parses as `Widget \`.

Fix: walk byte-by-byte, skip `\"` when looking for closing quote.

## 3: Price parsing bug

Sent `"price_cents":999` but response shows `price_cents:9`.
Possible Datastar serializer nesting or Content-Length truncation.

---

# Backlog

- TS sidecar render: effects array instead of single string
- Cross-platform support (currently Linux only, epoll)
- CI: run test-adapter, integration tests against /examples
- Login code delivery via worker (not server logging)
- Storage retry cap on busy
- SDK: assert no panic in prod
- Plugin API for adapters + packaged addons
- SSE fan-out to all users on a page
- Compiler/runtime output file for AI consumption
- WAL: track prod vs local origin
- CLI scaffolding (`tiger init`, `tiger add operation`)
