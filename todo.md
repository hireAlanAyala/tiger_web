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

Migration
you test it by running against a prod copy — that's the workflow.
The migration arm (e.g., 1 => exec(db, "ALTER TABLE ...")) won't exist until you write your first real migration.
Testing it now would mean testing a no-op. When you write a real migration,

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
