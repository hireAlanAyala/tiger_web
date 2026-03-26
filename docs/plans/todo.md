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

3. ~~**Sim test update**~~ — DONE. All 85/85 pass (`zig build test` exit 0).

4. ~~**Codegen**~~ — DELETED. Hand-written SDK + cross-language tests.

5. **Session as writes** — DEFERRED
   Remove session_action from HandleResult. Session changes via
   db.execute on a sessions table. Requires auth architecture change
   (cookie-based → sessions table). Only logout uses session_action.

6. **Simulation testing** — `docs/plans/simulation-testing.md`
   User-space domain verification via `[sim:*]` annotations.
   Reference model, assert callbacks, invariants, shared predicates.
   Phase 1: bolt onto fuzz.zig (Zig-native). Phase 2: scanner.
   Phase 3: TS sidecar sim.

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

json_string_field finds the closing `"` with a bare indexOf — no escape handling. A value like `"name":"Widget \"Pro\""` parses as `Widget \`. Since users type product names in the browser, a name containing a literal `"` gets silently truncated at the parse boundary.

Fix: walk the string byte-by-byte, skipping `\"` sequences when looking for the closing quote. Add tests: `{"name":"say \"hi\""}` should extract `say \"hi\"`.

## 3: Price parsing bug

The price_cents on the created product came back as $0.09 instead of $9.99. Sent `"price_cents":999` but the response shows `price_cents:9`. The Datastar payload serializer might be nesting the JSON differently than the parser expects — or the curl Content-Length was wrong and the body got truncated.

# Backlog
- framework author debugging improved a lot, user space debugging should improve more at the compiler assertions
- TS sidecar render should return effects array, not single string. Same spec as Zig tuples:
  `return [["patch", "#toast", html, "append"], ["sync", "/dashboard"]]`
  Requires: TS adapter generates effects return type, dispatch sends effects over wire,
  framework delivers as multiple SSE events. Currently TS render returns `string`.
- address todos scattered within the code
- Ensure the framework works on all operating systems (currently Linux only)
- CI should run test-adapter
- Add CI/CD with integration tests against the /examples repo
- Login code logging removed from server.zig — need a worker that polls for pending codes and sends them
- User-space spec: test worker, test returning SSE, test DB calls
- Stressor: multi-tenant user
- storage can retry forever on err, we should add an upper cap
- make sdk assert no panic in prod
- boil all adapters+packaged addons into a plugin api
- write vanilla html in render without a string and the compiler turns it to datastar so theres no api to learn
- add an opt in way for sse to fan out updates to all users for that page
- the compiler/runtime should output to a file in dev so ai can read it on its own with tail
- give users zig primitives in their pure functions,
  on compile chunk the user space by where zig is used,
  run a user space chunk,
  pass the result to zig as binary,
  run the zig after that chunk,
  If errors show it on compiler
  benefit: allows the language to have a uniform, assert, and other zig checks
- wal should track if request was in prod or local

ci ideas

  tiger init my-app
  tiger add operation get_product --read
  tiger add operation create_product --mutation
