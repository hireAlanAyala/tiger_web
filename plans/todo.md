# Open questions
- If we swapped out the DB with a cache, would the system still be deterministic? Is there a way to measure determinism?
- Does the sidecar restart on crash?
- Are all the user-space compile logs clear and actionable?
- What is the goal of squashing and how often? What do you gain, what do you lose?

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

## 4: Middleware primitive for pluggable auth

Cookie handling (resolution, header formatting, cookie_action dispatch) is baked into server.zig's process_inbox. If auth changes (OAuth, API keys, no auth), server.zig needs rewriting.

A middleware layer between HTTP parsing and the codec would let auth be pluggable:
- Pre-codec middleware: resolve identity from request headers (cookies, bearer tokens, API keys)
- Post-render middleware: format response headers (Set-Cookie, WWW-Authenticate)
- The server stays generic: accept, recv, tick, send

Not urgent — there's only one auth strategy today. The cookie_action enum and is_authenticated bool are the seam where middleware would plug in. Revisit when a second auth strategy is needed.

## 5: Render-owned refresh() for SSE mutations

The SSE followup mechanism is baked into server.zig. After every SSE mutation, the server defers rendering, runs a second state machine round-trip (page_load_dashboard), and sends three list fragments. This is a specific rendering choice hard-coded in the framework.

The render layer should own a refresh() primitive that re-fetches the queries used to build the current page. This replaces the server's followup deferral entirely. The server just renders the response. The render layer decides what to re-fetch, if anything.

Requires: render needs access to the state machine (or a callback) to run follow-up queries. Design the boundary carefully — render should request data, not call prefetch/execute directly.

Interim debt: server.zig's followup condition checks `resp.cookie_action == .none and resp.result != .login` to skip followup for login mutations. This is domain logic in the framework. Once refresh is opt-in, remove this condition and the needs_dashboard_refresh field on MessageResponse.

## 6: Split replay tests into framework vs application

The replay module mixes framework-level tests (WAL integrity, hash chain, truncation recovery) with application-level tests (product round-trip, updates/deletes, stop-at). If Product changes, framework tests break even though the framework didn't change.

Split:
- Framework side (replay.zig): WAL create/recover, root deterministic, hash chain validation, truncation recovery, version mismatch, verify valid/corrupt, read_batch, derive_work_path, format_uuid, body_to_json, write_json_string
- Application side: "full round-trip", "stop-at", "updates and deletes" move out. replay_fuzz.zig stays application-side

Same code coverage, same test count. Module ownership split, not new work.

## 7: Missing replay test coverage

kcov shows replay.zig at 94.7% (409/432 lines). Uncovered paths:

1. query() — the most complex untested function. Zero test coverage. Test: create a WAL with known entries, run SQL queries, assert output. Also test: empty WAL, invalid SQL.
2. entity_id() — tested indirectly through inspect, but no direct test per operation type.

query() is the priority — it's real untested logic, not debug info noise.


# Backlog

- Domain logic should assert inputs and outputs to preserve business logic
- Stress test: what happens if x% of processing is external API calls? Would this break determinism?
- Ensure the framework works on all operating systems (currently Linux only)
- CI should run test-adapter
- Add CI/CD with integration tests against the /examples repo
- Login code logging removed from server.zig — need a worker that polls for pending codes and sends them
- Followup decision moved from server.zig into state_machine commit() — verify Operation.needs_followup() stays correct as new operations are added
- Intra-tick visibility: writes applied per-operation (after each execute), not batched at end of tick. Operations later in the tick see earlier operations' writes. Architecture supports batching — move apply loop outside the connection for-loop when it matters
- Couple the DB schema with features more tightly
- User-space spec: test worker, test returning SSE, test DB calls
- Stressor: multi-tenant user
