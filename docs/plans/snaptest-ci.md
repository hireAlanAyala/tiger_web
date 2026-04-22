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

## TB utilities not yet ported

These exist in TigerBeetle's testing toolkit but are not in Tiger Web.
Each has a specific trigger for when to add it — don't add speculatively.

| Utility | TB location | What it does | When to add |
|---|---|---|---|
| `parse_seed` | `testing/fuzz.zig:90` | Accepts 40-char git commit hash as seed (truncates u160 → u64). CI passes commit hash so failures reproduce from the commit alone. | When CI exists (delivery step 1-2) |
| `random_int_exponential` | `testing/fuzz.zig:16` | Exponential distribution — values cluster around an average with a long tail. TB uses it for storage/network latency and workload intensity. | When `Simulation.run` needs realistic distributions (simulation-testing.md) |
| `random_id` | `testing/fuzz.zig:62` | Hot/cold ID generation — coin flip between small set (high collision) and large set (low collision). Simulates realistic cache access patterns. | When fuzz tests need to stress cache behavior or ID collision paths |
| `error_uniform` | `stdx/prng.zig:441` | Returns random variant from an error set type. ~6 lines. | When fuzz tests need to generate random error values |
| `DeclEnumExcludingType` | `testing/fuzz.zig:112` | Builds an enum type excluding specific variants — for swarm testing internal APIs while hiding internal-only operations. | When we need to fuzz a subset of operations excluding framework internals |
| `exhaustigen` | `testing/exhaustigen.zig` | Exhaustive permutation/combination generator without storing all in memory. For small state spaces where PRNG might miss corners. | When a module has a small enough state space for exhaustive testing |
| `snaptest` | `stdx/testing/snaptest.zig` | Snapshot testing with `SNAP_UPDATE=1` auto-update. Compares formatted output against source-embedded expected strings. | When render output or wire format tests need easy update-on-refactor |

## Delivery order

1. Basic CI workflow (unit-test + test + fuzz smoke + scan)
2. Add `parse_seed` to `fuzz_lib.zig` — needed for commit-seeded CI
3. Commit-seeded fuzzing in CI
4. Port `snaptest.zig` to framework
5. Add snapshot tests for render output + SSE framing
6. Extended nightly fuzz runs
7. Cross-language CI
