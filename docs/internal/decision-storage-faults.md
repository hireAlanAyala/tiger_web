# Decision: No per-operation storage fault injection

## Status: Adopted (2026-04-01)

## Context

SQLite's testing infrastructure injects I/O errors at every layer through a
custom VFS. Each individual read/write can fail, and the test suite verifies
SQLite handles every failure gracefully. After reviewing SQLite's testing page,
we considered whether we need per-operation fault injection on our storage
interface (ReadView/WriteView).

We don't. The reasoning comes from clarifying what the framework is responsible
for versus what the storage backend is responsible for.

## Framework responsibility: two buckets

The framework sees storage through exactly two outcomes:

1. **Transient failure → retry.** Prefetch returns null. The state machine
   retries next tick. The framework doesn't know or care why storage said "not
   now" — it just knows to try again.

2. **Unrecoverable failure → crash.** An assert fires. The process dies. No
   attempt to recover, no risk of operating on corrupt state.

These two responses are database-agnostic. They work for SQLite, Postgres,
DuckDB, or anything else. The framework's contract is: fail safely on transient
hiccups, crash on anything unsafe.

## Storage backend responsibility: classify errors

Each storage implementation maps its own error codes into the two buckets:

- SQLite: `SQLITE_BUSY` → transient. `SQLITE_CORRUPT`, `SQLITE_IOERR` → crash.
- A Postgres backend would map serialization failure → transient, connection
  lost → crash.

This classification lives inside the storage backend, not in the framework. The
framework never sees database-specific error codes.

## Why per-operation fault injection doesn't fit

A generic fault injector that fails individual ReadView/WriteView operations
would be testing a made-up error model. "Storage busy" means something specific
to SQLite. Postgres doesn't have that error — it has serialization failures,
connection timeouts, replication lag. These aren't the same fault with different
names. They're different faults requiring different handling, and that handling
belongs in the backend.

The only generic faults are "not ready" and "broken," and we already test both:

- **"Not ready"** is tested by the prefetch busy fault in `app.zig`. This
  injects at the prefetch dispatch boundary — the point where the framework
  decides to retry. It's a framework concern, so it lives above storage.

- **"Broken"** is `assert(ok)` / `@panic`. The correct behavior is crashing.
  There's nothing to inject because the test is: does the process die cleanly
  without corrupting the WAL or leaving partial state? The WAL replay fuzzer
  already covers crash-during-commit scenarios.

## Why this looks like a gap but isn't

SQLite needs per-operation fault injection because SQLite handles errors at every
layer — it recovers from I/O errors, retries busy locks, rolls back partial
transactions. Every recovery path is code that can have bugs, so every recovery
path needs testing.

We don't recover from storage errors. We either retry the whole prefetch (bucket
1) or crash (bucket 2). There's no per-operation recovery code, so there's no
per-operation recovery code to test.

## What we test instead

| Concern | How tested | Where |
|---|---|---|
| Framework retries on transient failure | Prefetch busy fault (PRNG) | `app.zig` fault injection |
| SM handles null prefetch correctly | Sim tests with busy faults | `sim.zig` |
| Crash doesn't corrupt WAL | Replay round-trip fuzzer | `replay_fuzz.zig` |
| SQLite and WAL stay in sync after crash | Seeded corruption test (100 iterations) | `replay_fuzz.zig` |
| Network faults during any phase | SimIO per-operation fault injection | `sim.zig` |
