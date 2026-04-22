# Benchmark Tracking — Decisions

This doc captures the decisions and findings behind Tiger Web's
benchmark-tracking system. It persists beyond
`docs/plans/benchmark-tracking.md` — plans are disposable; knowledge
is not (per `CLAUDE.md`).

- **Engineering values** — the 9 rules every benchmark file is held to.
- **Architectural decisions** — why three tiers, which primitives, etc.
- **Divergences from TigerBeetle** — where we deviate and why.
- **Preflight findings** — DR-1 through DR-4, frozen historical
  observations that reshaped the plan.
- **Scope boundaries** — what the system does and deliberately does not do.

When porting primitives or modules from TB in the future, re-read
this doc alongside `/home/walker/Documents/personal/tigerbeetle/docs/TIGER_STYLE.md`.

## Engineering values

These are the rules every file and every phase is held to. If a step
violates a rule, stop and revise before proceeding.

1. **Benchmark commitments, not guesses.** A benchmark is justified
   only when the thing it measures is externally committed — a
   cross-language wire contract, an on-disk format, a user-visible
   API, or a DX promise. Plastic internal data structures either get
   benched through their stable API (so implementation swaps produce
   new numbers without breaking the test) or not at all.
2. **Copy-first, trim-second at whatever granularity the TB file
   permits.** The discipline is the same across cases; the granularity
   adapts to the file.

   - **Self-contained TB files** (e.g., `bench.zig`, `checksum_benchmark.zig`):
     cp the whole file, trim with justification. Default is "TB's
     code stays unless we name why it's wrong for us."
   - **TB files deeply entangled with a subsystem we don't have**
     (e.g., `benchmark_load.zig` tied to VSR, `devhub.zig` tied to
     the tigerbeetle binary): cp the transplantable passages
     verbatim with per-passage attribution (file:line citations).
     The passages that can't transplant are written fresh because
     their TB equivalents are domain-specific, not reusable.

   The discipline — every line of TB's code we don't use has a named
   reason — applies at both granularities. Do **not** write a new
   version "in the style of" TB and later realign. Every deviation
   falls into one of three buckets: **principled** (TB's answer
   doesn't fit our domain), **flaw fix** (TB has a known weakness
   we can cheaply improve), or **tracked follow-up** (temporary
   state with a known end condition). Anything else is unprincipled
   divergence and reverts to TB's original.

   The "80% survival" heuristic is a *signal* about which granularity
   applies: if whole-file cp would survive at ≥80%, prefer whole-file
   cp. Below that, per-passage transplant is the right scope. It's
   never "write fresh with a vague TB inspiration."
3. **Each benchmark must pass the actionability test.** When the
   measured number moves, the engineer looking at the dashboard must
   have a concrete next investigation. "Something changed" is not
   enough. Every benchmark file's header names the investigation path.
4. **No hard CI thresholds.** Numbers are noisy. A threshold either
   fires false positives or is set high enough to miss real
   regressions. The dashboard is the tool; the human is the judge.
5. **Three tiers, each catching a different regression class.**
   Primitive tier (single algorithmic kernels), pipeline tier
   (framework pipeline without transport), SLA tier (end-to-end HTTP).
   Regressions surface at the finest tier that covers them.
6. **File-level discipline.** Every new file: functions ≤70 lines,
   ≥2 assertions per function on average, header paragraph with
   purpose + port source (if any) + divergences with rationale,
   `framework/bench.zig` harness, `stdx.PRNG` for randomness.
7. **Budgets are 10×-calibrated, not guessed.** Every `assert_budget`
   threshold follows the pattern already in `state_machine_benchmark.zig`:
   *"Set at ~10× expected value so they pass on slow CI runners but
   catch real algorithmic regressions."* Measure the expected value
   (three runs on the CI runner class in smoke mode), round up, multiply
   by 10. A number picked from the air is rejected — TB's "always
   motivate, always say why" applies to threshold values too. The 10×
   headroom is deliberately generous; it catches only order-of-magnitude
   regressions (10× slowdown from O(n²) or accidental allocations),
   which is all smoke-mode budgets should catch.
   Enforced mechanically by `scripts/bench_check.zig` (runs inside
   `zig build unit-test`).
8. **Transplanted code is cited.** When a passage is lifted from
   TigerBeetle, the comment names the source file:line so a future
   reader can see what's ours vs theirs.
9. **Open-loop mode is a blocking prerequisite for public claims.**
   We ship closed-loop to match TB. Before quoting any dashboard
   number externally (README, marketing, competitive comparison),
   open-loop mode is added.

## Why cp-first, trim-second

Previous ports from TB (including the original `framework/bench.zig`)
were written "in the style of" the TB file — outer shape preserved,
internals rewritten, simplifications introduced. The cost is not
immediately visible: we lose specific TB decisions we didn't recognize
as load-bearing. `framework/bench.zig` swapped `TimeOS` + `Duration`
for raw `std.time.Timer`. We didn't feel that loss at the time, but
TB's choice presumably encoded something (determinism? monotonic-clock
handling on specific platforms? a type-safety invariant?). Writing
fresh means we never pay the cost of understanding those decisions —
we just accumulate silent drift.

The cp-first discipline inverts this:

- Start from TB's file in its entirety
- Every deletion requires a named justification (principled / flaw
  fix / tracked follow-up)
- Every deletion that *can't* be justified reverts to TB's code

This forces the question "why did TB do it this way?" on every line
we'd otherwise rewrite. The question has to be answered (or deferred
to follow-up) before code changes, not after.

This is `CLAUDE.md`'s cp rule applied consistently: *"Surgical edits
on the real file produce an auditable diff where every change from
TB's original is intentional and documented."* The 80% survival
heuristic is a *signal* that trimming is heavy, not permission to
write fresh — writing fresh means the diff is against nothing, and
the TB decisions we dropped are invisible.

## Why three tiers

Each tier catches a different regression class. Running one tier
instead of three means some regressions hide under noise from layers
the benchmark didn't intend to measure.

| Tier | Why it exists |
|---|---|
| Primitive | A 20% CRC or HMAC regression is invisible in end-to-end HTTP throughput — the framework portion is only 30-40% of the measurement, so a 20% primitive regression translates to a ~7% HTTP regression, within noise. An isolated primitive bench sees it directly. |
| Pipeline | Catches framework-code regressions (handler dispatch, prefetch orchestration, commit batching) without contamination from HTTP parsing or kernel TCP. TigerBeetle has no direct equivalent because their VSR client library *is* the framework's core loop; we have more layers, so we have more tiers. |
| SLA | What customers actually see. Sensitive to kernel, TCP, SQLite, everything — which is exactly right for tracking the customer-facing number, and exactly wrong for isolating a framework change. |

A regression in the primitive tier should cause a proportional
regression in the pipeline tier, and a smaller (but visible)
regression in the SLA tier. Disagreements between the three tiers are
themselves signal — usually pointing at the right layer to investigate.

**Noise-floor caveat.** The proportionality heuristic holds only at
magnitudes above each tier's noise floor. Primitive tier (small
samples, high variance) may have ~10% noise; SLA tier (large samples,
kernel TCP variance) may have ~3%. A 5% framework regression shows
in SLA but gets lost in primitive noise. Measure each tier's noise
floor during the first month of devhub data collection; revisit
actionability thresholds (currently 10% per primitive) against
observed noise.

## Why this exact set of primitives

Five benchmarks, one per subsystem, each measuring a single algorithmic
kernel on an externally committed boundary:

| File | Subsystem | External commitment that justifies benchmarking |
|---|---|---|
| `crc_frame_benchmark.zig` | SHM transport | `packages/vectors/shm_layout.json` wire contract; 0x5CAC007A cross-language test vector; cannot change without simultaneous Zig + C + TS update |
| `aegis_checksum_benchmark.zig` | WAL | WAL entry format on disk; cannot change without breaking every existing WAL |
| `hmac_session_benchmark.zig` | Auth | User-visible cookie format; cannot change without breaking every active session |
| `wal_parse_benchmark.zig` | WAL | WAL entry body format on disk; same constraint as Aegis |
| `route_match_benchmark.zig` | HTTP dispatch | Scanner → generated-table contract; matcher implementation remains plastic, but the interface is locked |

The right unit is not "per subsystem" but **per distinct committed
algorithmic kernel**. The distribution:

| Subsystem | Committed kernels benched |
|---|---|
| SHM transport | 1 — `crc_frame` |
| WAL | 2 — Aegis MAC + body parse |
| Auth | 1 — HMAC session verify |
| HTTP dispatch | 1 — route match |
| SQLite storage | 0 — SQLite internals aren't our commitment |

Five benches = five distinct kernels. Adding a future subsystem
doesn't automatically add a bench; it adds a bench only if it
introduces a new committed kernel. Adding a kernel to an existing
subsystem (e.g., a new WAL field parser) does add a bench.

### Primitives considered and rejected

- `wal_recovery_benchmark.zig` — integration test, not a kernel.
  Parse + IO + hash chain composed. TB wouldn't bench it as a
  primitive; they'd rely on `wal_parse_benchmark` for the algorithmic
  signal and accept that recovery throughput is a pipeline-tier
  concern.
- `shm_slot_benchmark.zig` — protocol roundtrip, not a kernel. The
  algorithmic kernel is the CRC (already covered). Slot state
  transitions are state-machine mechanics. TB has no
  `vsr_message_roundtrip_benchmark.zig` for the same reason.
- `pending_index_benchmark.zig`, `ring_buffer_benchmark.zig` —
  plastic internals. Benchmarking them at the current
  implementation layer would calcify the data structure choice.
  Revisit later at the public API boundary if the container choice
  stabilizes (tracked as follow-up).
- Substrate utilities (`http.parse_request`, `codec.translate`,
  `parse_uuid`, `format_u32`, PRNG) — TB doesn't benchmark their
  equivalent substrate (TCP, memcpy) because they're not Tiger Web
  domain algorithms. Regressions here show up in the pipeline tier.

## Divergences from TigerBeetle

Each divergence is one of: **principled** (our domain differs),
**flaw fix** (TB has a known weakness), or **tracked follow-up**
(temporary state with an end condition).

### Principled divergences

- **HTTP client loop replaces VSR client loop.** Our domain is HTTP;
  customers never see VSR. The load generator's transport layer has
  to match what customers use. Shape transplanted from TB; mechanics
  rewritten.
- **Pipeline tier exists (TB has no direct equivalent).** TB's
  architecture is thinner — VSR client library calls directly into
  the database kernel. Tiger Web has HTTP → SHM → state machine,
  three layers of framework code between the client and the kernel.
  A pipeline tier catches regressions that are ours but aren't
  visible through HTTP. **Retirement criterion:** if the primitive
  tier + SLA tier together detect every regression caught by the
  pipeline tier for two consecutive quarters (six months), retire
  the pipeline tier. Until that signal holds, the tier earns its
  place.
- **No LSM-family benchmarks.** SQLite is our storage engine. We
  don't have LSM primitives to benchmark.
- **`assert_budget` in the harness.** TB's `bench.zig` lists
  "automatic regression detection" as an *explicit non-goal*:

  ```
  //! Non-goals:
  //! - absolute benchmarking,
  //! - continuous benchmarking,
  //! - automatic regression detection.
  ```

  TB deliberately chose benchmarks-report-humans-decide. We diverge
  because smoke-mode needs to catch catastrophic regressions (10×
  slowdowns from accidental O(n²) or allocations) inside
  `zig build unit-test`, which fails the build. This is not TB being
  wrong; it's two valid answers to different questions. TB has a
  human reviewer on their devhub; we want the unit-test run to be a
  tighter feedback loop. The one surgical addition to the harness
  during phase 0.

### Flaw fixes

- **Explicit warmup phase** (SLA tier, Phase D). TB's benchmark
  measures from `timer.reset()`, including cold-state overhead
  (SQLite prepared-statement cache fill, TCP connection warmup, page
  cache population). For a framework where the SLA claim is
  steady-state throughput, including warmup in the measurement
  window understates steady state. **Semantics: measure-and-discard.**
  Traffic runs during warmup; the histogram is zeroed before the
  real window begins. This is different from sleep-before-measuring.
- **Positive + negative-space pair-assertions in every benchmark**
  (phase C retrofit). TB's `checksum_benchmark.zig` template has no
  pair-assertion because checksum has no rejection path. Our
  domain-specific kernels do: tampered cookie → null, malformed WAL
  header → null, unmatched route → null. TIGER_STYLE's "golden rule
  of assertions" says to assert both positive and negative space;
  every primitive bench now does.
- **Automated bench-discipline check** (`scripts/bench_check.zig`).
  The engineering values above used to be prose; humans (me)
  violated them on the first pass of phase C. Discipline that isn't
  enforced is advice. The check parses every `*_benchmark.zig` for a
  header pointer to `docs/internal/benchmark-budgets.md` and a
  `bench.assert_budget` call, and runs inside `unit-test`. A
  reviewer who forgets the rules has the build reject the commit.

### Tracked follow-ups

- **Closed-loop load generator only.** TB is pure closed-loop and
  does not address coordinated omission. HTTP amplifies the failure
  mode (kernel scheduling can delay request issue, hiding the
  latency spike that would have occurred). We ship closed-loop to
  match TB. Open-loop mode is a **blocking prerequisite** before any
  public performance claim is made off the dashboard — not an
  open-ended "if regressions start hiding" trigger. The failure mode
  is invisible by design, so the remediation is time-boxed rather
  than signal-driven.
- **No machine fingerprint in the `MetricBatch`.** TB runs on
  GitHub-hosted `ubuntu-22.04` runners and accepts the consistency
  of that image class. We run on the same. When GitHub deprecates
  the image class, both of us get a discontinuity. Remediation:
  manual dashboard annotation on runner-class changes.

## Why no hard CI thresholds

TigerBeetle deliberately does not fail CI on benchmark regressions.
Benchmark numbers are noisy — kernel scheduling, disk cache state,
background processes all affect results. A hard threshold either
fires false positives (blocks valid commits) or is set so high it
misses real regressions.

The human-in-the-loop approach puts a competent reviewer in front of
a dashboard that makes regressions visually obvious. That reviewer
has context the CI system doesn't — they know whether a commit is
touching the hot path, they know whether the CI runner image changed
that week, they know whether a dependency bumped.

## Why one ci.yml, not a separate workflow

TB puts the devhub upload job in their existing `ci.yml`, gated by
`if: github.ref == 'refs/heads/main'`. A separate workflow file would
add surface area without adding capability and would drift from TB's
file layout. One CI workflow with branch-gated jobs is the TB-aligned
shape.

## Why append-only upload, not merge

TB has two different upload patterns in their repo:

- `cfo.zig` — merge seed records, dedupe, aggregate counts, prune
- `devhub.zig` — append one row per CI run

Reading `src/scripts/devhub.zig` confirms: devhub upload is simply
`fetch → reset → read array → append → commit → push` with retry on
push conflicts. No merge complexity. Every entry is unique by
`(commit, timestamp)` and there's nothing to merge across runs.

A contributor implementing phase E might look at our already-ported
`scripts/cfo.zig` and copy its retry-with-merge pattern. **That would
be wrong for devhub's simpler needs.**

## Preflight findings (frozen)

Preflight measurements and cross-file dry-run inspections surfaced
findings that reshaped the original plan. They are frozen historical
observations; the work they triggered is already done.

### DR-1 — `cache_line_size` missing from constants

Aegis bench imports `@import("framework/constants.zig").cache_line_size`.
Our `framework/constants.zig` didn't export it. TB's value
(`src/constants.zig:480`) is `config.cluster.cache_line_size`. Phase
C.2 gained a prerequisite step to add `cache_line_size: u16 = 64`
with bounded-and-power-of-2 comptime asserts.

### DR-2 — output-format mismatch vs `devhub.zig` parser

TB's `get_measurement` parses `label = value unit`:
```zig
_, const rest = stdx.cut(stdout, label ++ " = ") orelse ...
const value_string, _ = stdx.cut(rest, " " ++ unit) orelse ...
```

Our original `state_machine_benchmark.zig` used `get_product: 9.659us/op`
— does not parse. Phase 0 addendum switched every bench to TB's format
before Phase E's uploader depended on it.

### DR-3 — `benchmark_load.zig` is VSR-entangled; not whole-file cp-able

Reading the file (1069 lines): 26 `vsr.*` references, 35 VSR-domain
references (`MessagePool`, `MessageBus`, `Client`, `Account`,
`Transfer`, `Operation`). Top-of-file imports are the skeleton:

```zig
const vsr = @import("vsr");
const tb = vsr.tigerbeetle;
const IO = vsr.io.IO;
const Client = vsr.ClientType(tb.Operation, MessageBus);
```

Deleting those leaves almost nothing. Reframed from "cp verbatim,
trim VSR, graft HTTP" to "read TB's file for histogram + percentile +
closed-loop client-state pattern; write a Tiger Web HTTP version
with per-passage attribution." Phase-level plan reshaped.

### DR-4 — `devhub.zig` is ~25% survival, not 75–80%

TB's `devhub.zig` is heavy with tigerbeetle-binary-specific commands
(`tigerbeetle format`, `tigerbeetle inspect integrity`, custom TCP
ping). What survived into our port:

- `MetricBatch` struct (~15 lines)
- `Metric` struct (~5 lines)
- `get_measurement` parser (~15 lines)
- `upload_run` clone-reset-append-commit-push loop (~30 lines)

Total: ~70 of ~280 lines = ~25% survival. The `devhub_metrics` body
(the actual orchestrator) is tiger-web-specific and was written fresh.

### DR on `framework/bench.zig` drift

The pre-phase-0 harness used `std.time.Timer` and returned `u64`
nanoseconds, TB used `TimeOS` + `Duration`. The outer shape matched
but internals had drifted. **Decision: re-port from TB verbatim.**
TB's `TimeOS`/`Duration` presumably encode decisions we hadn't
recognized as load-bearing; re-porting restored them.
`assert_budget` stays as the one surgical addition.

### DR on `checksum_benchmark.zig` template survival

Measured (actual `cp`-and-measure, not estimated): 43 lines total.

- **Aegis port: 40/43 lines verbatim (93%).** Three import-path
  changes only.
- **Other primitives: ~75% survival.** Template shape preserved;
  kernel call + input + counter + report format substituted.

Decision: cp-as-template is viable for primitives. Primitive
benchmarks follow the template's shape with kernel-specific parts
substituted.

### DR on HTTP latency distribution

Measured (`zig build load -Doptimize=ReleaseSafe --connections=128
--requests=50000`): p1=9ms, p50=11ms, p99=12ms, p100=13ms. Debug at
concurrency=32: p50=2ms, p99=3ms. The earlier µs-granularity claim
was wrong. Decision: keep TB's ms histogram granularity.

## Phase C retrofit — what TIGER_STYLE taught us

The first-pass landing of phase C violated three TIGER_STYLE
principles. A retrofit pass closed each; the lessons apply to every
future TB port.

1. **Written "in the style of" the template instead of cp'd from
   it.** C.3/C.4/C.5 started as fresh files modeled on TB's
   `checksum_benchmark.zig` rather than as a verbatim `cp` followed
   by surgical trim. The file contents converged on the same shape
   an explicit cp-then-trim would have produced, but there was no
   git diff against TB's original — no audit trail.

   *Fix:* git-rm the first-pass files, re-`cp` TB's template,
   apply surgical deletions with inline bucket tags per removed line.
   Now `git diff /tmp/tb_checksum_benchmark.zig our_bench.zig` is
   auditable.

2. **Budgets were picked from the air, not calibrated.** Engineering
   value 7 was written before the first pass and was still violated.
   "Loose on purpose" comments appeared. The plan said "3 runs, 10×
   max, rounded up" and the first pass did one run.

   *Fix:* `scripts/bench_calibrate.zig` runs 3 configurations ×
   3 runs each and prints markdown-spliceable observations.
   `scripts/bench_check.zig` rejects any `*_benchmark.zig` whose
   header doesn't reference `docs/internal/benchmark-budgets.md`.

3. **Pair-assertions were positive-only.** Every primitive bench
   had a positive assertion at test start (vector match, round-trip,
   etc.) but no negative-space counterpart. TIGER_STYLE's golden
   rule says both.

   *Fix:* negative pair-assertions added across all five primitives
   (tampered cookie → null, malformed header → null, collision-on-
   flip, unmatched probe → null, etc.).

**Cross-cutting lesson:** the plan's prose rules didn't prevent the
violations. Humans forget; rereads of TIGER_STYLE fade. Mechanical
enforcement (bench-check in CI) is load-bearing.

## What this does NOT do

- Does not fail CI on regression (noise > signal for hard thresholds)
- Does not post PR comments (metrics without context mislead)
- Does not automatically roll back commits (human judgment required)
- Does not compare against baseline files (baselines drift with
  hardware, runner image updates, dependency changes)
- Does not publish laptop-run numbers as framework properties (tool
  stdout makes the machine context obvious; separate DX concern from
  the devhub pipeline, which runs exclusively on CI)

The dashboard is the tool. The developer is the decision-maker.

## What framework users get

Built into the framework, accessible without assembling an external
toolchain:

- `tiger-web benchmark` — HTTP throughput + latency (SLA tier) *(Phase D)*
- `zig build bench` — per-operation ns + algorithmic-kernel throughput
  (pipeline + primitive tiers)
- `zig build scripts -- bench-calibrate` — regenerate the 3-run
  observations for `docs/internal/benchmark-budgets.md`
- `zig build scripts -- bench-check` — enforce calibration discipline
- `zig build scripts -- perf` — CPU profiling with `perf` *(Phase D)*
- Public benchmark tracking dashboard at
  `https://hireAlanAyala.github.io/tiger-web-devhubdb` *(Phase G)*

No other web framework ships all four as first-class commands. The
value isn't that each tool is novel — it's that they're integrated
with the framework's metric definitions, so a user measures their
app, finds bottlenecks, and tracks regressions using one toolbox.

## Honest acknowledgments

Three things the system does not fully resolve:

1. **Coordinated omission is a known blind spot** until open-loop
   mode ships. Every performance claim from the dashboard before
   then carries an implicit "measured closed-loop" caveat that can
   hide tail-latency regressions. Tracked as follow-up with an
   explicit blocking trigger (first public claim).
2. **Runner-image drift detection is manual.** When GitHub
   deprecates a runner class, the dashboard shows a false
   regression. We rely on the developer noticing and annotating.
   Tracked as follow-up; remediation is cheap (~5 min) when the
   triggering announcement arrives.
3. **Pipeline tier motivation is load-bearing.** If future
   framework simplification reduces our layer count to match TB's,
   the pipeline tier's justification weakens and we'd reconsider
   whether it's still earning its complexity. As long as we have
   SHM dispatch and state-machine pipelining, it earns its place.
