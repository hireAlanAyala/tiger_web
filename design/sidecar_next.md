# Sidecar — next steps

## 1. Annotation scanner

Codegen scans user TS files for `// [translate]`, `// [execute]`,
`// [render]` annotations. Verifies every Operation has a handler.
Missing → build error with clickable `file:line`. Duplicate → build
error with both locations.

Language-agnostic — scans comments, works for any sidecar language.
Runs during `zig build codegen`. The scanner is a new pass in the
existing codegen binary that reads source files from a configured
directory (e.g., `ts/`).

Output: `generated/dispatch.generated.ts` — imports annotated
functions and wires them into the sidecar socket server dispatch.

## 2. Generated sidecar dispatch

The scanner output replaces the hand-written `ts/sidecar.ts` routing.
The generated dispatch reads the tag byte, calls the annotated
translate/execute/render function, writes the response. The developer
never touches socket or protocol code.

```
zig build codegen
  → scans ts/*.ts for annotations
  → generates dispatch.generated.ts
  → developer runs: node generated/dispatch.generated.ts /tmp/tiger.sock
```

## 3. Full sidecar simulator test

Run the existing PRNG-driven simulator through the sidecar path.
The simulator generates random operations, runs them through both
native and sidecar, and the spot-check catches any divergence.

This exercises every operation, every cache slot, every write
variant, and every render path through the real socket protocol.
Deterministic seeds for reproducibility.

Structure: the sim test starts the TS sidecar as a child process,
starts the Zig server with `--sidecar`, runs the full operation
sequence, and verifies no spot-check failures.

```bash
./zig/zig build test -- --sidecar    # sim tests through sidecar
```

This is the correctness proof — the spot-check running on every
operation with PRNG-driven inputs. If the sidecar's translate,
execute, or render disagrees with native on any operation, the
simulator finds a seed that reproduces it.

## 4. Battle testing

Run the sidecar in development against the real application.
Manual testing, edge cases, performance profiling. Fix issues
as they surface. No documentation until the system is proven.

Documentation comes after battle testing, not before.
