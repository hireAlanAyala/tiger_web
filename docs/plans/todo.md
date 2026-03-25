# Next plans to execute

1. ~~**Sidecar protocol rebuild**~~ — DONE 2026-03-25
   Self-describing binary rows, two pipelines (native SM + sidecar),
   SQL-write WAL, 24 TS handler files, binary dispatch, fuzzed,
   cross-language verified, replay tool rewritten.
   See `docs/plans/sidecar-protocol.md`.

2. **Worker integration** — `docs/plans/worker.md` — DEFERRED
   worker.fetch in prefetch (framework resolves across ticks).
   Worker polls for post-commit work (no after_commit callbacks).
   Chained queries solved by syncing external data to local db via
   worker jobs.

3. **Sim test update** — sim.zig compiles but tests fail due to
   handler/route refactors. Each test needs assertions updated for
   the new handler architecture (SQL writes, match_route, etc.).

4. **Codegen rewrite** — codegen.zig generates old binary serde that's
   no longer used. Running `zig build codegen` overwrites the hand-written
   SDK (types.generated.ts). Needs rewrite to generate only constants +
   enum mappings, or delete entirely.

5. **Session as writes** — DEFERRED
   Remove session_action from HandleResult. Session changes via
   db.execute on a sessions table. Requires auth architecture change
   (cookie-based → sessions table). Only logout uses session_action.

---

# Search improvements

All inside SearchQuery.matches(), no external service:
- Prefix matching — "wid" matches "widget"
- Naive stemming — strip common suffixes (ing, ed, s, er) before matching
- Scoring — name > description, exact > prefix, sort by score not id
- Synonym/alias table — loaded at init, "couch" → ["sofa", "loveseat"], common misspellings
- Edit distance (Levenshtein) — fallback for novel typos, O(n·m) per word pair

# Image processing (decided)

Images stay outside the state machine — client uploads to filesystem, worker processes.
State machine tracks job metadata (id, status, result) only. Worker reads from filesystem,
resizes, does domain logic (diff, color scan), posts result back. Result is small
(histogram, diff score, pixel count) — fits in fixed-size struct.

# Tickets

## 1: JSON parser rejects whitespace around colons

json_string_field expects the exact byte sequence `:`, json_u32_field/json_bool_field expect `:`. A body like `{"name" : "Widget"}` silently fails — field not found, request rejected. Today only Datastar's JSON.stringify() produces JSON (compact, no spaces), so this doesn't fire. Breaks if any other JSON producer sends requests.

Fix: after matching the closing `"` of the field name, skip optional spaces before and after `:` in all three extractors. Add tests with space variants.

## 2: JSON string parser truncates values containing escaped quotes

json_string_field finds the closing `"` with a bare indexOf — no escape handling. A value like `"name":"Widget \"Pro\""` parses as `Widget \`. The comment at codec.zig documents this. Since users type product names in the browser, a name containing a literal `"` gets silently truncated at the codec boundary.

Fix: walk the string byte-by-byte, skipping `\"` sequences when looking for the closing quote. Add tests: `{"name":"say \"hi\""}` should extract `say \"hi\"`.

## 3: Price parsing bug

The price_cents on the created product came back as $0.09 instead of $9.99. Sent `"price_cents":999` but the response shows `price_cents:9`. The Datastar payload serializer might be nesting the JSON differently than codec.zig expects — or the curl Content-Length was wrong and the body got truncated.

## 5: RESOLVED — render-owned refresh for SSE mutations

Followups deleted. Render has db access for post-mutation queries.
Handler owns the complete response. See decisions/render-db-access.md.

## 6: RESOLVED — status exhaustiveness enforced by scanner

Scanner extracts statuses from handle(), verifies render() handles each
one explicitly. No generated types, no catch-all. Same check for all
languages. See annotation_scanner.zig module doc.

## 7: RESOLVED — raw SQL in prefetch

Handlers call db.query/query_all with SQL directly. No ORM.
See user-space.md for the declaration-based prefetch design.


# Backlog
- TS sidecar render should return effects array, not single string. Same spec as Zig tuples:
  `return [["patch", "#toast", html, "append"], ["sync", "/dashboard"]]`
  Requires: TS adapter generates effects return type, dispatch sends effects over wire,
  framework delivers as multiple SSE events. Currently TS render returns `string`.
- address todos scattered within the code
- Domain logic should assert inputs and outputs to preserve business logic (progress: might be too to demo to new users)
- Ensure the framework works on all operating systems (currently Linux only)
- CI should run test-adapter
- Add CI/CD with integration tests against the /examples repo
- Login code logging removed from server.zig — need a worker that polls for pending codes and sends them
- User-space spec: test worker, test returning SSE, test DB calls
- Stressor: multi-tenant user
- storage can retry forever on err, we should add an upper cap
- assert prefetch cannot write data in sql
-- asert commit + handler cannot read data in sql
- assert the user has atleast 1 assert inside of prefetch to validate the ctx
- RESOLVED: render has db access, `then` killed, no multi-step needed
- make sdk assert no panic in prod
- boil all adapters+packaged addons into a plugin api
- write vanilla html in render without a string  and the compiler turns it to datastar so theres no api to learn
- add an opt in way for sse to fan out updates to all users for that page
- the compiler/runtime should output to a file in dev so ai can read it on its own with tail
- give users zig primitives in their pure functions,
on compile chunk the user space by where zig is used,
run a user space chunk,
pass the result to zig as binary,
run the zig after that chunk,
If errors show it on compiler
benefit: allows the language to have a uniform, assert, and other zig checks
- ensure each annotation stage only gets enough db access to work correctly, and assert others dont have side -effects


wal should track if request was in prod or local

RESOLVED: compiler should force error handling in render — scanner enforces status exhaustiveness

ci ideas

  tiger init my-app
  tiger add operation get_product --read
  tiger add operation create_product --mutation

## Framework audit primitives

The framework exposes building blocks for users to write simulation tests
with domain-specific oracles. Framework owns the harness, user owns the
oracle. See `storage-boundary.md` for rationale.

### Workload generator
- PRNG-driven operation sequencer with user-configured weights
- Swarm testing: random weights per seed, different seeds stress different mixes
- `random_enum_weights` and `gen_random_message` exist internally in fuzz_lib/fuzz.zig
- Need generic `WorkloadType(App)` that takes the user's operation enum

### Auditor interface
- Hook point where user plugs in their reference model
- Shape: `on_commit(msg, resp)`, `at_capacity(op) bool`, `id_pools() IdPools`
- `IdTracker` in fuzz.zig is the minimal version (IDs + capacity, no validation)
- User auditor extends with domain state and assertions
- Should be comptime-validated interface like `StateMachineType(Storage)`

### Coverage tracking
- `OperationCoverage` + `FeatureCoverage` exist internally in fuzz.zig
- Need to be generic over user's operation enum
- Feature coverage should be user-extensible

### Richer fault injection
- MemoryStorage currently does busy/err only
- Add: latency variation, partial batch failures, transient-then-recover
- Consider letting users bring their own MemoryStorage (just implement interface)

### Delivery order
1. Extract fuzz_lib utilities into framework/ (weights, FuzzArgs)
2. Make OperationCoverage generic over any operation enum
3. Define auditor interface as comptime contract
4. Build WorkloadType(App) wiring generator + coverage + auditor
5. Example auditor for ecommerce app in examples/
6. Enrich fault injection
