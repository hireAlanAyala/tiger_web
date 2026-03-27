# Decision: Sidecar architecture — unexpected development speed advantage

## Status: Observed (2026-03-27)

## Context

The sidecar architecture was chosen for language flexibility — run
handler business logic in TypeScript/Python while the framework runs
in Zig. The assumed trade-off: unix socket overhead + binary protocol
serialization = slower requests than native Zig handlers.

## Unexpected finding

The sidecar path has a FASTER development inner loop than native Zig:

| Path | Incremental rebuild |
|---|---|
| TypeScript handler change | **263ms** (scan + codegen) |
| Zig handler change | **1.7s** (recompile binary) |
| Zig no-op (nothing changed) | **56ms** |

The TypeScript developer changes a handler and rebuilds in 263ms.
The Zig developer changes a handler and waits 1.7s for recompilation.

## Why

The sidecar build is: run the scanner (compiled Zig binary, ~50ms)
+ write dispatch.generated.ts (text file, ~10ms) + Node.js loads the
new file. No compilation step — the handler is interpreted.

The native build is: Zig recompiles the entire binary including
all 24 handler modules. Zig's incremental compilation is fast (1.7s)
but can't beat "don't compile at all."

## Consequence

The sidecar isn't just a language flexibility feature — it's a
development speed feature. The framework (Zig) provides the
correctness guarantees (assertions, comptime checks, fuzz testing).
The sidecar (TypeScript) provides the fast iteration loop. The
developer gets both: TB-level correctness AND sub-second rebuilds.

This is an argument FOR the sidecar architecture, not against it.
The binary protocol overhead (~1ms per request) is invisible compared
to the 1.4s saved on every rebuild during development.
