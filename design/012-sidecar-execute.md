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

Structured, not raw SQL. Put and update only — no deletes. The
framework validates before applying:

```
Write = union(enum) {
    put:    { table, key, value },
    update: { table, key, value },
}
```

No delete command exists. Data is never removed:

- **Collections** soft-delete via a flag, same as products.
- **Collection membership** soft-delete via a `removed` flag on the
  junction row.
- **Login codes** expire naturally via `expires_at` — no deletion
  after verification. The storage layer ignores expired codes on read.

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

## Sidecar language binding: 1:1 mirror, not a DSL

The sidecar code mirrors the Zig app structure exactly. Same files,
same functions, same explicit switches. No magic prefetch inference,
no declarative routing, no hidden conventions. The Zig API is the
abstraction — the sidecar language is just another syntax for it.

```
message.ts       ← generated from message.zig (types, Operation, Status)
codec.ts         ← same translate function, same explicit routing
state_machine.ts ← same prefetch/execute split, same explicit handlers
render.ts        ← same HTML functions
```

Why 1:1 and not a DSL: we prototyped a declarative model (inferred
prefetch, `Prefetched<T>`, route declarations). It worked for simple
CRUD but broke on multi-entity operations (create_order needs N products),
dependency-chain prefetch (complete_order fetches order then its products),
and cross-entity pages (dashboard). The Zig API already solves these
cases explicitly. Adding abstractions on top created edge cases the
Zig code doesn't have.

## Annotation-based binding

The developer is free to organize files however they want. The binding
between functions and operations is a comment annotation, not a file
structure:

```typescript
// orders/checkout.ts

// [execute] .create_order
export function createOrder(cache: PrefetchCache, msg: Message) {
  // ...
}

// orders/render.ts

// [render] .create_order
// [render] .get_order
export function renderOrderDetail(order: OrderResult): string {
  // ...
}
```

One annotation can cover multiple operations (same as Zig where
execute_get handles four operations). The function name and file path
don't matter. The annotation is the contract.

## Build step enforces exhaustiveness

The build step scans all sidecar source files for annotations:

1. Collects all `// [execute]`, `// [prefetch]`, `// [render]`,
   `// [translate]` annotations
2. Knows all Operation variants from the Zig source (generated)
3. Missing operation → build error
4. Duplicate operation → build error
5. Generates the dispatch that routes operations to annotated functions

This preserves the exhaustiveness guarantee. Adding a new operation
to the Zig Operation enum fails the sidecar build until the developer
adds the corresponding annotated handler. Same safety as Zig's
exhaustive switch, different mechanism.

## LSP and type checking

Annotations are comments — the language server ignores them. The
function signatures use generated types (from the Zig source).
Autocomplete, hover, go-to-definition, rename all work normally.

The annotations tell the build step which function handles which
operation. The type imports tell the developer — if a function takes
`OrderRequest`, you know what operation it handles without reading
the comment. The comment is for the machine, the type is for the human.

## Zig-native is the default: the compiler as tooling

The sidecar is an option, not the default. For most users, writing
handlers in Zig with a file watcher (`zig build` on save) gives the
same feedback loop as a TypeScript LSP — under one second from save
to error with exact line numbers. The Zig compiler IS the linter.

What the compiler catches that a sidecar annotation system cannot:

- **Exhaustive switches.** Add an Operation variant, every switch in
  codec, state_machine, render fails with the exact missing arm.
  Annotations can check coverage at build time but can't point to
  the switch arm you need to add.

- **Type mismatches at every boundary.** Return the wrong result
  variant for an operation → compile error on the exact line. The
  sidecar validator catches this at the protocol boundary, one hop
  removed from the cause.

- **Comptime assertions.** body_max derived from EventType, Message
  layout validated with no_padding, Status must have .ok, Operation
  must have is_mutation. These run at compile time, not at the protocol
  boundary. The error points at the declaration, not at a runtime
  validation failure.

- **Refactoring safety.** Rename a field → every usage updates or
  fails. Rename an operation → every switch arm updates or fails.
  Comment annotations don't participate in rename-symbol.

- **One debugger, one stack trace.** The request flows through Zig
  from accept to send. No language boundary to cross, no split stack
  traces, no "the error is in TypeScript but the context is in Zig."

- **Fuzz and replay with zero overhead.** The fuzzer calls prefetch
  and execute directly — no socket, no serialization. Thousands of
  iterations per second. The auditor validates in-process. WAL replay
  is deterministic without qualification.

The sidecar trades these for language familiarity and ecosystem access.
For pure business logic (if statements and arithmetic on prefetched
data), there's no library to import and nothing the sidecar language
adds that Zig doesn't provide. Build the sidecar when someone needs
it — the architecture supports it. Ship Zig-native by default.

## Current state

Pure execute is implemented. Handlers return `ExecuteResult`
(response + writes). The dispatch loop applies writes via
`apply_write()`. Handlers never call storage directly. No deletes —
soft-delete via flags, expiry via timestamps. Write union covers
put/update for all entity types.

See design/013-unix-socket-sidecar.md for the transport implementation
scope.

## What moves to the sidecar

The execute decision: given this operation and this cached data, what's
the status, what's the result, what writes should happen. Pure function,
no side effects, deterministic.
