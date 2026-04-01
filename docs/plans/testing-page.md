# Plan: Testing Page

Public-facing page explaining how Tiger Web is tested. Inspired by
SQLite's testing page, but telling our story — simulation-first, not
coverage-first.

## Status

- [x] Metrics script (`zig build scripts -- metrics`)
- [x] Coverage diagnostic (`zig build scripts -- coverage`)
- [x] CFO lifetime seed counter (`fuzzing/totals.json`)
- [x] README testing section (philosophy + stats)
- [x] Decision doc: no per-operation storage fault injection
- [x] Checklist: periodic audit section (TB style)
- [ ] Bugs the simulator found (populate as CFO catches bugs)
- [ ] Full testing page (write when ready to ship publicly)

## Metrics script (done)

`zig build scripts -- metrics` outputs all scriptable numbers.
`zig build scripts -- metrics --no-fetch` skips devhubdb call.

Codebase metrics (counted from source):
- Shipped code lines (framework + application, excludes tooling)
- Test code lines
- Assertions (runtime + comptime, by type)
- Assert density (1 per N lines of shipped code)
- Sim scenario count
- Fuzzer count
- Coverage marks (production sites + test checks)

CFO metrics (from devhubdb `fuzzing/totals.json`):
- Lifetime seeds run (monotonic counter, survives merge algorithm)

We don't track lifetime seeds failed. A failed seed becomes passing
after the fix lands — tracking it would conflate "bugs caught" (good)
with "bugs present" (bad). "Bugs caught by fuzzing" is a human-curated
count, not a counter.

## Coverage diagnostic (done)

`zig build scripts -- coverage` runs unit tests under kcov.
Diagnostic tool, not a gate or a number for the testing page.

Sim tests can't be instrumented (epoll/ptrace conflict). Unit tests
cover ~84% of reachable shipped code. The unreachable files (server,
connection, SSE, handlers) are covered by sim tests — we just can't
measure it with kcov.

TB publishes kcov on their devhub but doesn't gate on it. We follow
the same pattern: use it to check if something stopped being tested,
not as a target.

## Page structure

### Philosophy (one paragraph)

"If the simulator can't break it, ship it. If it can, fix it and the
seed proves it forever." We don't measure coverage — we measure
whether invariants survive. The question isn't "did we test every
branch?" but "does every assertion hold after billions of random
scenarios?"

### Wow statements

Each gets its own short section with a concrete explanation.

**Zero flaky tests.** Every test is deterministic by seed. If it fails,
replay the seed — same result, every time. No retries, no "known
flaky," no skipping in CI. Determinism is a design constraint, not a
goal.

**No mocks.** Sim tests run the real server, real connection state
machine, real HTTP parser, real state machine. SimIO replaces the
kernel, not our code. The only fake is the OS. Everything above it is
the production code path under real fault injection.

**Every assertion is a crash.** We don't log warnings, return error
codes, or degrade gracefully on invariant violations. If an assertion
fails, the process dies. Crash, don't corrupt. Assertions downgrade
catastrophic correctness bugs into liveness bugs.

**No allocations after startup.** Every buffer is fixed-size, allocated
at init. The server can't OOM under load because there's nothing left
to allocate. This eliminates an entire class of production failures.

**The auditor disagrees, you have a bug.** An independent reference
model computes what the answer should be, then asserts the system
agrees. We don't just test that the system doesn't crash — we test
that it computes the right answer.

### Bugs the simulator found

The most compelling section on the page. 3-5 real stories, each with:
- The seed (readers can reproduce it themselves)
- What went wrong (e.g. "storage busy on tick 847 + partial send on
  connection 3 + concurrent request between prefetch and commit")
- Why no unit test would have caught it
- One paragraph, concrete, verifiable

This is what makes coverage percentages irrelevant. One story of a
compound fault caught by a 64-bit seed beats any metric.

**TODO:** Populate as the CFO finds bugs. Save the seed, write the
paragraph, add it here.

### Metrics dashboard

Display the numbers from the metrics script as evidence, not the
headline. Two groups:

**CFO (continuous)**
- Lifetime seeds run
- Last failure date

**Codebase (per-release, run `zig build scripts -- metrics`)**
- Shipped code (framework + application lines)
- Assert density (1 per N lines)
- Sim scenarios
- Fuzzers
- Coverage marks

### Simulation testing

How SimIO works. What faults it injects (accept, recv, send, send_now,
storage busy). That each fault is an independent PRNG decision. That
compound faults emerge naturally from the PRNG — no special mode
needed. Seed reproducibility.

### Fuzzers

List each fuzzer, what it targets, what invariants it checks:
- State machine (bypasses HTTP, prefetch/commit directly)
- Codec (random methods/paths/JSON)
- Render (random operations, asserts framing)
- Storage equivalence (SqliteStorage vs Auditor)
- Replay (WAL round-trip)
- Row format (binary protocol)
- Sidecar (protocol exchange)

### Coverage marks

How marks link production code paths to test assertions. Not coverage
measurement — proof that specific decision boundaries fire.

### The CFO

What it is, how it works, that it runs 24/7 against trunk. The CFO is
our equivalent of SQLite's continuous dbsqlfuzz — except it tests the
full stack, not just inputs.

### What we don't do (and why)

Each item was evaluated against TB's six principles (Safety,
Determinism, Boundedness, Fuzzable, Right Primitive, Explicit) and
against SQLite's testing practices. The reasoning is documented so the
next person who reads SQLite's testing page doesn't re-derive it.

**No 100% branch coverage metric.** SQLite pursues 100% MC/DC with
gcov, testcase() macros, and ALWAYS/NEVER build modes. We don't
measure coverage — we measure whether invariants survive simulation.
Coverage tells you "this branch was taken." Assertions tell you "this
branch was correct." SQLite themselves observed that MC/DC and fuzz
testing are in tension — we sidestep the tension entirely.

**No ALWAYS/NEVER macros.** SQLite uses these for defensive branches
that "should never fire" — three build modes to handle the coverage
gap. We use `assert`/`unreachable`/`maybe` — TB's vocabulary. If a
condition is always true, `assert` it. If it's never true,
`unreachable`. If it's sometimes true, `maybe()`. No middle ground,
no build modes.

**No mutation testing.** SQLite flips branches in assembly and verifies
the test suite catches it. With 2+ assertions per function, pair
assertions across code paths, and an auditor oracle, mutations can't
hide. The assertion density IS the mutation test.

**No per-operation storage fault injection.** SQLite injects I/O errors
at every VFS layer. We don't — the framework sees storage through two
buckets: transient (retry) or unrecoverable (crash). Each database
backend classifies its own errors into those buckets. A generic fault
injector would test a made-up error model. The prefetch busy fault
already tests the retry path. See `decision-storage-faults.md`.

**No testcase() macro.** SQLite annotates boundary conditions to ensure
both sides are tested. Our marks system is more powerful — marks prove
a code path fires, not just that a condition was evaluated. For
boundary conditions, the fuzzer's PRNG naturally generates values at,
near, and far from boundaries.

**No coverage gate.** kcov is a diagnostic (`zig build scripts --
coverage`), not a gate. TB publishes kcov on their devhub but doesn't
gate on it. Chasing a coverage percentage incentivizes shallow tests
that hit lines over deep tests that prove invariants.

**No assertions-per-function metric.** TB's rule is "2+ assertions per
function." That's a code review check, not a dashboard number. An
average that moves when someone adds helper functions rewards the
wrong behavior.

**No lifetime seeds-failed counter.** A failed seed becomes a passing
seed after the fix lands. Tracking lifetime failures conflates "bugs
caught" (good) with "bugs present" (bad). "Bugs caught by fuzzing" is
a human-curated count on this page, not an automated counter.
