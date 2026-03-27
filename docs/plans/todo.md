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

Expected result: sidecar throughput approaches native speed. The 5ms
round trip overhead drops to ~0.1ms (futex wake + cache line transfer).

This is a protocol-level change to `sidecar.zig` and
`generated/dispatch.generated.ts`. The handler interface doesn't change.

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
how does our server shard compared to others if we cant handle traffic?
is there a way that we could a come close to go lang throughput without more cores based on our simpplicity
are we truly no allocation on hot path? what are the possible side effects to the framework users or end users? did this concept map cleanly to web servers
❯ should we always recommend perf over providing an instrucmented perf command?                                                                                                                
speculating how do we measure in throuput against laravel,rails,nextjs all connected to sqlite
what might the throughput difference be if we gave up single-threaded for multi threaded
document perf permanent docs

Explore open source repos and see if they use ai
