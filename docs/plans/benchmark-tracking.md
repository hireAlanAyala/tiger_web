# Benchmark Rebuild — Implementation Plan

## Blocking on human

These items cannot be resolved from inside the repo. Everything past
Phase F depends on them. If you're picking the plan up and the
checkboxes below are still unchecked, these are the first things to
do — not buried in Phase B.

- [ ] **Generate PAT.** Fine-grained GitHub PAT scoped `contents: write`
  on `hireAlanAyala/tiger-web-devhubdb` only. URL:
  `https://github.com/settings/personal-access-tokens/new`.
- [ ] **Register the PAT as `DEVHUBDB_PAT`** in tiger_web's GitHub
  Actions secrets:
  `gh secret set DEVHUBDB_PAT --repo hireAlanAyala/tiger_web`.
- [ ] **Verify visibility** to the default-branch CI context:
  `gh secret list --repo hireAlanAyala/tiger_web | grep DEVHUBDB_PAT`.
- [ ] **Enable GitHub Pages** on `hireAlanAyala/tiger-web-devhubdb`
  (Phase G prerequisite; still unneeded until then). Settings →
  Pages → Source: `main` branch, root folder. Verify:
  `curl -sI https://hireAlanAyala.github.io/tiger-web-devhubdb/`
  returns 200.

Why here, not buried in phases: each is external, none takes more
than a few minutes, and all of them block F. A reviewer reading the
plan should see them before Phase C's discipline.

## Before starting (especially in a new session)

This plan ports substantial structure from TigerBeetle. The
cp-first-trim-second discipline (engineering value 2, and the matching
rule in `CLAUDE.md`) only works if the reader understands what TB
actually did before editing. Do not skip this; reading takes ~30
minutes and prevents the "wrote in the style of TB" failure mode this
plan exists to avoid.

Read in this order:

1. **TB's port principle** — `CLAUDE.md` → "Porting from TigerBeetle —
   cp first, trim second" section. The general rule that applies to
   every TB port, with the `framework/bench.zig` example of what
   going wrong looks like.

2. **The harness we're re-porting** —
   `/home/walker/Documents/personal/tigerbeetle/src/testing/bench.zig`.
   What `init`, `parameter`, `start`, `stop`, `estimate`, `report`,
   `TimeOS`, `stdx.Duration` each do and why. Phase 0 recreates this
   file; understanding the original is the prerequisite.

3. **The primitive template** —
   `/home/walker/Documents/personal/tigerbeetle/src/vsr/checksum_benchmark.zig`.
   43 lines. Every primitive benchmark in phase C starts as a `cp` of
   this file. The Substitute/Preserve/Add structure in phase C
   references its specific pieces.

4. **The SLA benchmark driver** —
   `/home/walker/Documents/personal/tigerbeetle/src/tigerbeetle/benchmark_driver.zig`
   (CLI entry, 227 lines) and
   `/home/walker/Documents/personal/tigerbeetle/src/tigerbeetle/benchmark_load.zig`
   (the load generator, 1069 lines). Phase D's "cp verbatim, trim
   VSR, graft HTTP" can only be executed if you can point at which
   lines are VSR-domain (to delete), which are transport-generic (to
   keep), and which are the histogram/percentile primitives (the
   load-bearing passages).

5. **The uploader** —
   `/home/walker/Documents/personal/tigerbeetle/src/scripts/devhub.zig`.
   The append-only git-push pattern. Phase E cps this file.

6. **This plan's engineering values section below.** The eight rules
   every phase is held to. Refresh before starting each phase.

Reference repo root: `/home/walker/Documents/personal/tigerbeetle`.

If any of the TB files above look unfamiliar when you start a phase,
stop and read the source. The plan's wording can match TB's idioms
without the reader recognizing them, and that's exactly the state
where we reintroduce the drift this discipline is meant to prevent.

## Current state (as of last committed work)

Checkboxes throughout the plan reflect what's done (`[x]`) vs what's
next (`[ ]`). Short version:

- **Phase 0**: ✅ done. `framework/bench.zig` re-ported from TB,
  `assert_budget` added as surgical addition, `state_machine_benchmark.zig`
  updated for `stdx.Duration`. Tests pass.
- **Phase 0 addendum**: `[ ]` pending. Update
  `state_machine_benchmark.zig` output format from
  `"get_product: 9.6us/op"` → `"get_product = 9600 ns"` to match TB's
  `devhub.zig` parser (per dry-run finding DR-2).
- **Phase A**: `[ ]` pending. Delete `scripts/loadtest.sh`,
  `load_driver.zig`, `load_gen.zig`. 30 min.
- **Phase B**: `[ ]` pending. Bootstrap `devhub/` dir in the
  existing devhubdb repo. Repo exists; `fuzzing/` has CFO data;
  `devhub/` dir missing. 30 min.
- **Phases C, D, E, F, G**: concrete checklists below.

### Known runtime unknowns (can't resolve without execution)

These are unavoidable — they only resolve by running the code:

- **CI-calibrated budgets.** Dev-machine numbers (9.6/63/16 µs) are
  2-5× faster than GitHub Actions will be. Phase F re-calibrates on
  actual CI.
- **Warmup effectiveness.** Claim: ≥20% p50 reduction. Phase D's
  verification step confirms or refutes.
- **DEVHUBDB_PAT end-to-end flow.** First CI push is phase F;
  earlier dry-runs are local only.

### Unknowns resolved by pre-execution dry-runs

These were open in earlier plan drafts; cross-file inspections
resolved them. Details in "Preflight measurements" below:

- DR-1: `framework/constants.zig` missing `cache_line_size` — phase
  C.2 gains a prerequisite step.
- DR-2: TB's devhub parser expects `label = value unit` format;
  our current bench output uses `label: value/op`. Phase 0 addendum
  + updated phase C/D format specs.
- DR-3: Phase D's cp-verbatim-trim-VSR model was wrong;
  `benchmark_load.zig` is too VSR-entangled. Reframed as
  pattern-transplant-with-attribution.
- DR-4: Phase E's `devhub.zig` survival is ~25%, not 75-80%.
  Reframed: small TB structures transplanted verbatim; `devhub_metrics`
  orchestrator written fresh.

---

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
   enough. Every benchmark file's header names the investigation path,
   and this plan drafts the statement so a contributor copies rather
   than invents.
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
8. **Transplanted code is cited.** When a passage is lifted from
   TigerBeetle, the comment names the source file:line so a future
   reader can see what's ours vs theirs.
9. **Open-loop mode is a blocking prerequisite for public claims.**
   We ship closed-loop to match TB. Before quoting any dashboard
   number externally (README, marketing, competitive comparison),
   open-loop mode is added.

---

## Preflight measurements (observed, decisions baked in)

Pure observations. No code changes. Preflight was run before finalizing
this plan; results replace earlier conditional language.

### Cross-file dry-run inspections (post-phase-0)

After phase 0 landed, dry-run inspections of the TB files the later
phases depend on surfaced three real findings that reshape the plan:

**Finding DR-1: `cache_line_size` is missing from our constants.**
Aegis bench imports `@import("framework/constants.zig").cache_line_size`.
Our `framework/constants.zig` does not export it. TB's value
(`src/constants.zig:480`) is `config.cluster.cache_line_size`. Phase
C.2 gains a prerequisite step: add `cache_line_size: u16 = 64` (or
whatever TB's resolved value is — check at port time) to
`framework/constants.zig`.

**Finding DR-2: TB's devhub.zig parses `label = value unit` format;
our benchmarks emit `label: value/op`.** TB's `get_measurement`
helper does `stdx.cut(stdout, label ++ " = ")` then
`stdx.cut(rest, " " ++ unit)`. Any benchmark whose output will be
parsed by `scripts/devhub.zig` must emit the TB format. Our current
`state_machine_benchmark.zig` uses `get_product: 9.659us/op` —
**does not parse**. Phase C and phase D benchmarks must emit
`get_product = 9659 us` format. Phase 0 addendum task added below
to update `state_machine_benchmark.zig` before phase E depends on it.

**Finding DR-3: phase D cp-verbatim model is wrong for
`benchmark_load.zig`.** Reading the file (1069 lines): 26 `vsr.*`
references, 35 VSR-domain references (`MessagePool`, `MessageBus`,
`Client`, `Account`, `Transfer`, `Operation`). The top-of-file
imports are the entire skeleton:

```zig
const vsr = @import("vsr");
const tb = vsr.tigerbeetle;
const IO = vsr.io.IO;
const Client = vsr.ClientType(tb.Operation, MessageBus);
```

Deleting those imports leaves almost nothing. The plan's "cp verbatim,
trim VSR, graft HTTP" framing was optimistic. The realistic framing
is "**read TB's file for the histogram + percentile + closed-loop
client-state pattern; write a Tiger Web HTTP version that uses those
patterns with attribution**." This is closer to a pattern-transplant
than a file-port. Phase D section rewritten below.

**Finding DR-4: TB's devhub.zig is ~50% survival, not 75-80%.**
The file is heavy with tigerbeetle-binary-specific commands: builds
tigerbeetle, runs `tigerbeetle format`, runs `tigerbeetle start`,
does custom TCP ping, runs `tigerbeetle inspect integrity`, runs
`tigerbeetle inspect metrics`. None of that applies to us. What
survives:

- `MetricBatch` struct shape (~15 lines)
- `get_measurement` parser helper (~15 lines)
- `upload_run` git-clone-fetch-reset-append-commit-push loop (~30 lines)
- CLI arg pattern (~10 lines)

Total: ~70 of ~280 lines survive = ~25% survival. The `devhub_metrics`
function (the 200-line orchestrator that actually runs the
benchmarks) is entirely Tiger-Web-specific and gets written fresh.
Plan phase E section rewritten below.

The discipline still holds — every deletion from the cp has a named
reason (tigerbeetle-binary-specific commands, specific parser labels,
etc.) — but the survival ratio is worse than estimated. The useful
lesson for future TB ports: **survival ratio is visible only from
reading the actual file, not from structural similarity.**

### `framework/bench.zig` diff against TB's `src/testing/bench.zig`

**Observed drift:** our harness uses `std.time.Timer` and returns `u64`
nanoseconds, TB uses `TimeOS` + `Duration`. We added `assert_budget`
that TB doesn't have. The outer shape (`init`, `parameter`, `start`,
`stop`, `estimate`, `report`, smoke/benchmark mode, `seed_benchmark`)
matches.

**Decision:** re-port from TB verbatim. Our current file was written
"in the style of" TB's — the exact pattern we're trying to stop
doing. TB's `TimeOS` and `stdx.Duration` may encode decisions we
haven't recognized as load-bearing yet. The re-port itself is code
work; moved to **Phase 0** below.

### `src/vsr/checksum_benchmark.zig` template survival

**Observed** (actual `cp`-and-measure, not estimated): 43 lines total.

- **Aegis port: 40/43 lines survive verbatim (93%).** Only three
  import-path changes: `@import("../constants.zig")` →
  `@import("framework/constants.zig")`, `@import("checksum.zig")` →
  `@import("framework/checksum.zig")`, `@import("../testing/bench.zig")`
  → `@import("framework/bench.zig")`. Our `framework/checksum.zig`
  exports `pub fn checksum(source: []const u8) u128` — same signature
  as TB's. No body edits required.
- **Other primitives (CRC, HMAC, WAL parse, route): ~35/43 survive
  (81%).** Four substitutions each (function call, counter name,
  parameter range, hash-of-run print format). Same shape, different
  kernel.

**Decision:** cp-as-template is viable. Primitive benchmarks follow
this shape verbatim with only kernel-specific parts substituted.

### Local calibration of existing pipeline-tier budgets

Ran `state_machine_benchmark.zig` three times (benchmark mode, not
smoke — smoke mode is silent) on the development machine to establish
a calibration baseline:

| Operation | Run 1 | Run 2 | Run 3 | Max | 10× (budget) |
|---|---|---|---|---|---|
| `get_product` | 9.654 µs | 9.552 µs | 9.631 µs | 9.654 µs | ~100 µs |
| `list_products` | 62.811 µs | 63.022 µs | 62.824 µs | 63.022 µs | ~640 µs |
| `update_product` | 15.789 µs | 15.941 µs | 15.878 µs | 15.941 µs | ~160 µs |

Variance across runs is <1% on a quiescent dev machine.

**Caveats:**
- Numbers are benchmark-mode (large inputs). Smoke-mode (small
  inputs) runs in unit-test will show different absolute values;
  calibration happens in smoke mode.
- Dev machine ≠ CI runner. When phase F ships, re-calibrate on
  GitHub Actions ubuntu-22.04 (usually 2-5× slower than local) and
  update budgets accordingly.
- The existing `state_machine_benchmark.zig` budgets (500 µs, 2 ms,
  1 ms) were calibrated for slow CI in smoke mode. Don't blindly
  tighten them to our benchmark-mode numbers.

**Decision:** the 10× rule is validated as feasible on observed data
(small variance, reasonable headroom above max). Primitive benches in
phase C use the same rule; numbers get pinned during CI calibration
in phase F.

### HTTP latency distribution on the current load tool

**Observed** (`./zig/zig build load -Doptimize=ReleaseSafe --
--connections=128 --requests=50000`):

| Metric | Value |
|---|---|
| p1 | 9 ms |
| p50 | 11 ms |
| p99 | 12 ms |
| p100 | 13 ms |

**Observed (Debug, concurrency=32):** p50 = 2 ms, p99 = 3 ms.

Neither mode shows predominantly sub-ms latencies. The earlier claim
("HTTP latency is sub-ms, µs buckets warranted") was wrong.

**Decision:** keep TB's ms granularity. Remove µs-granularity as a
divergence. The 10,001-slot ms histogram gives range from 0-10,000ms
which comfortably contains our distribution.

---

## Phase 0 — re-port the benchmark harness ✅ DONE

Effort: 1 hour (actual: ~30 min). Dependencies: preflight measurements.
Blocks: phase C.

**Status: complete.** First concrete code work and first real test of
the cp-first-trim-second discipline. Executed on 2026-04-22.

**Outcome:** clean execution. Two surgical changes beyond the cp itself
were needed and both are justified:

1. `@import("../time.zig")` → `@import("time.zig")` — path
   substitution. TB's `bench.zig` lives at `src/testing/`; our
   `bench.zig` lives at `framework/`, co-located with `time.zig`.
   Structural file-layout difference; the import resolves to the same
   `TimeOS` type.
2. `@import("test_options")` kept as-is; build.zig renamed
   `bench_options` → `test_options` to match TB's convention.

One surgical addition as planned: `pub fn assert_budget` with a
clearly-marked comment block documenting this as a principled
divergence from TB's "automatic regression detection" non-goal.

**Caller updates (`state_machine_benchmark.zig`):**

- Durations array type changed `[repetitions]u64` → `[repetitions]Duration`
- Divide-by-ops changed from `dur.* /= ops` to
  `dur.* = .{ .ns = elapsed.ns / ops }`
- Report format: dropped `std.fmt.fmtDuration(est)` wrapper;
  `Duration` has its own `format` method that produces the same
  human-readable output (e.g. `9.659us`)
- Budget constants changed from `const get_product_ns: u64 = 500_000`
  to `const get_product: Duration = .{ .ns = 500_000 }`

**Output-format diff (pre vs post):** identical structure. Only
differences are run-to-run variance on the measured numbers
(e.g. `9.609us/op` before, `9.659us/op` after — same 3 decimal
digits, same suffix). `scripts/devhub.zig` will parse the same shape.

**All tests pass:**
- `zig build unit-test` ✓
- `zig build bench` ✓ (output format verified)
- `zig build test` — 219 passed
- `zig build test-sidecar` — 232 passed, 1 skipped

**What the discipline taught us** (bake-in for future ports):

- The path-substitution surgical edit was **necessary** and
  **justified**. When file layouts differ, imports diverge. This is
  not "cp failed"; this is "cp succeeded, and layout adaptation is
  the minimum trim."
- The `bench_options` → `test_options` rename moved our surrounding
  code to match TB's, rather than editing TB's file. This is the
  preferred direction under cp-first: **trim our environment to
  match TB, not TB's file to match our environment.**
- `stdx.Duration` does carry semantic weight — the pretty-print
  format method comes for free and replaces our ad-hoc
  `std.fmt.fmtDuration` wrapper. TB's choice was load-bearing after
  all.

**Historical record (what this phase executed):**

- [x] Back up current `framework/bench.zig` as reference
- [x] `cp /home/walker/Documents/personal/tigerbeetle/src/testing/bench.zig framework/bench.zig`
- [x] Surgical addition: `pub fn assert_budget(bench, measured,
  budget, name)` with file-header comment documenting this is our
  one justified addition (principled divergence from TB's
  "automatic regression detection is a non-goal" stance)
- [x] Surgical path substitution: `@import("../time.zig")` →
  `@import("time.zig")` (file-layout difference, same type)
- [x] Surgical rename in `build.zig`: `bench_options` → `test_options`
  to match TB's convention so `bench.zig`'s
  `@import("test_options")` works verbatim
- [x] Surgical deletions: **none** (every TB function stayed)
- [x] Update callers (`state_machine_benchmark.zig`) to use
  `stdx.Duration` instead of `u64` where the harness now returns it.
  **`stdx.Duration` API reference** (verified in
  `/home/walker/Documents/personal/tigerbeetle/src/stdx/time_units.zig`):
  - Constructors: `Duration.ms(n)`, `Duration.seconds(n)`, `Duration.minutes(n)`
  - Accessors: `.to_us()`, `.to_ms()` (return `u64`)
  - Comparisons: `.min(other)`, `.max(other)`, `.clamp(min, max)`
  - Sort: `Duration.sort.asc` (for `std.sort.block`)
  - Format: human-readable `"1.123s"` via `format` method — the
    report output will look different from raw `u64` ns; this is
    what the output-format verification below catches
- [x] **Output-format verification:** diffed pre/post `zig build
  bench` output — identical structure, only run-to-run variance on
  measured numbers. `scripts/devhub.zig` will parse the same format.
  `Duration`'s built-in `format` method produces the same
  human-readable output (e.g. `9.659us`) as our previous
  `std.fmt.fmtDuration` wrapper.
- [x] Verify `zig build unit-test` and `zig build bench` still pass

### Phase 0 addendum — output format to match TB's parser ✅ DONE

Surfaced by cross-file dry-run DR-2 after phase 0 landed. Needed
before phase E could parse the output.

- [x] Updated `state_machine_benchmark.zig` report calls from
  `"get_product: 9.6us/op"` format to TB's
  `"get_product = 9658 ns"` format.
- [x] Output verified: `get_product = 9658 ns`, `list_products = 63423 ns`,
  `update_product = 15894 ns`. All lines match regex
  `^[a-z_]+ = \d+ \w+$` — exactly the shape
  `scripts/devhub.zig`'s `get_measurement` parser expects.
- [x] Budget constants remain `Duration` typed; report-format change
  is purely string formatting.

Phase 0 is the first invocation of the cp-first rule. If this phase is
awkward, the rule is wrong; revise the rule, not the phase. If this
phase is straightforward, the rule is calibrated and subsequent phases
apply the same discipline.

---

## Phase A — delete existing confusion

Effort: 30 min. Dependencies: none.

- [x] `grep -rn "loadtest.sh" .github/ docs/ scripts/ CLAUDE.md` —
  identified references; draft plan + historical internal docs left
  untouched (descriptive of prior state)
- [x] Delete `scripts/loadtest.sh`
- [x] Delete `load_driver.zig` and `load_gen.zig`
- [x] Remove the `load` step + load_gen unit-test entry from `build.zig`
- [x] Update `CLAUDE.md` Quick Reference section: replaced `zig build load`
  + `loadtest.sh` blocks with a phase-D placeholder pointing at
  `tiger-web benchmark`; profiling block stubs the load invocation
  line until phase D ships
- [x] File table under "Application (root)" has no entries for the
  deleted files (already absent)
- [x] Dropped `load_gen.zig` / `load_driver.zig` entries from
  `scripts/coverage.zig` skip list and `scripts/metrics.zig`
  tooling list (stale after deletion)
- [x] Verified: `./zig/zig build unit-test`, `./zig/zig build test`,
  `./zig/zig build test-sidecar` all pass

**`scripts/perf.zig` stubbed.** Full orchestration removed (lives in
git history at `67993e8~1:scripts/perf.zig`). Invoking
`zig build scripts -- perf` now prints a phase-D pointer and exits 1
rather than shelling out to a missing binary. Phase D rewires the
script to drive `tiger-web benchmark`.

No user-visible API change. These were dev tools; their replacement
(`tiger-web benchmark`) ships in phase D.

---

## Phase B — devhubdb repo bootstrap

Effort: 30 min. Dependencies: none. Unblocks E and F.

**Observed state** (verified via GitHub API, 2026-04-22):

- Repo exists at `https://github.com/hireAlanAyala/tiger-web-devhubdb`
- `fuzzing/` directory exists with `data.json` (39 KB, ~5 commits from
  CFO on 2026-03-27) and `logs/`
- `fuzzing/totals.json` status: needs verification during phase B
- **`devhub/` directory does not exist** — phase B creates it
- GitHub Pages **not enabled** — manual activation needed in phase G
- CFO last uploaded 2026-03-27; not currently running in CI (no
  workflow references `devhubdb`). Phase F is the first CI upload for
  either CFO or the devhub benchmark feed

Tasks:

- [x] Clone `https://github.com/hireAlanAyala/tiger-web-devhubdb` locally
- [x] Verified `fuzzing/` intact (`data.json` 39 KB + `logs/`); did
  not touch existing CFO data
- [x] Created `devhub/data.json` containing `[]`
- [x] Created `fuzzing/totals.json` (was absent on remote). Value
  aligned to `sum(.count)` across existing `fuzzing/data.json`
  entries = **184456**, not `0`. CFO's `SeedTotals.read` returns
  `{seeds_run: 0}` on `FileNotFound`, so `0` wouldn't have crashed —
  but it would have silently under-reported cumulative seeds by the
  historical count. Corrected on devhubdb commit `f70fdd8`.
- [x] Bootstrap pushed on devhubdb `main`: `d252562` (initial) →
  `f70fdd8` (totals.json fix). Remote paths confirmed via API.
- [ ] **User action:** Generate a GitHub PAT with `contents: write`
  scope on `hireAlanAyala/tiger-web-devhubdb` only (fine-grained PAT
  recommended; classic also works). Browser URL:
  `https://github.com/settings/personal-access-tokens/new`
- [ ] **User action:** Add the PAT as `DEVHUBDB_PAT` in tiger_web's
  GitHub Actions secrets. Via CLI (once PAT is in clipboard):
  `gh secret set DEVHUBDB_PAT --repo hireAlanAyala/tiger_web`
- [ ] **User action:** Verify `DEVHUBDB_PAT` visible to default
  branch: `gh secret list --repo hireAlanAyala/tiger_web | grep DEVHUBDB_PAT`

CFO has been targeting this repo. Phase B completes its missing
`devhub/` half and unblocks the first CI-driven upload from either
subsystem.

---

## Phase C — primitive benchmarks (5 files)

Effort: 1–2 days. Dependencies: phase 0 + A. Independent of D.

**Port discipline:** each file starts as a `cp` of
`src/vsr/checksum_benchmark.zig`, then trims and substitutes. Do not
write a fresh file "modeled on" the template — copy the template
verbatim as the starting point, then each change is a conscious
substitution (the kernel call, the input shape, the hash-of-run
print). TB's choices in the template that we don't *actively replace*
survive unchanged.

Each file's header contains: purpose, external commitment, the
actionability statement drafted below, and a list of the specific
substitutions we made relative to `checksum_benchmark.zig`.

### C.1 `crc_frame_benchmark.zig` ✅ DONE (commit `cabcc0c`)

Landed as written. Divergence from this checklist: per-size metrics
(`crc_frame_64` … `crc_frame_65536`) via `inline for` rather than a
single `blob_size` parameter — the file header's actionability
statement already references cross-size comparison, so a single
parameter would have undercut it.

**Historical checklist:**

- [x] `cp src/vsr/checksum_benchmark.zig crc_frame_benchmark.zig` as starting point
- [x] Substitute: `checksum(blob)` → `shm_layout.crc_frame(len, payload)`
- [x] Substitute: single `blob_size` parameter → inline-for over 5 sizes
- [x] Substitute: checksum counter hash-print → CRC counter hash-print
- [x] Substitute: `bench.report` format → `"crc_frame_{size} = {d} ns"`
- [x] Add: cross-verify `"hello"` → `0x5CAC007A` at test start
- [x] Add: per-size `bench.assert_budget`. Budgets calibrated off
  dev-machine Debug (325/1123/4211/16671/260084 ns) at 10-20×
  headroom; phase F re-calibrates on CI.
- [x] Preserved TB's scaffold (Bench init/deinit, arena, repetitions,
  estimate, report, hash-of-run print)
- [x] Wired into `build.zig` under `bench_sources`

**Actionability statement for the file header:**
*"If MB/s drops >10%, check `std.hash.crc.Crc32` stdlib changes first,
then verify the `inline fn` annotation on `crc_frame` survived any
optimization. If MB/s jumps >10%, inspect whether Zig added SIMD
specialization for CRC32 and whether that applies here. A drop on one
payload size but not others usually means cache behavior changed."*

### C.2 `aegis_checksum_benchmark.zig` ✅ DONE (commit `382102b`)

Prerequisite landed in same commit: `cache_line_size: u16 = 64` added
to `framework/constants.zig` with a `comptime` assertion (citing
TB `src/config.zig:154` and `src/constants.zig:480`).

Port itself: 40/43 lines verbatim (93% — matches DR-1 estimate). Three
surgical additions beyond the import path changes, all documented
in the file header: test name disambiguation, TB-parseable report
format, `assert_budget` call. One test name rename (`checksum` →
`aegis_checksum`) is a flaw fix, not a principled change.

**Historical checklist:**

- [x] `cache_line_size` prereq (verified concrete value = 64)
- [x] `cp src/vsr/checksum_benchmark.zig aegis_checksum_benchmark.zig`
- [x] Three import-path substitutions
- [x] Report format adjusted to `"aegis_checksum = {d} ns"` (DR-2)
- [x] `assert_budget` at 10 µs (dev-machine 1 KiB ≈ 200 ns, ~50×
  headroom; phase F re-calibrates)
- [x] Wired into `build.zig` under `bench_sources`

**Actionability statement for the file header:**
*"If MB/s drops >10%, check whether AES-NI hardware acceleration is
still engaged (`std.crypto.core.aes.has_hardware_support`). A cross-
architecture CI change or VM disabling AES-NI will produce a step
function drop. If the fallback software path is active, WAL throughput
bottlenecks on checksum computation."*

### C.3 `hmac_session_benchmark.zig` ✅ DONE (commit `638b183`)

Landed with one principled divergence from the plan text: `blob_size`
parameter dropped, not varied. Our cookie is fixed-length
(`cookie_value_max = 97`) by the auth protocol — there is no
realistic size to vary. Documented inline in the file header. Plan
text inherited TB's blob-size parameter shape verbatim without
reconciling it against our domain.

"Timestamp check" also dropped: our `verify_cookie` does not validate
a time window; plan text speculated one existed.

**Historical checklist:**

- [x] `cp` starting point
- [x] Substitute kernel → `auth.verify_cookie(cookie, key)`
- [x] `blob_size` parameter removed (divergence above)
- [x] Substitute counter → `verify_counter: u64`
- [x] Report format `"hmac_session = {d} ns"`
- [x] Pair-assertion: sign → verify round-trip recovers `user_id` and `kind`
- [x] Preserved scaffold
- [x] Wired into `build.zig`

**Actionability statement for the file header:**
*"If ns/op rises >20%, check whether HMAC-SHA256 stdlib changed or the
cookie format grew. If verification starts failing in the pair assertion,
the cookie schema drifted — session invalidation is a user-visible
breaking change. If ns/op drops sharply, a verification step was
removed; check the auth flow covers time-window enforcement."*

### C.4 `wal_parse_benchmark.zig` ✅ DONE (commit `13dcc25`)

Body hand-constructed in a `build_body` helper (3 writes with SQL +
params, 2 dispatches with name + args, ~300 bytes). Pair-assertion
checks both dispatches' names round-trip. Kernel: `Wal.skip_writes_section`
+ loop of `parse_one_dispatch`.

**Historical checklist:**

- [x] `cp` starting point
- [x] Kernel → `skip_writes_section` + `parse_one_dispatch` loop
- [x] Input → pre-built in-memory body (`build_body` helper, no IO)
- [x] Counter → `parse_counter: u64`
- [x] Report `"wal_parse = {d} ns"` + separate `"parsed N dispatches"` line
- [x] Pair-assertion: round-trip names (`charge_payment`, `send_email`)
- [x] Preserved scaffold
- [x] Wired into `build.zig`

**Actionability statement for the file header:**
*"If ns/entry rises, check whether the WAL entry body format gained
fields or the parsing loop added validation. Recovery time scales with
entries × ns/entry; a 30% parse regression translates to 30% slower
startup on WAL replay. If the pair assertion fails, the on-disk format
changed — coordinate migration before shipping."*

### C.5 `route_match_benchmark.zig` ✅ DONE (commit `7c014b2`)

`match_any` mirrors `app.zig:handler_route` (inline iteration over
`gen.routes` calling `parse.match_route`) minus the handler-body
decode. Probe set covers exact, parameterized, deeper parameterized,
unmatched (DoS surface), and root.

**Historical checklist:**

- [x] `cp` starting point
- [x] Kernel → inline iteration over `gen.routes` calling `parse.match_route`
- [x] Input → 5 mixed probes with expected `Operation`
- [x] Counter → `match_counter: u64`
- [x] Report `"route_match = {d} ns"` + separate `"match_sum"` hash line
- [x] Pair-assertion: every probe resolves to its expected operation
- [x] Preserved scaffold
- [x] Wired into `build.zig`

**Actionability statement for the file header:**
*"If ns/match rises, check whether the generated route table grew
(more routes = more comparisons) or the matcher's loop structure
changed. A rise on parameterized routes but not exact-match usually
means the pattern-matcher's splitter got slower. If unmatched-path
performance regresses, the 404 path is taking longer — which affects
DoS surface."*

### C.6 harness invariants (shared across all 5) ✅ DONE

Initial landing was flagged by a TIGER_STYLE audit as having three
systemic gaps (discipline violations, not correctness bugs):

1. C.3/C.4/C.5 were written "in the style of" the template rather
   than a real `cp`-then-trim with per-deletion bucket tags. No
   audit trail against TB's file.
2. Budgets were set from single dev-machine observations, not the
   plan-mandated `10× max(3 runs)` discipline. "Loose on purpose"
   comments slipped in.
3. Pair-assertions were positive-only; TIGER_STYLE's golden rule
   requires positive AND negative space.

All three closed by a retrofit pass:

- C.3/C.4/C.5 restarted from a verbatim `cp` of TB's
  `checksum_benchmark.zig`, surgical deletion pass with inline
  bucket tags on every removed line. Commits `9c78f22` / `5ba2173`
  / `da10fdc`.
- C.1/C.2 retrofitted in place (already cp'd, so no restart
  needed) with the same header structure, negative-space
  pair-assertions, 3-run calibration, and units-last naming.
  Commit `c0ebf28`.
- `framework/constants.zig` `cache_line_size` assert replaced —
  was `assert(cache_line_size == 64)` (tautology), now checks
  three relationships (bounds 16..256, power-of-two,
  `>= @alignOf(std.atomic.Value(u64))`). Part of commit `9c78f22`.

Post-retrofit invariant audit:

- [x] Every benchmark body fits under 70 lines. Helper setup
  extracted (`build_body` in wal_parse, `match_any` in route_match).
- [x] Every benchmark has **both** a positive AND a negative
  pair-assertion at test start. Negative probes:
  - aegis: `checksum("hello") != checksum("hallo")` (hash property)
  - crc_frame: length-prefix participates (`crc_frame(4, "hello")
    != crc_frame(5, "hello")`) AND payload sensitivity
  - hmac_session: tampered cookie (flipped bit in HMAC tail) → `null`
  - wal_parse: truncated dispatch header → `null`
  - route_match: explicit unmatched probe → `null`
- [x] Every benchmark imports `framework/bench.zig` (no second harness).
- [x] Every benchmark is deterministic — PRNG seeded from
  `bench.seed`, or fixed input by construction.
- [x] Every benchmark calls `bench.assert_budget` in smoke mode.
- [x] Every budget is `10× max(3 runs)` rounded up, with the three
  observed numbers recorded in the file header.
- [x] `zig build bench` runs all five. Dev-machine Debug, post-retrofit:
  - `aegis_checksum = 2046328 / 2062949 / 2061315 ns` at 1 MiB
    (benchmark mode) / `4942 / 2976 / 4841 ns` at 1 KiB (smoke-
    equivalent via `blob_size=1024`) — budget 50000 ns
  - `crc_frame_{size}`: per-size budgets 15k/50k/150k/600k/3M ns
  - `hmac_session = 2109 / 2072 / 2691 ns` — budget 30000 ns
  - `wal_parse = 139 / 136 / 112 ns` — budget 2000 ns
  - `route_match = 4083 / 6485 / 5702 ns` — budget 70000 ns
- [x] `zig build unit-test`, `test` green post-retrofit.
  `test-sidecar` flaky on one run (unrelated — no sidecar code
  touched), clean on retry.

---

## Phase D — SLA benchmark as `tiger-web` subcommand

Effort: 1–2 days. Dependencies: A. Independent of C.

### D.1 CLI integration

- [ ] Add `benchmark: BenchmarkArgs` to the `Command` union in `main.zig`
- [ ] Write `benchmark_driver.zig` (fresh; TB's args don't port)
- [ ] `BenchmarkArgs` fields: `--port`, `--connections`, `--requests`,
  `--ops`, `--warmup-seconds` (default 5), `--json`
- [ ] `--json` emits NDJSON to stdout for `scripts/devhub.zig`;
  otherwise human-readable `key = value` to stdout (parseable by
  devhub)

### D.2 `benchmark_load.zig` — pattern-transplant with attribution

**Reframed from earlier "cp-verbatim, trim-VSR" after DR-3 finding.**
TB's `benchmark_load.zig` is not cp-able for us: the VSR client is
the structural skeleton, not a replaceable leaf. Imports like
`vsr.ClientType(tb.Operation, MessageBus)` are the spine of the file.
Deleting them leaves almost nothing.

Realistic model: **read TB's file as reference, write a Tiger Web
HTTP version that transplants the specific patterns by name**,
with file:line citations for every transplanted passage (per
engineering value 8).

This is still TB-aligned — we're preserving TB's *techniques*, not
writing fresh from memory — but the cp-first rule doesn't apply at
the whole-file level because the file is inseparable from VSR. The
cp-first rule applies at the *passage* level instead.

- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/tigerbeetle/benchmark_load.zig /tmp/benchmark_load_reference.zig`
  — kept as reference only, not as starting point
- [ ] Create `benchmark_load.zig` fresh, with file header documenting
  the transplanted passages and their sources
- [ ] **Transplanted passages with citations** (each one is a
  structural lift from TB's file, not a from-scratch rewrite):
  - Histogram — `[10_001]u64` (or `[10_001]u32`) lap counters, bucket
    by `@min(ms, 10_000)`. Cite `benchmark_load.zig:117-118, 876`.
  - Percentile walk — cumulative sum across buckets, find p1/p50/p99/p100.
    Cite `benchmark_load.zig:1051-1068`.
  - Client state machine pattern — BitSet `clients_busy`, array
    `clients_request_ns`, callback unsets + records latency. Cite
    `benchmark_load.zig:858-876`.
  - Output format — `label = value unit` lines, cite
    `benchmark_load.zig:556-572` (and confirmed by DR-2 to be the
    format `scripts/devhub.zig` parses).
  - PRNG seeding — cite `benchmark_load.zig` usage of
    `stdx.PRNG.from_seed`.
- [ ] **Written fresh because TB's equivalents are domain-specific:**
  - HTTP client over TCP (persistent keep-alive). TB has VSR client.
  - JSON body construction per operation (reuses `codec.zig`/
    `message.zig`). TB has account/transfer binary packing.
  - Operation-weight mix (`--ops=create_product:80,list_products:20`).
    TB has a fixed register → create → query workflow.
  - Stage orchestration. TB's stages are VSR-specific.
- [ ] **Surgical addition** (not in TB, explicitly justified as flaw fix):
  - Warmup phase with measure-and-discard semantics. Run load traffic
    for `--warmup-seconds` seconds (default 5) to fill SQLite prepared-
    statement cache, warm TCP connections, populate page cache.
    Discard the histogram, zero it, then begin the real measurement
    window. **Semantics: system is actively exercised during warmup;
    only recorded measurements are discarded.** Document as flaw fix
    in the file header.

The file header paragraph must enumerate: which passages are
transplanted (with TB file:line), which are written fresh, and which
are surgical additions. A future contributor can audit the file by
cross-referencing with TB's original.

### D.3 HTTP client loop (new code, not ported)

- [ ] Persistent TCP connection pool with keep-alive
- [ ] Request body construction per operation (reuses `codec.zig`
  and `message.zig` types)
- [ ] Operation-weight mix (`--ops=create_product:80,list_products:20`)
  driven by `stdx.PRNG` for deterministic replay under a seed
- [ ] Connection-error handling: reconnect + track reconnection count
  as a reported metric

### D.4 Machine-readable output for state_machine_benchmark

- [ ] Add `--json` flag to `state_machine_benchmark.zig` so phase E
  can merge its output into the `MetricBatch`
- [ ] Existing human-readable mode remains default for developer runs

### D.5 Verification

- [ ] `./zig-out/bin/tiger-web start --port=3000 &` then
  `./zig-out/bin/tiger-web benchmark --port=3000 --connections=64
  --requests=50000` produces reasonable numbers
- [ ] `--json` output is valid JSON parseable by Zig's `std.json`
- [ ] No orphaned processes after run (pair with existing orphan
  check in CLAUDE.md)
- [ ] Warmup is effective: run the SLA bench twice on a cold database,
  once with `--warmup-seconds=5` and once with `--warmup-seconds=0`.
  The warmup run's p50 should be lower by at least 20% (proves the
  warmup traffic actually populates caches). If the difference is
  smaller, either warmup is a no-op or our system has no cold-cache
  penalty worth measuring — investigate before shipping.

---

## Phase E — devhub uploader

Effort: 1 day. Dependencies: B, C, D.

### E.1 Port from TB — partial cp, ~50% survival (per DR-4)

**Reframed from earlier "cp with surgical edits" after DR-4 finding.**
TB's `devhub.zig` is heavy with tigerbeetle-binary-specific commands:
builds `tigerbeetle`, runs `tigerbeetle format`, `start`, `inspect
integrity`, `inspect metrics`, custom TCP ping for startup timing.
None of that applies to us. Realistic survival is ~25% of the file;
the rest gets written fresh for Tiger Web's distinct metrics.

- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/scripts/devhub.zig /tmp/devhub_reference.zig`
  as reference
- [ ] Create `scripts/devhub.zig` with these **structures
  transplanted verbatim** from TB:
  - `MetricBatch` struct (~15 lines): preserve `timestamp`,
    `attributes: { git_repo, branch, git_commit }`, `metrics: []Metric`
    shape. Swap `git_repo` value for our URL.
  - `Metric` struct (~5 lines): `name`, `value`, `unit`
  - `get_measurement` parser helper (~15 lines, verbatim — confirmed
    by DR-2 this matches the output format we'll emit)
  - `upload_run` git-clone-fetch-reset-append-commit-push loop
    (~30 lines). Append-only, not merge. Preserve 32-retry on push
    conflicts.
  - `CLIArgs` struct with `sha` field and `--skip-kcov` convention
    (we probably don't need kcov, but preserve the pattern for
    `--dry-run` etc.)
- [ ] **Write fresh for Tiger Web** (no TB equivalent applies):
  - `devhub_metrics` function body: runs our three tiers, collects
    our specific metrics
  - All the tigerbeetle-binary-specific command invocations get
    dropped (no `tigerbeetle format`, no `inspect metrics`, no
    custom TCP ping, no changelog parsing, no release flag logic)
- [ ] Surgical edits on transplanted structures:
  - `MetricBatch.attributes.git_repo`:
    `"https://github.com/tigerbeetle/tigerbeetle"` →
    `"https://github.com/hireAlanAyala/tiger_web"`
  - `upload_run` clone URL:
    `github.com/tigerbeetle/devhubdb` →
    `github.com/hireAlanAyala/tiger-web-devhubdb`
  - `Metric` list populated with our three-tier metric names

### E.2 Upload semantics (append-only, not merge)

Devhub upload is simpler than CFO upload. Do NOT copy CFO's merge
algorithm.

- [ ] Per iteration:
  1. `git fetch origin main && git reset --hard origin/main`
  2. Read `devhub/data.json` (JSON array)
  3. Append the new `MetricBatch` as one additional array element
  4. Write, `git add`, `git commit`, `git push`
  5. On push conflict: retry (up to 32 times)
- [ ] No merge logic, no deduplication, no per-commit aggregation
- [ ] Fail with `CanNotPush` error if all 32 retries exhausted

CFO's merge algorithm exists because CFO accumulates seed records
across many runs and prunes. Devhub accumulates one line per CI run;
every entry is unique by (commit, timestamp) and there's nothing to
merge.

### E.3 Wire into `scripts.zig`

- [ ] Add `devhub: devhub.CLIArgs` to the `CLIArgs` union
- [ ] Add `@import("./scripts/devhub.zig")` in `scripts.zig`
- [ ] `--sha` flag for explicit commit attribution (TB pattern)
- [ ] `--dry-run` flag: compute metrics, skip the push
- [ ] Invocation: `./zig/zig build scripts -- devhub`

### E.4 Run order

The uploader invokes all three tiers in sequence, parses their output,
merges into one `MetricBatch`, commits one NDJSON array element:

- [ ] `./zig/zig build bench` (primitive + pipeline tiers, via `--json`)
- [ ] `./zig-out/bin/tiger-web benchmark --json` (SLA tier)
- [ ] Parse outputs; build `MetricBatch`
- [ ] Clone devhubdb, perform the append-only upload per E.2

### E.5 File header

- [ ] Header paragraph in `scripts/devhub.zig` documents:
  - Port source (`src/scripts/devhub.zig` from TB)
  - Divergences from TB with rationale
  - Tracked follow-ups (open-loop, runner drift)
  - Reference to `docs/plans/benchmark-tracking.md` for deeper context

### E.6 Verification

- [ ] `./zig/zig build scripts -- devhub --dry-run` runs all tiers,
  prints merged `MetricBatch`, does not push
- [ ] `./zig/zig build scripts -- devhub` pushes one entry to devhubdb
  (requires `DEVHUBDB_PAT` in env)

---

## Phase F — CI wiring

Effort: 1 hour. Dependencies: B, E.

- [ ] Extend existing `.github/workflows/ci.yml` with a `devhub` job
  (**not** a new workflow file — TB's pattern is one ci.yml with
  branch-gated jobs)
- [ ] Gate: `if: github.ref == 'refs/heads/main'`
- [ ] On PRs: run with `--dry-run` so the benchmark code is exercised
  but no upload occurs
- [ ] Secrets: reference `DEVHUBDB_PAT` from phase B
- [ ] Verification: merge a commit, observe a new entry in
  `devhubdb/devhub/data.json` within minutes

---

## Phase G — dashboard (deferred)

Effort: 1–2 days. Dependencies: F produces data for ≥1 week.

- [ ] `cp src/devhub/devhub.js` and `src/devhub/index.html` from TB
  into the devhubdb repo root. **Survival estimate:** the earlier
  "~80%" figure was an unverified guess. Metric-name strings, chart
  configurations, and outlier-detection logic are all TB-specific;
  actual survival is likely closer to 60% once VSR-domain metric
  names are swapped for our three tiers. Re-measure during phase G
  execution; if it's under 50%, revisit whether the cp-first
  approach applies here or if a fresh dashboard is legitimate.
- [ ] Surgical edits:
  - Data source URL: point at
    `https://raw.githubusercontent.com/hireAlanAyala/tiger-web-devhubdb/main/devhub/data.json`
  - Metric names to chart: update to our three tiers
  - Three chart panels (SLA, pipeline, primitive) with tier-level
    navigation
  - Week-over-week outlier highlighting (top 3 per panel)
- [ ] **Enable GitHub Pages** on `hireAlanAyala/tiger-web-devhubdb`
  (verified 2026-04-22: currently returns 404, i.e. not yet enabled).
  Repo settings → Pages → Source: `main` branch, root folder.
  Verification: `curl -sI https://hireAlanAyala.github.io/tiger-web-devhubdb/`
  should return 200 within a few minutes of activation.
- [ ] Public URL: `https://hireAlanAyala.github.io/tiger-web-devhubdb`
- [ ] Commit-link annotations so each data point links to the tiger_web
  commit that produced it

---

## Tracked follow-ups

These are not shared exposures with TB. They are temporary states with
known end conditions.

- [ ] **Open-loop load generator mode.** Blocking prerequisite for any
  public performance claim off the dashboard (README, marketing,
  external comparison). Not "if regressions start hiding" — the
  failure mode is invisible by design, so the remediation is
  time-boxed (before first public claim) rather than signal-driven.
- [ ] **Runner-image change detection.** When GitHub deprecates a
  runner class, annotate the dashboard with the date of the switch
  so the discontinuity is visible rather than misread as a
  regression. Subscribe to GitHub Actions deprecation announcements;
  add annotation within 24h of any runner image change.
- [ ] **`pending_index_benchmark.zig` and `ring_buffer_benchmark.zig`
  at API boundary.** Add only if the container-choice for those
  structures stabilizes and we want regression detection. Benchmark
  through `add`/`resolve`/`find_by_op` (not the flat-array scan) so
  an implementation swap produces a new number without breaking the
  test. Until then the pipeline-tier bench covers them implicitly.
- [ ] **Per-endpoint load shapes.** Default `--ops` mix will need
  tuning as domain grows.

---

## Effort summary

| Phase | Effort | Depends on |
|---|---|---|
| preflight measurements | done | — |
| 0 (harness re-port) | done (~30 min actual) | preflight |
| 0 addendum (output format) | done (~10 min actual) | 0 |
| A | 30 min | 0 |
| B | 30 min | nothing |
| C | 1.5–2 days | 0, A |
| D | **2–3 days** (up from 1-2 after DR-3) | A |
| E | **1–1.5 days** (up from 1 after DR-4) | B, C, D |
| F | 1 hour | B, E |
| G | 1–2 days | F + ≥1 week of data |

**Pragmatic sequencing:** 0 → A + B in parallel → **C, then D**
→ E → F → G.

C before D is the default. C validates the discipline on easy cases
(~85% survival cp-with-trim); D is the higher-risk pattern-transplant
with fresh HTTP code. Learning from C first reduces the risk surface
of D. Parallelizing saves calendar time only if you're confident D
won't reshape anything in C, which you're not confident of until C
is done.

Total to phase F (CI uploading on every main merge): **~5-6 focused
days** (up from ~4 after dry-run findings DR-3 and DR-4).

The 25-50% scope growth is itself a finding: TB's benchmark tooling
is more domain-entangled than the cp-first rule initially suggested.
The rule still holds, but its granularity shifted (see engineering
value 2). Future TB ports should budget an inspection pass before
phase planning, not only after.

---

# Reasonings

The rules above are the distilled output. The reasoning that produced
them is below. A reader who agrees with the rules can stop at the end
of phase G; a reader who wants to challenge or extend a rule reads on.

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
  slowdowns from accidental O(n²) or allocations) inside `zig build
  unit-test`, which fails the build. This is not TB being wrong;
  it's two valid answers to different questions. TB has a human
  reviewer on their devhub; we want the unit-test run to be a
  tighter feedback loop. The one surgical addition to the harness
  during phase 0.

### Flaw fixes

- **Explicit warmup phase.** TB's benchmark measures from
  `timer.reset()`, including cold-state overhead (SQLite prepared-
  statement cache fill, TCP connection warmup, page cache
  population). For a framework where the SLA claim is steady-state
  throughput, including warmup in the measurement window understates
  steady state. **Semantics: measure-and-discard.** Traffic runs
  during warmup; the histogram is zeroed before the real window
  begins. This is different from sleep-before-measuring.

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
  manual dashboard annotation on runner-class changes (tracked as
  follow-up).

## Preflight observations

Preflight measurements were run before finalizing this plan. Three
findings, each with a bound decision:

1. **`framework/bench.zig` has drifted from TB in the exact way
   engineering value 2 prohibits.** Our harness swapped `TimeOS` +
   `stdx.Duration` for raw `std.time.Timer`; it was written "in the
   style of" TB's file. **Decision: re-port from TB verbatim** (as a
   1-hour preflight task, before phase C). `assert_budget` stays as
   the one justified surgical addition.
2. **`checksum_benchmark.zig` template survives ~85%.** The outer
   structure (test scaffold, `Bench` init, parameter, arena alloc,
   samples loop, estimate call, report) is reusable per primitive
   with the kernel call and hash-of-run print swapped. **Decision:
   cp-as-template is viable; primitive benchmarks follow the
   Substitute/Preserve/Add structure in phase C.**
3. **HTTP latencies are ms-scale, not sub-ms.** Measured p1=9ms,
   p50=11ms at ReleaseSafe / 128 connections; p1=1ms, p50=2ms at
   Debug / 32 connections. The earlier µs-granularity claim was
   wrong. **Decision: keep TB's ms histogram granularity.** Divergence
   removed from the plan.

The preflight's role is exactly this: preventing the plan from
asserting facts it hasn't measured. Findings 1 and 3 reversed
plan decisions that were based on assumption; finding 2 confirmed
an assumption that turned out to be correct.

## Why cp-first, trim-second

Previous ports from TB (including our current `framework/bench.zig`)
were written "in the style of" the TB file — outer shape preserved,
internals rewritten, simplifications introduced. The cost is not
immediately visible: we lose specific TB decisions we didn't recognize
as load-bearing. `framework/bench.zig` swapped `TimeOS` + `Duration`
for raw `std.time.Timer`. We don't currently feel that loss, but TB's
choice presumably encodes something (determinism? monotonic-clock
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

This is CLAUDE.md's `cp` rule applied consistently: *"Surgical edits
on the real file produce an auditable diff where every change from
TB's original is intentional and documented."* The 80% survival
heuristic is a *signal* that trimming is heavy, not permission to
write fresh — writing fresh means the diff is against nothing, and
the TB decisions we dropped are invisible.

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
be wrong for devhub's simpler needs.** Phase E.2 spells this out
explicitly.

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

- `tiger-web benchmark` — HTTP throughput + latency (SLA tier)
- `zig build bench` — per-operation µs + algorithmic-kernel throughput
  (pipeline + primitive tiers)
- `zig build scripts -- perf` — CPU profiling with `perf` (existing)
- Public benchmark tracking dashboard at
  `https://hireAlanAyala.github.io/tiger-web-devhubdb` (phase G)

No other web framework ships all four as first-class commands. The
value isn't that each tool is novel — it's that they're integrated
with the framework's metric definitions, so a user measures their
app, finds bottlenecks, and tracks regressions using one toolbox.

## Honest acknowledgments

Three things this plan does not fully resolve:

1. **Coordinated omission is a known blind spot** until open-loop
   mode ships. Every performance claim from the dashboard before
   then carries an implicit "measured closed-loop" caveat that can
   hide tail-latency regressions. Tracked as follow-up with an
   explicit blocking trigger (first public claim).
2. **Runner-image drift detection is manual.** When GitHub
   deprecates a runner class, our dashboard will show a false
   regression alongside TB's. We rely on the developer noticing and
   annotating. Tracked as follow-up; the remediation is cheap (~5
   min) when the triggering announcement arrives.
3. **Pipeline tier motivation is load-bearing.** If future
   framework simplification reduces our layer count to match TB's,
   the pipeline tier's justification weakens and we'd reconsider
   whether it's still earning its complexity. As long as we have
   SHM dispatch and state-machine pipelining, it earns its place.

These are surfaced here rather than buried because readers deserve to
see the assumptions the plan rests on.
