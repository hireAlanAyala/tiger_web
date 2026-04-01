# Tiger Web

Full-stack web framework built in Zig, following TigerBeetle conventions.

## Testing

Most projects test by walking on eggshells — measuring which branches
were taken, adding coverage targets, wrapping every layer in mocks. SQLite
does this better than anyone: 590x test-to-code ratio, 100% MC/DC, four
independent test harnesses. It works. It's also the wrong model for us.

Coverage answers "did we test every branch?" We answer a different
question: **"does every invariant survive?"**

We write assertions — one every 12 lines of shipped code. Each one says:
if this isn't true, crash the process. Then we throw billions of random
scenarios at those assertions and see what survives. Same seed, same
result, every time. No flaky tests. No retries. No "known failures."

A robot (the CFO) does this 24/7 against trunk. If it finds a failing
seed, we fix the bug and the seed proves it forever.

### What makes this different

**Every assertion is a crash.** We don't log warnings or return error
codes on invariant violations. The process dies. Crash, don't corrupt.
Assertions downgrade catastrophic correctness bugs into liveness bugs.

**No mocks.** Simulation tests run the real server, real connection state
machine, real HTTP parser, real storage layer. The only fake is the OS
— `SimIO` replaces the kernel with a PRNG-driven fault injector. Everything
above it is production code under real fault injection.

**Zero flaky tests.** Every test is deterministic by seed. If it fails,
replay the seed — same physical path, same result. Determinism is a
design constraint, not a goal.

**No allocations after startup.** Every buffer is fixed-size, allocated at
init. The server can't OOM under load because there's nothing left to
allocate.

**The auditor disagrees, you have a bug.** An independent reference model
computes what the answer should be, then asserts the system agrees. We
don't just test that the system doesn't crash — we test that it computes
the right answer.

### By the numbers

```
Shipped code:        15,510 lines
  Framework:          8,742
  Application:        6,768
Test code:            4,713 lines

Assertions:           1,216 runtime + 45 comptime
Assert density:       1 per 12 lines of shipped code

Sim scenarios:        28 full-stack
Fuzzers:              3 independent
Coverage marks:       13 production sites, 12 test checks
CFO:                  runs 24/7, every seed reproducible
```

Run `zig build scripts -- metrics` to regenerate.
