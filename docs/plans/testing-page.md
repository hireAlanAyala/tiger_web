# Plan: Testing Page

Public-facing page explaining how Tiger Web is tested. Inspired by
SQLite's testing page, but telling our story — simulation-first, not
coverage-first.

## Metrics script

Write a script that outputs all scriptable numbers. Rerun before each
release or page update.

Scriptable from codebase:
- [ ] Production lines vs test lines (ratio)
- [ ] Total assertions (runtime `assert()` + `unreachable` + `@panic()`)
- [ ] Total comptime assertions
- [ ] Sim scenario count (`test` blocks in sim.zig)
- [ ] Fuzzer count (entries in fuzz_tests.zig)
- [ ] Coverage marks (production `log.mark.*` sites + test `marks.check()` calls)

Scriptable from CFO logs:
- [ ] Total seeds run by CFO
- [ ] Seeds since last CFO failure
- [ ] Last failure date (if any)

## Page structure

### Philosophy (one paragraph)

"If the simulator can't break it, ship it. If it can, fix it and the
seed proves it forever." We don't measure coverage — we measure
whether invariants survive. The question isn't "did we test every
branch?" but "does every assertion hold after billions of random
scenarios?"

### Wow statements

Each of these gets its own short section with a concrete explanation of
what it means and why it matters.

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

### Metrics dashboard

Display the numbers from the metrics script. Two groups:

**CFO (continuous)**
- Seeds run since last failure
- Total seeds run
- Last failure date

**Codebase (per-release)**
- Production vs test line ratio
- Assertions (runtime + comptime)
- Sim scenarios
- Fuzzers
- Coverage marks

### Simulation testing

How SimIO works. What faults it injects (accept, recv, send, send_now,
storage busy). That each fault is an independent PRNG decision. That
compound faults emerge naturally. Seed reproducibility.

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

### What we don't do (and why)

Brief section addressing techniques we considered and rejected, with
reasoning:
- No 100% branch coverage metric (simulation + assertions cover the
  same ground differently)
- No ALWAYS/NEVER macros (assert/unreachable/maybe is the right
  vocabulary)
- No mutation testing (assertion density + auditor catch mutations)
- No per-operation storage fault injection (framework sees two buckets:
  retry or crash — see decision-storage-faults.md)

### The CFO

What it is, how it works, that it runs 24/7 against trunk. The CFO is
our equivalent of SQLite's continuous dbsqlfuzz — except it tests the
full stack, not just inputs.
