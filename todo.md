questions
- would SSE connections count towards the connection slots?
- put nginx in front of server?

search improvements (all inside SearchQuery.matches(), no external service):
- prefix matching — "wid" matches "widget"
- naive stemming — strip common suffixes (ing, ed, s, er) before matching
- scoring — name > description, exact > prefix, sort by score not id
- synonym/alias table — loaded at init, "couch" → ["sofa", "loveseat"], common misspellings
- edit distance (Levenshtein) — fallback for novel typos, O(n·m) per word pair

image processing design (decided):
- images stay outside the state machine — client uploads to filesystem, worker processes
- state machine tracks job metadata (id, status, result) only
- worker reads from filesystem, resizes, does domain logic (diff, color scan), posts result back
- result is small (histogram, diff score, pixel count) — fits in fixed-size struct

Migration — DONE, see design/009-documentation_database.md

Ticket 1: JSON parser rejects whitespace around colons                                                                                                                                       
                                                                         
  json_string_field expects the exact byte sequence ":", json_u32_field/json_bool_field expect ":. A body like {"name" : "Widget"} silently fails — field not found, request rejected. Today   
  only Datastar's JSON.stringify() produces JSON (compact, no spaces), so this doesn't fire. Breaks if any other JSON producer sends requests.
                                                                                                                                                                                               
  Fix: after matching the closing " of the field name, skip optional spaces before and after : in all three extractors. Add tests with space variants.

  ---
  Ticket 2: JSON string parser truncates values containing escaped quotes

  json_string_field finds the closing " with a bare indexOf — no escape handling. A value like "name":"Widget \"Pro\"" parses as Widget \. The comment at codec.zig:423 documents this. Since
  users type product names in the browser, a name containing a literal " gets silently truncated at the codec boundary.

  Fix: walk the string byte-by-byte, skipping \" sequences when looking for the closing quote. Add tests: {"name":"say \"hi\""} should extract say \"hi\".


  2. The price_cents on the created product came back as $0.09 instead of $9.99. I sent "price_cents":999 but the response shows price_cents:9. The Datastar payload serializer might be
  nesting the JSON differently than codec.zig expects — or the curl Content-Length was wrong and the body got truncated. Worth investigating.

domain logic should assert their inputs and outputs to preserve business logic

- stress test architcture what would happen if x% of the processing was external api calls. would this break determinism

---
Ticket 4: Middleware primitive for pluggable auth

  Cookie handling (resolution, header formatting, cookie_action dispatch) is baked into server.zig's process_inbox. The server checks cookie_kind for is_authenticated, formats Set-Cookie/clear-cookie headers, and reads resp.cookie_action. If auth changes (OAuth, API keys, no auth), server.zig needs rewriting.

  A middleware layer between HTTP parsing and the codec would let auth be pluggable:
  - Pre-codec middleware: resolve identity from request headers (cookies, bearer tokens, API keys)
  - Post-render middleware: format response headers (Set-Cookie, WWW-Authenticate)
  - The server stays generic: accept, recv, tick, send

  Not urgent — there's only one auth strategy today. The cookie_action enum and is_authenticated bool are the seam where middleware would plug in. Revisit when a second auth strategy is needed.

---
Ticket 5: Render-owned refresh() for SSE mutations

  The SSE followup mechanism is baked into server.zig. After every SSE mutation, the server defers rendering, runs a second state machine round-trip (page_load_dashboard), and sends three list fragments. This is a specific rendering choice hard-coded in the framework.

  The render layer should own a refresh() primitive that re-fetches the queries used to build the current page. Dashboard mutations call refresh (re-fetches product/collection/order lists). Login mutations skip it — they return their own fragment. Future pages with different queries get their own refresh logic.

  This replaces the server's followup deferral entirely. The server just renders the response. The render layer decides what to re-fetch, if anything. The needs_dashboard_refresh bool on MessageResponse is the interim seam — replace it when render owns the refresh.

  Requires: render needs access to the state machine (or a callback) to run follow-up queries. The server currently mediates this. Design the boundary carefully — render should request data, not call prefetch/execute directly.

  Interim debt: server.zig's followup condition checks `resp.cookie_action == .none and resp.result != .login` to skip followup for login mutations. This is the server inspecting result types — domain logic in the framework. Once refresh is opt-in, remove this condition and the needs_dashboard_refresh field on MessageResponse (added but unused pending this ticket). Each operation's render path calls refresh explicitly or not.

- what is the error handling at the framework level? how does it work when does it trigger?

---
Ticket 6: Split replay tests into framework vs application

  The replay module mixes framework-level tests (WAL integrity, hash chain, truncation recovery) with application-level tests (product round-trip, updates/deletes, stop-at). The application tests depend on Product, make_product, and specific field assertions (price_cents, version, name). If Product changes, framework tests break even though the framework didn't change.

  Split:
  - Framework side (replay.zig): WAL create/recover, root deterministic, hash chain validation, truncation recovery, version mismatch, verify valid/corrupt, read_batch, derive_work_path, format_uuid, body_to_json, write_json_string. replay_entries stays here — it's Message-generic.
  - Application side: "full round-trip", "stop-at", "updates and deletes" move out. replay_fuzz.zig stays application-side — it knows about products, collections, orders, login codes.

  Same code coverage, same test count. The split is module ownership, not new work. Framework tests never import application types. Application tests call replay_entries from the application side.

---
Ticket 7: Missing replay test coverage

  kcov shows replay.zig at 94.7% (409/432 lines). The uncovered paths:

  1. query() — the most complex untested function. Loads WAL entries into an in-memory SQLite table, runs user SQL, prints results. Zero test coverage. Fixed-input test: create a WAL with known entries, run "SELECT count(*) FROM entries", "SELECT * FROM entries WHERE operation = 'create_product'", assert output matches. Also test: empty WAL (only root), invalid SQL (error message).

  2. replay_entries() via the fuzzer — kcov marks some lines as uncovered due to debug info artifacts, but the fuzzer does exercise this path. Confirm by running kcov on the fuzz binary with a fixed seed.

  3. entity_id() — exhaustive switch mapping operations to their entity ID. Tested indirectly through inspect, but no direct test that each branch extracts the correct ID. Fixed-input test: construct a Message for each operation type that carries an entity ID in the body (create_product, create_collection, create_order), assert entity_id returns the body's ID, not msg.id.

  query() is the priority — it's real untested logic, not debug info noise.

  Aggregate coverage (kcov, unit + fuzz + sim merged):
    checksum.zig       100.0%    auth.zig           100.0%
    http.zig            99.4%    render.zig          99.1%
    state_machine.zig   99.0%    message.zig         98.8%
    connection.zig      98.2%    wal.zig             95.9%
    auditor.zig         95.3%    sim.zig             95.1%
    replay.zig          94.7%    server.zig          94.5%
    codec.zig           94.2%    storage.zig         93.3%
    tracer.zig          90.1%    io.zig              28.6%
    TOTAL               96.8%   (9634/9958 lines)

  io.zig is 28.6% — expected, it's the real epoll layer. Tests use SimIO.
  Fuzz + sim add the most to storage.zig (+18%) and codec.zig (+16%).

- stressor (multi tenant user)

---
Inspect later: framework split decisions

  1. Login code logging removed from server.zig. Currently no way to see login codes
     without querying the DB directly or using tiger-replay inspect. Need a worker
     that polls for pending login codes and sends them (email service or logs).
     Schema needs a "sent" flag on login_codes table, plus a list endpoint.

  2. Followup decision moved from server.zig into state_machine commit().
     Operation.needs_followup() is an exhaustive switch — adding a new mutation
     forces a decision. Verify this stays correct as new operations are added.
     The server now reads resp.followup without inspecting which operation ran.

---
Ticket 8: Defer writes to end of tick (pure execute)

  Execute handlers currently call storage.put/delete/insert during execute().
  This means operations processed earlier in the tick are visible to later
  operations in the same tick — an accidental ordering dependency.

  Change execute() to return {response, writes[]} instead of calling storage
  directly. The framework collects all writes from all operations in the tick,
  then applies them in one batch after all executes complete.

  This fixes intra-tick visibility (operations see tick-start state, not each
  other's writes) and enables the sidecar execute model (see design/012).

  Write failures after execute: framework overrides the response with
  storage_error and rolls back the transaction. Same pattern as prefetch
  errors today.

  Do this before implementing the sidecar — it's the same change.
