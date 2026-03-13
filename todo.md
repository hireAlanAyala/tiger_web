questions
- would SSE connections count towards the connection slots?
- put nginx in front of server?

remaining patterns not yet exercised:
- rate limiting — cross-cutting concern at the connection or commit loop layer

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
