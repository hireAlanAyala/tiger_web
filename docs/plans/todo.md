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

# Storage boundary gaps (from audit)

High priority:
- Assert bind parameter count matches SQL placeholders (1 line)
- Assert bind return codes `rc == SQLITE_OK` (~10 lines)

Medium priority:
- Assert column names match struct field names on first row (~15 lines)

Low priority:
- Retry cap on busy (storage can retry forever)
- query/query_all error discrimination (interface change)
- query_all truncation detection (documentation or comptime)
- Write failure model: panics (TB) vs returned errors (web) — decide

## WAL filename derived from database path

The application-level WAL filename is hardcoded to `tiger_web.wal`.
Every server instance (dev, load test, perf script) writes to the same
file, corrupting each other's replay chain.

Fix: derive from `--db` path. `--db=tiger_web.db` → `tiger_web.db.wal`.
Same convention as SQLite's own WAL (`tiger_web.db-wal`). The WAL
file lives next to the database, obvious pairing, no conflicts.

Change in `main.zig`: replace `"tiger_web.wal"` with
`db_path ++ ".wal"`. Load test and perf script cleanup already
delete the db file — the paired WAL deletes with it.

## Sidecar: shared memory transport to replace Unix socket

The sidecar is 3.9x slower than native Zig (13K vs 53K req/s). The
cost is 3 Unix socket round trips per request (~5ms), not the
TypeScript runtime. p50 goes from 2ms to 7ms — the socket overhead
is the floor regardless of sidecar language.

Sidecar handlers are pure functions: data in, data out. They can't
hold state or corrupt memory. A buggy handler produces wrong HTML,
not memory corruption — caught by tests, same as Zig handlers. Process
isolation via socket buys nothing that testing doesn't already provide.

Proposal: replace the Unix socket with shared memory (mmap) and a
doorbell (eventfd/futex). The server writes request data into a shared
ring buffer, signals the sidecar, the sidecar writes the response into
the same buffer. Zero kernel round trips, zero serialization for
fixed-size fields, zero copy.

Expected result: 13K → 35-45K req/s (from 3.9x slower to ~1.3-1.5x
slower than native). The 5ms round trip overhead drops to ~0.1ms
(futex wake + cache line transfer). Remaining gap is V8 computation
time, not transport. The sidecar becomes nearly free in throughput
terms — the developer experience tradeoff (TypeScript, instant
rebuilds) costs ~30% instead of ~75%.

Safety model: the server owns the shared memory region — creates it,
maps it, controls the layout. The sidecar writes into designated
response slots at known offsets with known sizes. Neither process
touches the other's private memory.

Why this is safer than sockets:
- No frame parsing. Socket transport requires a frame parser that
  could read past buffer bounds on malformed input (the WAL aliasing
  bug was this class of problem). Shared memory has fixed-size slots
  at comptime-known offsets. Nothing to parse, nothing to overflow.
- Fixed layout via comptime, not process isolation via kernel. This
  is the TigerBeetle model — trust the layout, verify with assertions,
  fuzz the boundary.

Crash recovery: if the sidecar crashes or writes garbage, the server's
eventfd wait times out (same as socket disconnect today). The server
zeros the shared region (it owns it), the sidecar restarts, re-maps
the same region, resumes. Same recovery path as socket disconnect.

Why process isolation via socket is unnecessary: sidecar handlers are
pure functions. They can't hold state, can't corrupt memory, can't
affect other requests. A buggy handler produces wrong HTML — caught
by tests before shipping, same as Zig handlers.

### Why shared memory, not embedded V8

Embedding V8 (like Bun/Deno) would eliminate IPC entirely — handlers
become function calls within the same process. But embedding a JS
runtime is a massive dependency (Bun is 300K+ lines largely because
of this), and it's JavaScript-only. A Go sidecar would need a
different embedding, Python another.

Shared memory is language agnostic. Any language that can mmap a file
and read/write bytes at fixed offsets works — TypeScript, Go, Rust,
Python, Java. The protocol is just bytes at known positions. The
sidecar doesn't know the server is written in Zig. Write a Go sidecar,
a Rust sidecar, a Python sidecar — they all map the same buffer, read
the same offsets, write the same format.

Shared memory gets 90% of the speed benefit of embedding with 1% of
the complexity, and it works for every language.

This is a protocol-level change to `sidecar.zig` and
`generated/dispatch.generated.ts`. The handler interface doesn't change.
Existing sidecar fuzz tests (10K protocol exchanges, 7 paths) cover
the same data format — only the transport changes.

Measured data (i7-14700K, 128 connections, 100K requests):
- Native Zig: 53,048 req/s, p50=2ms, p99=2ms
- Sidecar (TypeScript, Unix socket): 13,642 req/s, p50=7ms, p99=22ms

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
- Marketing: fuzz test counter in repo, open-source counter program, coverage CLI with branching
- rotate github pad code, we leaked it in claude
- figure out a webscraping + html assertion flow
- figure out how to ingest large payloads from post like images etc, without passing the heavy data through the tick and passing a reference instead (local object storage, but auto hidden frm user)
- add a way to inspect the start/stop time for all annotations/features and read trends so you can see when things are getting slow.
- some things are tested against /examples for regression/performance we might want to isolate some of these tests into more user space agnostic code to protect them from example churn
- worst case json allocation in message should probably be configurable in case a framework user needs to up the value
- is ci/cd tracking benchmarks/loadtest/perf?

# clean up
- ensure we use cli/program defaults very carefully. i like no defaults or few defaults over heavy defaults
- think about 10 years from now, what parts of the user space would have likely been violated? we should pull back a primitive for these.



Theres a pattern of annotations needing settings
[worker]
interval 5s
timeout 3m
it's probably best to collapse this to
[worker]
settings: interval 5s, timeout 3m, etc..
====
So we can enforce settings sitting directly under the annotation and we can keep the space between annotation and function super tight


Questions:
Explore open source repos and see if they use ai


