# TB 1:1 Alignment — Additional Opportunities

Catalogues places where Tiger Web could more closely mirror TigerBeetle's
practices, beyond the benchmark-tracking plan's current scope. Each
item lists effort, payoff, and whether it's blocking anything.

**Source of truth for TB conventions:**
`/home/walker/Documents/personal/tigerbeetle/` (local clone). When
porting, cp-first-trim-second per `CLAUDE.md` and
`docs/internal/decision-benchmark-tracking.md`.

**Why a separate plan:** these are alignment choices, not work the
benchmark-tracking plan needs to ship. Grouping them here lets us
triage independently and pick based on current priorities.

## Already matched — for the record

Not work; just anchors so a future reader knows what *is* aligned.

- Histogram-based latency bucketing — matches TB `benchmark_load.zig:117,876,1045-1068`.
- `get_measurement`, `MetricBatch`, `upload_run` — matches
  `scripts/devhub.zig` (verbatim transplant minus URL swap).
- `framework/bench.zig` harness — matches `src/testing/bench.zig`
  (phase 0 re-port, one principled surgical addition: `assert_budget`).
- `stdx.PRNG.from_seed` for determinism — every bench uses it.
- CFO seed tracking — `scripts/cfo.zig` ported; `fuzzing/data.json`
  on devhubdb holds 184456 historical seeds.
- One CI workflow with branch-gated jobs — matches
  `.github/workflows/ci.yml` pattern.

## Moved into `benchmark-tracking.md` Phase G

The following items were originally catalogued here but are
benchmarking/dashboard-adjacent. They now live inside Phase G so
the plan that ships the dashboard also ships the work it depends
on. This file keeps only work that's genuinely orthogonal to
benchmark-tracking.

- **`triaged` issue-label convention** → G.1 one-time repo setup.
- **`/tree/release` tag convention** → inline note next to G.1's
  release-tree URL swap.
- **Seed `92` standardization** → G.0.b fuzz invocations (first
  adoption site) + note to extend to sim-test/CI.
- **`sudo -E` in devhub CI job** → G.0.b kcov wiring step.
- **`unit-test-build` standalone binary** → G.0.a (hard
  prerequisite for kcov).

## Tier 2 — medium cost, infrastructure

Worthwhile once the dashboard is shipped and stable. Unlock more
developer-experience capabilities.

### 6. Style-check script beyond `bench-check` ✅ DONE (2026-04-27)

Shipped as `scripts/style_check.zig` (commit `fffbc0a`). Three
mechanical checks on hot-path files: throwaway markers (FAIL),
70-line function limit (WARN; skips comptime type-constructor
sigs), assertion density ≥2/fn (WARN). Wired into `zig build
unit-test` alongside `bench-check`. First run found 12 real
discipline gaps in existing code — exactly the class of issue
that prose rules in CLAUDE.md kept missing.

(Original tier-2 description follows for historical record.)

- [ ] Add `scripts/style_check.zig` that walks the tree and asserts:
  - No function body exceeds 70 lines (TIGER_STYLE hard limit)
  - No file exceeds 100 columns (`zig fmt` catches most but not
    comments)
  - Banned abbreviations (`mp`, `he`, other project-specific) don't
    reappear
  - Assertion density ≥2/fn average in `*_benchmark.zig` and hot-path
    framework files (benchmarks already checked via `bench-check`;
    extend to `framework/server.zig`, `framework/connection.zig`,
    etc. where TIGER_STYLE applies most)
- [ ] Wire into `zig build unit-test` like `bench-check` — CI
  fails if discipline slips.
- [ ] Outcome: matches TB's "rules enforced mechanically, not by
  discipline" principle. Removes reliance on post-hoc TB-lens
  audits to catch style drift.

Effort: ~1-2 hours (AST walking, minimal; string checks across
files, easy).
Blocks: nothing; purely tightens future commits.

### 7. `release_validate` workflow skeleton

- [ ] `cp /home/walker/Documents/personal/tigerbeetle/.github/workflows/release_validate.yml`
  → our `.github/workflows/release_validate.yml`.
- [ ] Surgical trims: TB-binary-specific validation steps (format,
  inspect integrity) drop. Keep the triggering shape
  (`on: push: tags: [v*]`) and the job skeleton.
- [ ] Fresh content: validate-our-artifact-shape (e.g., ship
  `./zig-out/bin/tiger-web` with `start`/`trace`/`schema`/`benchmark`
  subcommands, run a smoke).
- [ ] Outcome: when we tag `v0.1`, CI already has a validation
  pipeline. No retroactive workflow scramble when releases actually
  start shipping.

Effort: ~1 hour (cp + trim + skeleton).
Blocks: nothing. Useful as an anchor when release story is
designed.

### 7a. Untrack native-addon binaries; CI rebuilds on every run ✅ DONE (2026-04-27)

Shipped as commit `d83003d`. Moved
`packages/ts/native/dist/**/shm.node` into `.gitignore`. `focus_exe.step.dependOn(native_addon_step)`
in `build.zig` already auto-rebuilds; verified by `rm -rf
packages/ts/native/dist/` followed by `zig build` reproducing all
four platform addons from source. Source-to-binary drift is now
mechanically impossible.

(Original tier-2 description follows for historical record.)

- [ ] `packages/ts/native/dist/{aarch64,x86_64}-{linux,macos}/shm.node`
  are checked into git. Verified (2026-04-24) that `zig build
  native-addon` run back-to-back produces *byte-identical*
  binaries — so there's no non-determinism to fix. The drift
  that prompted this follow-up is **source-to-binary drift**:
  something between the last commit of these binaries
  (`c06ccf1`, weeks ago) and now produces a different binary
  from the same unchanged source. Root cause not yet
  investigated — candidates include toolchain version, OS, or
  a non-determinism source not caught by the back-to-back test.
  Verify before prescribing a fix. Currently nothing catches
  this — no CI step fails when the committed addon diverges
  from what the source would build. Per CLAUDE.md: *"prebuilt
  artifacts drift — CI must rebuild from source."*
- [ ] Remediation: move `packages/ts/native/dist/*` into
  `.gitignore`. CI runs `zig build native-addon` before any step
  that consumes the addon (`npm run build` in
  `examples/ecommerce-ts`, sim-tests that load the addon, etc.).
  Source-to-binary drift becomes impossible by construction.
- [ ] Outcome: no tracked-binary-vs-source-drift class of bug;
  no phantom dirty-tree from unrelated `zig build native-addon`
  invocations; the addon is regenerated deterministically on
  every CI run from the source in that commit.

Effort: ~1 h (.gitignore + CI wiring + verify every consumer
rebuilds first).
Blocks: nothing; orthogonal to benchmark-tracking. Filed here
(not in `benchmark-tracking.md`) because it's TB-alignment
concerning prebuilt artifacts, not benchmark infrastructure.

## Tier 3 — architectural, high cost

Load-bearing investments. Don't do unless the correctness story
explicitly needs them.

### 8. VOPR-analog state-space explorer

- [ ] Design a scenario-description format for our cluster-like
  shape: server + sidecar + HTTP client, with injectable faults
  (sidecar restart mid-dispatch, HTTP parse races, WAL recovery
  under concurrent writes, SHM slot contention).
- [ ] Build the explorer: PRNG-driven scenario selection, bounded
  state-space search, assertion of global invariants after each
  step.
- [ ] Integrate into CI (like TB runs VOPR per-commit with seeds).
- [ ] Outcome: the single biggest correctness win available. VOPR
  is what makes TigerBeetle trust its distributed correctness
  claims; an analog would give us equivalent confidence in our
  sidecar dispatch + WAL durability.

Effort: weeks (TB's VOPR is several thousand lines; ours would
be domain-specific but comparable scale).
Blocks: nothing today; unlocks "we trust our concurrency story"
as a first-class claim.

### 9. Generative sim-test scenario framework

- [ ] Move our ~27 hand-written `sim.zig` scenarios toward
  scenario-generator patterns. Describe valid state transitions
  once; let the framework explore combinations.
- [ ] Outcome: scenario coverage scales with state space, not
  with hand-written test count. Regression classes we haven't
  thought of get exercised automatically.

Effort: weeks (major sim-test restructure).
Blocks: nothing; subset of VOPR work; can be done independently.

## Structural patterns — low priority, informational

- **`docs/` taxonomy alignment.** TB: `docs/coding/`, `docs/internal/`,
  `docs/operating/`, `docs/TIGER_STYLE.md`. Ours: `docs/guide/`,
  `docs/internal/`, `docs/plans/`. Different but not wrong. No
  action unless a doc genuinely doesn't fit our taxonomy.
- **Commit-message style.** TB: imperative mood, ≤72 char first
  line, `subsystem: summary` prefix. We mostly do this; a formal
  template in `.gitmessage` or `CLAUDE.md` would tighten. ~5 min
  if we want it.
- **`--skip-kcov` long-form flag convention.** Already in G.0 plan;
  noting here for completeness.

## Prioritization — if you want a shortlist

- **If goal is "dashboard feels like TB's":** covered by
  `benchmark-tracking.md` Phase G (items 1–5 were moved there).
- **If goal is "infrastructure that future TB-matches land on":**
  items 6 + 7 + 7a (~3-4 hours total).
- **If goal is "correctness story matches TB":** item 8 alone is
  the load-bearing one. Item 9 is a stepping-stone.

Remaining items (6–9) are orthogonal to benchmark-tracking — Phase G
ships without them.
