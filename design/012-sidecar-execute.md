# Sidecar Execute Model

## Core Idea

Make execute() a pure function that returns decisions + write commands.
The framework owns all IO and storage. The execute phase can run in
Zig, WASM, or a sidecar process over a unix socket — the framework
doesn't care.

## Pipeline

```
prefetch()  → framework reads storage, caches results
execute()   → pure function: {operation, cached_data} → {response, writes[]}
apply()     → framework batches writes into one transaction (one fsync per tick)
```

Execute never touches storage. It receives prefetched data, makes a
decision, and returns what to write. The framework validates and applies.

## Why pure execute

**Replay works without the sidecar.** The WAL records every message.
The message deterministically produces the same writes. Replay is
framework-only — the sidecar can be offline, crashed, or rewritten.

**The framework validates writes.** Before applying, the framework can
reject invalid keys, enforce constraints, assert invariants. Bugs in
business logic don't corrupt storage — the framework gate-keeps.

**Writes are automatically batched.** The server already wraps each
tick in begin_batch/commit_batch. Execute returns write commands, the
framework collects them from all operations in the tick, applies in
one transaction. One fsync, same as today.

## Write commands

Structured, not raw SQL. The framework validates before applying:

```
Write = union(enum) {
    put:    { table, key, value },
    delete: { table, key },
}
```

The storage layer translates these to SQL. The app never touches a
database handle.

## Sidecar transport options

| Transport          | Latency    | Notes                                      |
|--------------------|------------|--------------------------------------------|
| Native Zig         | ~10ns      | No sidecar — execute is compiled in        |
| WASM (embedded)    | ~100ns     | Sandboxed, deterministic, no IPC           |
| Unix socket        | ~20-50μs   | Separate process, any language              |
| Shared memory      | ~2μs       | mmap + futex, complex protocol             |

SQLite write in WAL mode is ~50-100μs. The sidecar hop is noise — storage
is the bottleneck. At 50μs per call, the framework handles 20,000 ops/second
through a unix socket. A busy ecommerce site does 50-100 orders per minute.

## Why unix socket is viable

The tick already batches all writes into one SQLite transaction. The
fsync cost dominates. Adding 20-50μs for a socket round trip doesn't
move the needle — you're already waiting for storage.

WASM is faster and avoids managing a separate process, but the socket
is architecturally fine. Choose based on developer ergonomics, not
performance.

## Type boundary

Extern structs with no_padding are C ABI compatible. The message body
maps directly to memory in WASM or across a socket — no serialization,
just memcpy. A transpiler generates equivalent type definitions in the
sidecar's language from the Zig source.

## What stays in Zig

Tick loop, connection pool, epoll IO, HTTP parsing, WAL, auth/cookies,
storage reads, storage writes, response rendering, fuzz infrastructure.

## Determinism: assured → probabilistic

In native Zig, determinism is assured. The compiler enforces no hidden
state, no allocations, no syscalls in execute. The PRNG is seeded and
reproducible. Replay is guaranteed to produce identical results.

Moving execute to a sidecar trades assured determinism for probabilistic
determinism. The sidecar's language runtime may have:
- Floating point differences across platforms
- HashMap iteration order varying between versions
- Garbage collector non-determinism affecting timing
- Hidden global state (thread locals, locale, timezone)
- Library upgrades that change behavior for the same inputs

The framework cannot enforce determinism across a process boundary.
It can only verify it after the fact.

**Required: determinism assertion.** The framework must assert that
sidecar execute is deterministic by replaying a subset of committed
operations and comparing results. Two strategies:

1. **Online spot-check.** After every N commits, re-execute the last
   operation with the same inputs and assert the response and writes
   match byte-for-byte. Catches non-determinism as it happens. Cost:
   one extra sidecar call per N operations.

2. **Offline replay audit.** Periodically replay the full WAL through
   the sidecar and assert every response matches. Catches drift from
   runtime upgrades, library changes, or platform differences. Run as
   a CI job or pre-deploy check.

Both are needed. Online catches immediate non-determinism (HashMap
ordering, GC timing). Offline catches slow drift (library upgrades,
platform migration).

WASM has an advantage here — WASM execution is specified to be
deterministic (no non-determinism in the spec except explicit random
imports, which the framework controls). A WASM sidecar gets assured
determinism back. Unix socket sidecars in interpreted languages do not.

## What moves to the sidecar

The execute decision: given this operation and this cached data, what's
the status, what's the result, what writes should happen. Pure function,
no side effects, deterministic.
