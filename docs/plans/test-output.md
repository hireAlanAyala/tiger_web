# Test output — debugging UX

## Problem

When a test fails, the developer sees a wall of warn-level log output
from framework internals (accept failures, storage warnings, WAL
truncation) with the actual failure buried inside. During the
interleaved writes debugging session, it took 10 tool calls just to
parse which test failed and why. `grep` for "failed" matched
`[server] (warn): accept failed`. When all tests pass, there's no
summary line — just silence after pages of warnings.

## What was tried and why we reverted

### Attempt 1: std_options in sim.zig with per-scope log_scope_levels

Set `pub const std_options` in `sim.zig` with `log_scope_levels` to
silence `.server`, `.connection`, `.storage` etc. at `.err`.

**Failed.** The framework was a separate Zig module (`b.dependency`).
Each module resolves `std_options` from its own root. The framework's
root was `framework/lib.zig`, not `sim.zig`. Per-scope filtering in
`sim.zig` had no effect on framework code.

### Attempt 2: std_options in framework/lib.zig

Added `std_options` to `framework/lib.zig` with test-only scope levels
(`if (builtin.is_test)`).

**Failed.** Same root problem — the framework module's `std_options`
only applies to framework code, but `std_options` in the framework
can't reference the application's configuration. It's a one-way
boundary.

### Attempt 3: Eliminate the module boundary

Changed from `b.dependency("tiger_framework")` to direct file path
imports: `@import("framework/lib.zig")`. Removed `framework/build.zig`
and `framework/build.zig.zon`. All 23 files updated.

**One compilation unit now.** Matches TigerBeetle's structure. But
`std_options` in `sim.zig` still didn't work because...

### Attempt 4: Discovery — test runner owns the root

Zig's test runner (`test_runner.zig`) is the actual root of test
binaries. It has its own `std_options` with `logFn = log`. The user's
`std_options` in `sim.zig` is NOT the root — it's ignored. The test
runner's `logFn` filters by `std.testing.log_level` (default `.warn`).

This is why per-scope filtering never worked — the test runner doesn't
use `log_scope_levels` at all. It uses a single global level.

### Attempt 5: Convert sim.zig to addExecutable

Made sim.zig an executable with `pub fn main()`. Now sim.zig IS the
root — full control over `std_options`, `logFn`, per-scope filtering.
Converted all 27 test blocks to named functions. Added custom panic
handler, `--log-debug` flag, test name filter, `--seed` flag, address
space limit.

**Worked.** Clean output: one line on success, test name + stack trace
on failure. Per-scope filtering silenced framework noise. All the
debugging UX goals were met.

### Attempt 6: Discovery — we built the wrong thing

Comparing against TigerBeetle's actual implementation revealed:

- TB's seeded unit tests use `addTest`, not `addExecutable`
- TB's fuzz tests in unit test form use `PRNG.from_seed_testing()`
  which reads `std.testing.random_seed` — set by the test runner
- TB only uses `addExecutable` for the VOPR (hours-long cluster
  simulation) and fuzz dispatchers — not for unit-level tests
- Our 27 scenario tests run in milliseconds. They're unit tests, not
  simulations. We built VOPR-level infrastructure for unit-test work.

The test runner's `std.testing.log_level` is the correct mechanism for
log control. Setting it to `.err` in a test init block works because
the test runner runs tests sequentially in declaration order. TB relies
on the same property with `from_seed_testing()` reading a global.

## Conclusion: revert to addTest

The correct architecture, matching TigerBeetle 1:1:

### Sim tests: addTest (not addExecutable)

```zig
// sim.zig — root is test_runner.zig, not us
test {
    // Silence framework noise. Runs first (declaration order).
    std.testing.log_level = .err;
}

test "cancel order — client cancels, worker completion rejected" {
    var prng = PRNG.from_seed_testing();
    var sim_io = SimIO.init(prng.int(u64));
    // ... test body ...
}
```

- `std.testing.log_level = .err` silences framework scopes globally
- `PRNG.from_seed_testing()` gives each test the same deterministic
  seed, varying per CI run via `--seed`
- Zig's test runner handles `--test-filter` for running specific tests
- No custom main, no custom panic handler, no CLI parsing

### Future simulation harness: addExecutable

The custom main/panic/logFn/CLI infrastructure we built belongs in the
future `Simulation.run` implementation — the PRNG-driven reference
model harness from `simulation-testing.md`. That runs for thousands of
events, needs per-scope filtering, custom failure output, and seed-
based reproduction. It IS a simulation, not a unit test.

### What stays from the current work

These changes are correct and should be kept:

1. **Framework module boundary eliminated** — `@import("framework/lib.zig")`
   everywhere, one compilation unit. Matches TB. Required for
   `from_seed_testing()` to resolve from the correct root.

2. **`framework/build.zig` and `framework/build.zig.zon` deleted** —
   the framework is not a separate package.

3. **`PRNG.from_seed_testing()` updated** — works in both test binaries
   (reads `std.testing.random_seed`) and executables (reads
   `root.testing_seed`). Needed for future simulation executable.

4. **`marks.zig` `enabled` flag** — supports both `builtin.is_test`
   and explicit `enable_marks` opt-in. Needed for future simulation
   executable.

5. **`limit_address_space()`** — 4GB cap, stays in sim.zig as a helper.

6. **`fuzz_tests.zig` per-scope logFn** — it's an executable
   (`addExecutable`), its `std_options` IS the root. Correct.

### What gets reverted

1. **sim.zig back to `addTest`** — test blocks, `std.testing.allocator`,
   `std.testing.expect`/`expectEqual`
2. **Custom `main()`, panic handler, CLI parsing** — deleted
3. **Custom `logFn` in sim.zig** — replaced by `std.testing.log_level = .err`
4. **`build.zig` sim step** — back to `b.addTest` from `b.addExecutable`

### Why the addExecutable attempt was wrong

TB's split is clear:

| Test type | Zig primitive | TB example | Our equivalent |
|---|---|---|---|
| Seeded unit tests | `addTest` | `test "Queue: fuzz"` | sim.zig scenario tests |
| Fuzz dispatchers | `addExecutable` | `fuzz_tests.zig` | `fuzz_tests.zig` (already correct) |
| Long-running simulation | `addExecutable` | VOPR | future `Simulation.run` |

We confused category 1 with category 3. Our scenario tests are seeded
unit tests, not simulations. The seed controls IO interleavings (partial
delivery, fault timing), not a reference model exploration. They belong
in `addTest`.

The VOPR-level infrastructure (custom main, panic handler, per-scope
logFn, `--log-debug`, test name filter, `--seed` CLI flag, address
space limit) belongs in the simulation harness we haven't built yet.

## Delivery order

1. Revert sim.zig to `addTest` with `test "name" {}` blocks
2. Add `test { std.testing.log_level = .err; }` init block
3. Change all `SimIO.init(hardcoded)` to use `from_seed_testing()`
4. Revert build.zig sim step to `b.addTest`
5. Remove custom main, panic handler, CLI infrastructure from sim.zig
6. Keep: module boundary elimination, marks.zig, fuzz_tests.zig logFn
7. Verify: `zig build test` output is clean, seeded, deterministic
8. Save executable infrastructure for simulation-testing.md plan

## Infrastructure to relocate to simulation-testing.md

The following pieces from the current sim.zig executable should be
preserved as reference for the future simulation harness (`Simulation.run`).
They're the correct architecture for a long-running PRNG-driven
simulation — just not for unit tests.

| Piece | Current location | Future home |
|---|---|---|
| Custom `pub fn main()` with test loop | sim.zig | simulation harness executable |
| Custom `logFn` with per-scope runtime filtering | sim.zig `sim_log` | simulation harness |
| `--log-debug` CLI flag for verbose output | sim.zig main | simulation harness CLI |
| `--seed=N` CLI flag for reproduction | sim.zig main | simulation harness CLI |
| Test name filter (`-- cancel`) | sim.zig main | simulation harness `--filter` |
| Custom panic handler with test name + `reproduce:` | sim.zig `panic` | simulation harness |
| `limit_address_space()` (4GB cap) | sim.zig | simulation harness + keep in sim.zig |
| `pub var testing_seed` for `from_seed_testing()` | sim.zig | simulation harness |
| `pub const enable_marks = true` | sim.zig | simulation harness |
| `pub const std_options` with `logFn` | sim.zig | simulation harness |

The commit that contains these is the reference: current HEAD before
the revert. The simulation-testing.md plan's delivery step 1
(`Simulation.run` loop) should start from this infrastructure.
