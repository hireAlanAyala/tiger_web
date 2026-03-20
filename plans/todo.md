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

## 5: Render-owned refresh() for SSE mutations

The SSE followup mechanism is baked into server.zig. After every SSE mutation, the server defers rendering, runs a second state machine round-trip (page_load_dashboard), and sends three list fragments. This is a specific rendering choice hard-coded in the framework.

The render layer should own a refresh() primitive that re-fetches the queries used to build the current page. This replaces the server's followup deferral entirely. The server just renders the response. The render layer decides what to re-fetch, if anything.

Requires: render needs access to the state machine (or a callback) to run follow-up queries. Design the boundary carefully — render should request data, not call prefetch/execute directly.

Interim debt: server.zig's followup condition checks `resp.cookie_action == .none and resp.result != .login` to skip followup for login mutations. This is domain logic in the framework. Once refresh is opt-in, remove this condition and the needs_dashboard_refresh field on MessageResponse.

# 6: zig code should use annotation bu not go through the sidecar
right now the zig code doesnt have a way to declare error html, not sure what to do

# 7. user should be able to call raw sql form prefetch


# Backlog
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
- does render have a primitive for launching an operation through the pipeline again for multi-step operations? (or did we not need that)
- make sdk assert no panic in prod
- boil all adapters+packaged addons into a plugin api
- write vanilla html in render without a string  and the compiler turns it to datastar so theres no api to learn
- add an opt in way for sse to fan out updates to all users for that page
