# Test output — debugging UX

## Problem

When a test fails, the developer sees a wall of warn-level log output
from framework internals (accept failures, storage warnings, WAL
truncation) with the actual failure buried inside. During the
interleaved writes debugging session, it took 10 tool calls just to
parse which test failed and why. `grep` for "failed" matched
`[server] (warn): accept failed`. When all tests pass, there's no
summary line — just silence after pages of warnings.

Today's output on failure:

```
[server] (warn): accept failed: result=-1
[server] (warn): accept failed: result=-1
[server] (warn): accept failed: result=-1
... (50 more lines)
[connection] (warn): invalid HTTP request fd=100
[server] (warn): unmapped request: get /unknown fd=100
[server] (warn): accept failed: result=-1
... (20 more lines)
/home/walker/.../sim.zig:1176:16: in test.interleaved writes
    200 => try std.testing.expect(body_contains(get_resp.body, "Updated")),
               ^
```

## What the developer should see

On failure:

```
SEED=0xd021
events=10000, limits={product:20, order:50}
fault_busy_ratio=15/100, swarm_weights={create:42, update:7, delete:0, ...}

FAIL  interleaved writes — update and delete same entity across connections
      sim.zig:1176 — expected body to contain "Updated"

      model state:
        product aabbccdd...: inventory=50, active=true, version=2
      db state:
        product aabbccdd...: inventory=45, active=false, version=3

      full log: .zig-cache/test-logs/0xd021.log
      reproduce: ./zig/zig build test -- --seed=0xd021
```

On success:

```
85/85 passed (seed=0xa3f1)
```

## Design

### 1. Print simulation config at start

Following TB's VOPR pattern: print the full simulation config before
the run starts. When a failure is reported later, the developer already
knows the exact conditions without having to guess.

```zig
log.info(
    \\
    \\  SEED={}
    \\  events={}
    \\  fault_busy_ratio={}
    \\  swarm_weights=...
, .{ seed, events_max, fault_busy_ratio });
```

This goes to both stderr and the log file. It's always visible.

### 2. Per-scope log level filtering

Following TB's `fuzz_tests.zig` pattern: the test binary sets
`log_level = .info` globally, then silences noisy framework scopes
individually:

```zig
pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .server, .level = .err },
        .{ .scope = .connection, .level = .err },
        .{ .scope = .storage, .level = .err },
        .{ .scope = .wal, .level = .err },
        .{ .scope = .io, .level = .err },
    },
};
```

Only `.err` level from framework scopes gets through. The test harness
scope (`.sim`, `.fuzz`) stays at `.info`. Accept failures, recv peer
closed, WAL truncation warnings — all gone from stderr. Actual errors
(storage corruption, unrecoverable failures) still print.

This matches TB's approach: the noise doesn't exist in the first place.
No buffering, no discard-on-success complexity.

### 3. Redirect verbose logs to file, not discard

TB critique: don't silence — redirect. Silencing means when a test
crashes (signal, assertion) rather than fails (returns error), you have
no trail.

The log override writes verbose output to a per-seed log file:
`.zig-cache/test-logs/<seed>.log`. Stderr gets only summary-level
output. On failure, the path to the log file is printed. On crash,
the file is already on disk.

This preserves the full trace without polluting stderr. The developer
only opens the log file when they need to drill into framework internals.

Implementation: custom `logFn` that:
- Writes all levels to the log file (buffered writer, flush after each)
- Writes only `.err` from framework scopes to stderr
- Writes all levels from test scopes (`.sim`, `.fuzz`) to stderr

### 4. Seed as reproduction command

TB's output always leads with the seed because the seed is all you need
to reproduce. The reproduction line uses `.err` level so it's never
filtered out — following TB's `log.err("you can reproduce this failure
with seed={}")` pattern.

```
reproduce: ./zig/zig build test -- --seed=0xd021
```

One copy-paste. No guessing about which binary, which flags, which seed
format.

For sim tests with hardcoded seeds, the reproduce command uses the test
name filter:

```
reproduce: ./zig/zig build test -- --test-filter="interleaved writes"
```

### 5. Dump state on failure

Following TB's `simulator.cluster.log_cluster()` pattern: on
verification failure, print the model state and DB state side by side
for the entity that diverged. Not just "assertion failed at line X"
but "here's what the world looked like."

```
model state:
  product aabbccdd...: inventory=50, active=true, version=2
db state:
  product aabbccdd...: inventory=45, active=false, version=3
```

This goes to stderr (always visible on failure) and the log file.

### 6. Distinct exit codes

Following TB's `Failure` enum: different exit codes for different
failure classes.

| Exit code | Meaning |
|---|---|
| 0 | All tests passed |
| 1 | Test assertion failed (correctness) |
| 2 | Test timed out (liveness) |
| 127 | Crash (panic, signal) |

CI scripts can distinguish "test found a bug" from "test infrastructure
hung" from "test panicked." Different failures need different responses.

### 7. Unimplemented escape hatch

Following TB's `unimplemented()` pattern: operations without full
test coverage exit 0 instead of failing. This lets the developer run
the simulation in a loop during development — only real failures stop
the loop. Paths that aren't done yet produce a log line but not a
failure.

### 8. Summary line

Always print a summary, pass or fail:

```
85/85 passed (seed=0xa3f1)
```

```
84/85 passed, 1 failed (seed=0xa3f1)
```

Zig's test runner already does this, but the output is buried in log
noise. With scopes silenced on stderr, the summary becomes visible.
The seed is included so the developer can always reproduce the exact
run.

## TigerBeetle patterns adopted

| TB pattern | Our implementation |
|---|---|
| VOPR prints full config at start | Print seed, events, fault ratios, swarm weights |
| Per-scope log levels in `fuzz_tests.zig` | Same — silence `server`, `connection`, `storage`, `wal`, `io` in test binary |
| VOPR `log_override` with short/full modes | Log file for full, stderr for summary |
| VOPR buffered writer (4KB, flush after each) | Same — buffered file writer for log output |
| Seed-first failure output | Print `reproduce:` command with seed at `.err` level |
| `log_cluster()` state dump on failure | Print model vs DB state for diverged entities |
| `Failure` enum with distinct exit codes | Same — correctness, liveness, crash |
| `unimplemented()` exits 0 | Same — incomplete test paths don't block the loop |
| `--vopr-log=full` opt-in to noise | `--log-debug` on test binary enables verbose stderr |

## What this does NOT change

- Production log output — unchanged, controlled by `main.zig`
- Framework log sites — no marks or log calls added or removed
- Log scopes — existing scopes stay as they are
- Coverage marks — still work, marks use their own mechanism

## Decisions

### Why filter at scope level, not buffer-and-discard per test?

Buffer-and-discard means: capture all log output per test, discard on
pass, print on failure. This has a fatal flaw — if a test crashes
(SIGABRT from assertion, @memcpy alias panic) rather than returning an
error, the buffer is lost. The crash handler would need to flush the
buffer, adding complexity to a code path that should be minimal.

TB's approach is simpler: the noise never reaches stderr. The full
trace goes to a file unconditionally. No buffer management, no crash
handler complexity, no lost logs.

### Why a log file instead of just silencing?

Pure silencing loses information. When debugging a framework-level issue
(like the actual SimIO bug we initially suspected), the developer needs
the full trace. Redirecting to a file preserves it without cluttering
the happy path. The developer opts in by opening the file.

### Why not structured JSON log output?

Overhead for human-read logs. The logs are for debugging by a developer
reading a terminal, not for machine processing. Plain text with the
existing `[scope] (level): message` format is correct for this use case.

### Why print config at start, not just on failure?

The config is short (~10 lines) and always useful. If the test passes,
you can see what was tested. If it fails, you don't have to scroll up
or re-run to find the conditions. TB prints it unconditionally. The
cost is negligible — a few lines of output before the run.

### Why state dump on failure instead of just the assertion line?

An assertion line says "line 1176 failed." A state dump says "the model
thinks inventory is 50 but the DB has 45." The second tells you what
went wrong. The first tells you where the code noticed. The developer
needs both, but they need the "what" first.

## Delivery order

1. Add `std_options` with per-scope log levels to `sim.zig` and `fuzz_tests.zig`
2. Add custom `logFn` that splits output between stderr and log file
3. Create `.zig-cache/test-logs/` directory on test init
4. Print simulation config at start of each test run
5. Print `reproduce:` command on test failure (at `.err` level)
6. Add state dump helper — prints model vs DB for diverged entities
7. Add distinct exit codes for correctness, liveness, crash
8. Add `--log-debug` flag to test binary for full stderr output
9. Verify summary line is visible with scopes silenced
10. Document the log file location and reproduce workflow in CLAUDE.md
