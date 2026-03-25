# Snapshot testing + CI/CD

## Snapshot testing

### What TB does

TigerBeetle's `stdx/testing/snaptest.zig` provides a `Snap` type that:
- Compares formatted output against an expected string literal in the source
- On mismatch, prints a diff
- With `SNAP_UPDATE=1`, auto-rewrites the source file to match the actual output
- Supports `<snap:ignore>` markers for non-deterministic parts (timestamps, IDs)

The pattern replaces `expectEqual` for complex types — instead of asserting
field-by-field, you format the value as a string and compare against a snapshot.
Refactors that change output format update all snapshots with one env var.

### Where we'd use it

- **Render output verification** — assert that a handler's render produces
  specific HTML. Currently render tests check `body_contains("Updated")`.
  Snapshots would check the full HTML output, catching layout regressions.

- **SSE framing** — assert that SSE event output matches expected format.
  The `encode_patch_event` / `encode_signal_event` output is structural
  and sensitive to framing.

- **WAL entry format** — assert serialized WAL entries match expected binary
  layout (hex-encoded snapshots). Catches accidental format changes.

- **Protocol wire format** — assert binary row format output matches expected
  bytes. The cross-language vector tests already do this with files, but
  snapshots would be inline and self-updating.

### Implementation

Port TB's `snaptest.zig` into `framework/snaptest.zig`. The implementation
is ~200 lines — a `Snap` struct that holds `@src()` location + expected string,
a `diff` method, and a file-rewriting path guarded by `SNAP_UPDATE=1`.

### When

After the simulation testing API is built. Snapshots are most valuable when
there's complex formatted output to verify — right now our assertions are
simple enough that `assert(body_contains(...))` works.

## CI/CD

### What TB does

- **Commit hash as seed** — CI passes the git commit hash as a fuzzer seed
  via `parse_seed`. Failures are reproducible from the commit alone. The
  hash is 40 hex chars, truncated to u64. Different commits exercise
  different state space regions automatically.

- **Tiered test runs:**
  - Fast: unit tests + smoke fuzzers (seconds)
  - Medium: simulation with moderate event counts (minutes)
  - Long: VOPR with millions of ticks + fault injection (hours, nightly)

- **Deterministic reproduction** — every CI failure includes the seed.
  A developer copies the seed, runs locally, gets the exact same failure.

- **Exit codes** — different codes for correctness (129) vs liveness (128)
  vs crash (127). CI dashboards distinguish failure types.

### Our CI plan

#### Phase 1: Basic CI (GitHub Actions)

```yaml
# .github/workflows/test.yml
- zig build unit-test          # unit tests
- zig build test               # 27 sim tests + 3 PRNG fuzz seeds
- zig build fuzz -- smoke      # all fuzzers, small event counts
- zig build scan -- handlers/  # annotation validation
```

Every PR runs this. Total time: ~30 seconds.

#### Phase 2: Commit-seeded fuzzing

```yaml
# Use git commit hash as fuzzer seed
- SEED=$(git rev-parse HEAD)
- zig build fuzz -- state_machine $SEED
- zig build fuzz -- --events-max=50000 state_machine $SEED
```

Add `parse_seed` to accept 40-char hex (git hash), truncate to u64.
Different commits explore different state space. Failures reproduce
from the commit.

Implementation: add to `fuzz_lib.zig`:
```zig
pub fn parse_seed(bytes: []const u8) u64 {
    if (bytes.len == 40) {
        // Git commit hash — truncate to u64.
        const hash = std.fmt.parseUnsigned(u160, bytes, 16) catch
            @panic("invalid commit hash seed");
        return @truncate(hash);
    }
    return std.fmt.parseUnsigned(u64, bytes, 10) catch
        @panic("invalid seed");
}
```

#### Phase 3: Extended nightly runs

```yaml
# Nightly: longer fuzz runs
- zig build fuzz -- --events-max=500000 state_machine
- zig build fuzz -- --events-max=100000 sidecar
- zig build fuzz -- --events-max=100000 replay
```

Random seeds (no argument), longer runs. Failures create issues with
the seed for reproduction.

#### Phase 4: Cross-language CI

```yaml
- npm run build                            # TS sidecar build
- zig build scan -- examples/ecommerce-ts/ # annotation scan
- zig build test-adapter                   # TS adapter tests
- npx tsx generated/serde_test.ts          # cross-language vectors
```

Validates the sidecar pipeline end-to-end.

### Distinct exit codes

Already designed in test-output.md:

| Exit code | Meaning |
|---|---|
| 0 | All tests passed |
| 1 | Test assertion failed (correctness) |
| 2 | Test timed out (liveness) — future |
| 127 | Crash (panic, signal) |

CI scripts use exit codes to classify failures in dashboards.

## Delivery order

1. Add `parse_seed` to `fuzz_lib.zig` (accept git hash as seed)
2. Basic CI workflow (unit-test + test + fuzz smoke + scan)
3. Commit-seeded fuzzing in CI
4. Port `snaptest.zig` to framework
5. Add snapshot tests for render output + SSE framing
6. Extended nightly fuzz runs
7. Cross-language CI
