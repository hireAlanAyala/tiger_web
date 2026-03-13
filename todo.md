questions
- would SSE connections count towards the connection slots?
- put nginx in front of server?

remaining patterns not yet exercised:
- rate limiting — cross-cutting concern at the connection or commit loop layer
- full-text search — storage concern (SQLite FTS), different access pattern than key lookup or cursor pagination

image processing design (decided):
- images stay outside the state machine — client uploads to filesystem, worker processes
- state machine tracks job metadata (id, status, result) only
- worker reads from filesystem, resizes, does domain logic (diff, color scan), posts result back
- result is small (histogram, diff score, pixel count) — fits in fixed-size struct
