# Unix Socket Sidecar

## Prerequisite

Ticket 8: pure execute. Execute handlers return `{response, writes[]}`,
dispatch loop applies writes. All in Zig, all tests passing. No sidecar
code until this is done.

## Overview

The Zig framework connects to a sidecar process over a unix domain
socket. The sidecar runs the execute phase in any language. The
framework owns everything else: HTTP, IO, WAL, auth, storage reads,
storage writes, rendering.

Default is Zig-native (no socket). Sidecar is opt-in via CLI flag:
`--sidecar /tmp/tiger-web.sock`

## Protocol

Fixed-size binary. No JSON, no framing negotiation. One request, one
response, synchronous. The Zig server is single-threaded — one
connection to the sidecar is enough.

**Request (Zig → sidecar):**
```
operation:      u8
id:             u128
body:           [body_max]u8
prefetch_cache: [cache_size]u8   (serialized, fixed layout)
```

**Response (sidecar → Zig):**
```
status:     u8
result:     [result_max]u8
writes_len: u8
writes:     [writes_max]Write
```

The Message body and all domain types are extern structs with
no_padding — byte-copyable with known field offsets. The prefetch
cache is flattened into a fixed-size buffer with presence flags
for optional fields (1 byte per optional: 0 = null, 1 = present,
followed by the value bytes).

## Comptime-generated validation

The Zig compiler knows the exact byte layout of every type at
comptime via `@typeInfo`. The validator is generated from the same
type definitions the Zig handlers use:

- Status byte must be a valid `Status` enum value
- Each write must target a valid table index
- Each write key must be non-zero
- Response size must match `@sizeOf(ExecuteResult)`
- Field offsets match the extern struct layout

The validator is always in sync with the types because it IS the
types — generated from comptime `@typeInfo`. Change a field in Zig,
the validator changes automatically. No manual protocol versioning.

This is stronger than a sidecar-language type check: TypeScript
checks structural shape, the Zig validator checks byte-level layout.
A structurally correct TypeScript object with wrong serialization
offsets is caught. The error message says exactly which field or
value is wrong.

## Zig side

**Socket client.** Connect at startup if `--sidecar` flag is set.
Reconnect on failure with backoff.

**Sidecar execute path.** In `commit()`, if sidecar is connected:
serialize inputs → send → recv → validate → apply_writes. If not
connected or call fails: return storage_error (same handling as
SQLite write failure).

**Fallback.** No automatic fallback to Zig-native. The sidecar is
either the execute path or it isn't. Mixing would break determinism —
some operations through Zig, some through the sidecar, different
results for the same input. If the sidecar is down, requests fail
until it's back. The operator restarts it, same as restarting any
other dependency.

**Spot-check.** Every N commits, also run the Zig-native execute on
the same inputs. Compare response + writes byte-for-byte with sidecar
output. Log divergence as an error. Catches non-determinism from GC,
HashMap ordering, runtime version changes.

## TypeScript sidecar

**Socket server.** Node.js `net.createServer` on the unix socket
path. Single connection. Read binary request, call user handler,
write binary response.

**Startup:** `node sidecar.js --socket /tmp/tiger-web.sock`

**User code structure mirrors Zig 1:1.** Same files, same functions,
same explicit switches. No DSL, no inferred prefetch, no magic. The
Zig API is the abstraction — TypeScript is just another syntax for it.

## Type generation

`zig build codegen` reads the app's Zig types at comptime and emits
TypeScript files. Same comptime introspection as `graph_comptime.zig`.

**Generated files:**
- `types.generated.ts` — domain structs as TypeScript interfaces
  (Product, Order, Collection, etc.)
- `protocol.generated.ts` — Operation and Status as string unions,
  PrefetchCache interface, Write union, ExecuteResult type
- `serde.generated.ts` — binary ↔ TypeScript serialization functions
  (field offsets derived from Zig extern struct layout)

The generated types give the TypeScript developer full LSP support:
autocomplete, hover, go-to-definition, rename. The type imports tell
the developer what operation a function handles — if it takes
`OrderRequest`, you know.

## Dynamic language support

The unix socket doesn't care what's on the other end. Python, Ruby,
Lua — anything that reads and writes the binary protocol works.

What you lose without TypeScript's generated types:
- No compile-time type checking (field typos, wrong shapes)
- No IDE autocomplete on domain types
- Codegen for each language must be built separately

What you keep regardless of language:
- Comptime-generated Zig validation catches every invalid response
- Spot-checks catch non-determinism
- WAL replay works (framework-only, sidecar not needed)

| Sidecar language | Wrong return type caught by       |
|------------------|-----------------------------------|
| Zig (native)     | Zig compiler, build time          |
| TypeScript       | TS compiler via generated types   |
| Python/Ruby/Lua  | Framework validation, first call  |

## Build order

```
1. Ticket 8: pure execute           ← no sidecar, Zig only
2. Protocol design                   ← nail down binary format
3. Type generation (zig build codegen)
4. TypeScript sidecar                ← socket server + serde + handlers
5. Zig socket client + validation    ← connect, send, recv, validate
6. Spot-check                        ← determinism verification
```

Each step is independently testable. Type generation is useful on
its own (documentation, external tooling). The sidecar can be tested
by sending manual binary requests. The Zig socket client can be
tested with a mock sidecar.

## Not in scope

- WASM transport (future, for Rust sidecars)
- Auto-start sidecar from `zig build run`
- Hot reload of sidecar code
- Multiple concurrent sidecars
- Automatic fallback to Zig-native on sidecar failure

## Performance

SQLite write (WAL mode): ~50-100μs. Unix socket round trip: ~20-50μs.
The sidecar hop is noise — storage is the bottleneck. At 50μs per
call, the framework handles 20,000 ops/second through the sidecar.
A busy ecommerce site does 50-100 orders per minute. Three orders of
magnitude of headroom.
