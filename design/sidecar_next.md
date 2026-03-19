# Sidecar — next steps

## 1. Annotation scanner — DONE

Scanner validates `[route]`, `[handle]`, `[render]` annotations.
Outputs JSON manifest. Clickable file:line errors.

## 2. Adapter system — DONE

TypeScript adapter reads manifest, extracts function names,
generates dispatch.generated.ts. Language-agnostic manifest
enables community-contributed adapters.

## 3. Full sidecar simulator test

Run the existing PRNG-driven simulator through the sidecar path.
The simulator generates random operations, runs them through the
sidecar, and validates responses structurally (correct status
codes, valid HTML, no crashes).

This exercises every operation, every cache slot, every write
variant, and every render path through the real socket protocol.
Deterministic seeds for reproducibility.

Structure: the sim test starts the TS sidecar as a child process,
starts the Zig server with `--sidecar`, runs the full operation
sequence, and verifies no failures.

This exercises the full stack with random inputs. Crashes, wrong
status codes, and protocol errors surface as test failures with
deterministic seeds for reproduction.

## 4. Battle testing

Run the sidecar in development against the real application.
Manual testing, edge cases, performance profiling. Fix issues
as they surface. No documentation until the system is proven.

Documentation comes after battle testing, not before.
