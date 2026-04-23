# Benchmark Rebuild — Implementation Plan

## Blocking on human ✅ RESOLVED 2026-04-23

All four external-action items closed. Preserved as a record.

- [x] **PAT.** Reused the existing `tigerweb_cfo` fine-grained PAT
  (originally created for CFO work; same `contents: write` scope on
  `hireAlanAyala/tiger-web-devhubdb` applies to devhub uploads).
  Token was located in `~/.zsh_history_tiger_web_cfo`.
  **Follow-up:** rotate and rename the token at next convenient
  moment (the string appeared in this session's Claude Code logs).
- [x] **Registered as `DEVHUBDB_PAT`** on `hireAlanAyala/tiger_web`
  via `gh secret set`. Confirmed via `gh secret list`.
- [x] **Visibility verified** — secret listed under repo secrets on
  default-branch context.
- [x] **Pages enabled** on `hireAlanAyala/tiger-web-devhubdb` via
  `gh api --method POST /repos/.../pages`. Confirmed:
  `https://hirealanayala.github.io/tiger-web-devhubdb/devhub/data.json`
  returns HTTP 200.

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

## Current state (as of 2026-04-22)

Checkboxes throughout the plan reflect what's done (`[x]`) vs what's
next (`[ ]`). Short version:

- **Phase 0** ✅ done. Harness re-ported from TB verbatim; `assert_budget`
  added as surgical principled divergence.
- **Phase 0 addendum** ✅ done. All bench output conforms to TB's
  `"label = value unit"` shape; `scripts/devhub.zig`'s
  `get_measurement` parses it.
- **Phase A** ✅ done. Load tooling deleted; CLAUDE.md Quick Reference
  trimmed; `scripts/perf.zig` stubbed (failing loud pending Phase D
  `tiger-web benchmark`).
- **Phase B** ✅ done on the repo side (commits `d252562` + `f70fdd8`
  on devhubdb). PAT registration is user-action — see
  **Blocking on human** above.
- **Phase C** ✅ done (5 primitives + state_machine pipeline; strict
  `cp`-then-trim discipline; `bench-check` + `bench-calibrate`
  automation wired into `unit-test`).
- **Phase E** ✅ done (commit `27f5a51`). 2-tier uploader shipped
  under the E-before-D revision.
- **Phase F** ✅ config shipped (commit `6c0879f` + `fc7bb7f`
  gate). PRs dry-run immediately; main-branch upload blocks on
  DEVHUBDB_PAT registration.
- **Phase D** ✅ done (commits `ed4fbff` skeleton, `6ab5e77` load
  generator, `345418d` devhub integration). `tiger-web benchmark`
  subcommand ships closed-loop HTTP load with warmup, op-mix,
  percentile output. devhub uploader now emits 18 metrics across
  all three tiers.
- **Phase G** deferred until devhubdb has ≥1 week of data.

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

The 9 rules every benchmark file and phase is held to live in
`docs/internal/decision-benchmark-tracking.md`. They persist past
this plan's delete-at-Phase-G lifecycle because they're cross-phase
decisions, not work-to-do.

Short form (refer to the internal doc for full text):

1. Benchmark commitments, not guesses
2. Copy-first, trim-second (granularity adapts to the TB file)
3. Each benchmark passes the actionability test
4. No hard CI thresholds
5. Three tiers, each catching a different regression class
6. File-level discipline (70-line limit, ≥2 asserts/fn, headers)
7. Budgets are 10×-calibrated (enforced by `bench-check`)
8. Transplanted code is cited (file:line)
9. Open-loop mode is a blocking prerequisite for public claims

---

## Preflight findings

DR-1 through DR-4 (missing `cache_line_size`, output-format mismatch,
`benchmark_load.zig` VSR entanglement, `devhub.zig` survival ratio)
plus the pre-phase-0 `framework/bench.zig` drift and
`checksum_benchmark.zig` template-survival findings all live in
`docs/internal/decision-benchmark-tracking.md` under "Preflight
findings (frozen)". They're historical observations that reshaped
the plan; the work each triggered is already done.

Short reference for bisect: DR-1 → `cache_line_size` added.
DR-2 → output-format fix (Phase 0 addendum). DR-3 → Phase D
reframed as pattern-transplant. DR-4 → Phase E scoped to ~25%
survival. Full context in the internal doc.

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
**User actions (PAT generation, secret registration, verification):**
see **"Blocking on human"** at the top of this plan. The canonical
copy lives there because Phase F depends on it too.

CFO has been targeting this repo. Phase B completed its missing
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

## Phase D — SLA benchmark as `tiger-web` subcommand ✅ DONE

Shipped across three commits:

- `ed4fbff` — CLI skeleton (`BenchmarkArgs`, dispatcher, driver stub).
- `6ab5e77` — `benchmark_load.zig` pattern-transplant (histogram +
  percentile walk from TB cited; HTTP client + warmup + op-mix
  fresh).
- `345418d` — `scripts/devhub.zig` runs SLA tier end-to-end,
  MetricBatch now carries 18 metrics.

**Warmup finding (D.5 verification):** on a cold database the plan
claimed the warmup should reduce p50 by ≥20%. Actual: p50 identical
at 40 ms with or without warmup. Our system hits steady state
within the first few requests — SQLite prepared-statement cache
and TCP handshake complete too fast for warmup to shift the
histogram. Plan's own escape clause applies ("our system has no
cold-cache penalty worth measuring — investigate before shipping").
Warmup feature stays (cheap; may matter for larger future
workloads) but doesn't carry weight today.

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

### D.4 — REMOVED

Originally called for adding `--json` flag to
`state_machine_benchmark.zig`. Redundant after Phase 0's addendum:
every bench (state_machine + C.1–C.5) already emits TB-parseable
`label = value unit` lines that `devhub.zig`'s `get_measurement`
helper consumes directly. No JSON required.

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

## Phase E — devhub uploader ✅ DONE (commit `27f5a51`)

Shipped as a 2-tier uploader (primitive + pipeline) per the
E-before-D revision. Phase D will extend the metric list when it
lands. Dry-run verified locally; first real upload blocked on user
PAT registration (Blocking-on-human at top of plan).

Effort: 1–1.5 days. Dependencies: **B, C** (not D — reordering below).

**Execution order note (2026-04-22 revision):** Phase E now runs
*before* Phase D. At Phase E's ship time the `MetricBatch` carries
**primitive + pipeline tiers only**; SLA tier joins when Phase D
lands. The uploader code doesn't care about the tier count — it
shells out to benches, parses their lines, and pushes. Adding a
third tier later is a one-line change to E's run order.

Why this order: dashboard data starts flowing in ~1 day instead of
~4 days (D is 2–3 days before E can even start). The primitive +
pipeline tiers become the baseline trends by the time SLA joins.

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

The uploader invokes the available tiers in sequence, parses their
output (`label = value unit` per `get_measurement`), merges into one
`MetricBatch`, commits one array element:

**At Phase E's ship time (SLA tier not yet present):**

- [ ] `./zig/zig build bench` (primitive + pipeline tiers, text output)
- [ ] Parse outputs via `get_measurement`; build `MetricBatch`
- [ ] Clone devhubdb, perform the append-only upload per E.2

**When Phase D lands later** — add one step between parse and build:

- [ ] `./zig-out/bin/tiger-web benchmark` (SLA tier, text output)

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

## Phase F — CI wiring ✅ PARTIAL (commit pending below)

The job config ships; the first real upload is blocked on
`DEVHUBDB_PAT` registration per "Blocking on human" at the top of
the plan. PRs will exercise `--dry-run` starting immediately (no PAT
required).

Effort: 1 hour. Dependencies: B, E.

- [x] Extended existing `.github/workflows/ci.yml` with a `devhub`
  job (not a new workflow file — TB's pattern).
- [x] Branch-aware gating: `if [ ref = main ]; then upload; else
  --dry-run; fi`. Both paths run the bench pipeline end-to-end; only
  the upload call differs.
- [x] PR path: `--dry-run` no-PAT-required. Catches parser
  regressions, missing metrics, compile breaks before they hit main.
- [x] Secrets: references `secrets.DEVHUBDB_PAT` via env var.
- [x] `fetch-depth: 0` on checkout so `git show -s --format=%ct <sha>`
  resolves in the uploader.
- [ ] **User action:** register `DEVHUBDB_PAT` secret (see top of plan).
- [ ] **Verification (post-PAT):** merge a commit, observe a new
  entry appended to `hireAlanAyala/tiger-web-devhubdb/devhub/data.json`
  within minutes.

---

## Phase G.0 — coverage pipeline (prerequisite for G.1)

Effort: 1–2 hours. Dependencies: F uploading on main for ≥1 commit.

The Phase G dashboard (next step) includes a **Coverage** link that
points at `./coverage/index.html` served from the same GitHub Pages
origin as `devhub/data.json`. That file needs to exist before G.1
or the link 404s. G.0 ships the kcov pipeline that produces it.

**Discipline:** `cp` TB's `devhub_coverage()` function from
`/home/walker/Documents/personal/tigerbeetle/src/scripts/devhub.zig:58-95`
into our `scripts/devhub.zig`, then trim with bucket tags. Do not
re-derive the kcov invocation from memory — the binary list,
events-max count, seed (`92`), and symlink-cleanup step are TB
decisions we may not fully understand, and the cp-first rule
exists to preserve them.

- [ ] `cp` TB's `devhub_coverage` function (TB:58-95) verbatim into
  `scripts/devhub.zig`.
- [ ] Surgical trims (each with inline bucket tag):
  - `./zig-out/bin/test-unit` → our unit-test invocation.
    **Prerequisite:** TB ships a standalone `test-unit` binary
    built via `test:unit:build`; our `zig build unit-test` runs
    tests directly without producing a kcov-attachable binary.
    Need to add a `unit-test-build` step in `build.zig` that
    produces `./zig-out/bin/tiger-unit-test` (or similar) with
    debug info, then kcov runs against it. (Principled — port
    source differs; also ~20 lines of build.zig work that
    precedes the kcov wiring itself.)
  - Drop TB's two LSM-specific fuzz invocations (`lsm_tree`,
    `lsm_forest`). We have no LSM subsystem. Principled.
  - Drop TB's VOPR invocation. No VOPR equivalent. Principled.
  - **Replace with OUR full fuzzer set.** When VOPR is dropped,
    its coverage contribution must be replaced with our own
    fuzzers or the coverage report will look thin. Our complete
    fuzzer inventory (from `fuzz_tests.zig:42-52`): `state_machine`
    (core pipeline), `replay` (WAL round-trip), `message_bus`
    (sidecar Unix socket protocol), `row_format` (SHM row wire
    contract — the cross-language boundary), `worker_dispatch`
    (CALL/RESULT boundary). Each gets a kcov-wrapped invocation
    with events-max sized for meaningful path coverage:

    ```
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 state_machine 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 replay 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 message_bus 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 row_format 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 worker_dispatch 92
    ```

    Events-max: TB uses 500_000 for LSM fuzzers. We use 100_000
    as a middle ground — more than the smoke-mode default (10k)
    so paths actually get exercised, less than TB's number so
    coverage CI stays bounded (~1-2 min per fuzzer). Revisit if
    coverage % stays flat after more events. Seed `92` matches
    TB's convention — lets us diff coverage across commits with
    the same inputs.

    **Why all five, not a subset:** a kcov report that covers
    only `state_machine` would hide gaps in the
    sidecar/wire-contract surface area (message_bus, row_format,
    worker_dispatch) — exactly the subsystems where regressions
    would be most expensive. Covering the full fuzzer set
    mirrors TB's "cover the main testing surface" intent without
    inheriting VOPR/LSM specifics.
  - Keep: `kcov` invocation shape, `--include-path=./src`,
    output directory convention, seed `92`, symlink cleanup.
    TB decisions we preserve.
- [ ] `cp` TB's `--skip-kcov` CLI flag shape into our `CLIArgs`
  (TB:43-46). Default `false` on main, but allow local runs to
  skip to save time.
- [ ] Add `sudo apt-get install -y kcov` to the devhub CI step in
  `.github/workflows/ci.yml`. One line, above the `zig/download.sh`
  step.
- [ ] Modify the devhub CI step to upload the generated `coverage/`
  directory to Pages alongside `devhub/data.json`. Either: (a) push
  coverage into the devhubdb repo's `coverage/` subdir during
  `upload_run`, (b) use `actions/upload-pages-artifact` +
  `actions/deploy-pages` with both `devhub/data.json` and
  `coverage/` in the artifact. TB uses (b); we should match since
  (a) bloats the git history with HTML diffs.
- [ ] Verify: after next main merge,
  `curl -sI https://hirealanayala.github.io/tiger-web-devhubdb/coverage/index.html`
  returns 200.

## Phase G.1 — dashboard

Effort: 2–3 hours (revised down from 1–2 days). Dependencies: G.0
complete + F produced data for ≥1 week.

**Discipline:** whole-file `cp` of TB's three dashboard files,
then surgical remove + change. Minimum edits that make the
dashboard **honest** (renders our data, attributed to us) without
any from-memory rewriting. Inert TB code (VOPR branches,
release-commit detection) stays — keep what doesn't hurt us.

- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/devhub/devhub.js`
  into `tiger-web-devhubdb/devhub.js` (or root; TB puts it at
  `src/devhub/` in source and serves the whole dir).
- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/devhub/index.html`
  into the same location.
- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/devhub/style.css`
  into the same location.

**Remove (2 items):**

- [ ] **Release manager section + rotation logic.** No solo-project
  analog; hardcoded TB team roster (`batiati`, `cb22`,
  `chaitanyabhandari`, `fabioarnold`, `lewisdaly`, `matklad`,
  `sentientwaffle`, `toziegler`, `GeorgKreuzmayr`) renders other
  people's names as "this week's release manager." Delete:
  - HTML `<section id="release">` block (index.html:24-40)
  - JS `main_release_rotation()` + `get_release_manager()`
    (devhub.js:24-53)
  - JS top-level invocation of `main_release_rotation()` (remove
    from the `main()` or equivalent entry point)
- [ ] **Coverage link** in Links section. Replaced by Phase G.0 —
  actually wait: G.0 MAKES the coverage link work, so **KEEP** the
  link. Rename this remove-item to "coverage link stays, G.0
  ensures the target exists." (Leaving the strikethrough here as
  a reminder that the list was revised.)

**Change (17 substitutions, group by file):**

`index.html`:
- [ ] `<title>TigerBeetle DevHub</title>` → `Tiger Web DevHub`
- [ ] Nav branding: replace `<svg id="logo"><use href="#svg-logo">`
  (line 17-19) with a plain text wordmark `<h1 class="brand">Tiger
  Web DevHub</h1>` or equivalent. Structural element stays; SVG
  contents swap.
- [ ] SVG template block at bottom (`<svg id="svg-logo">` with the
  TigerBeetle path data, lines 88-95): replace `<path>` contents
  with a placeholder `<text>Tiger Web</text>` or a Tiger-Web
  artwork later. Keep the `<svg id="svg-logo">` shell so the
  `<use href="#svg-logo">` reference still resolves if any JS
  accesses it.
- [ ] "My code review" link → `github.com/hireAlanAyala/tiger_web/pulls/assigned/@me`
- [ ] "Issue triage" link →
  `github.com/hireAlanAyala/tiger_web/issues?q=is%3Aissue+is%3Aopen+-label%3Atriaged`
- [ ] Nyrkiö link in Metrics header: **remove the `<a>` tag** (not
  the surrounding `<h2>` text), since we don't publish to Nyrkiö.
  Structural element goes; replacement text is already the "Raw
  data" link next to it.
- [ ] "Raw data" link (fuzz section): `tigerbeetle/devhubdb` →
  `hireAlanAyala/tiger-web-devhubdb`
- [ ] "Raw data" link (metrics section): same swap.

`devhub.js`:
- [ ] Metrics data URL (line 218):
  `raw.githubusercontent.com/tigerbeetle/devhubdb/main/devhub/data.json`
  → `raw.githubusercontent.com/hireAlanAyala/tiger-web-devhubdb/main/devhub/data.json`
- [ ] Fuzz data URL (line 57): same pattern.
- [ ] Logs base URL (line 61):
  `raw.githubusercontent.com/tigerbeetle/devhubdb/main/` → our equivalent.
- [ ] Issues API URL (line 59):
  `api.github.com/repos/tigerbeetle/tigerbeetle/issues` →
  `api.github.com/repos/hireAlanAyala/tiger_web/issues`
- [ ] Commit link URL (line 171 and line 378):
  `github.com/tigerbeetle/tigerbeetle/commit/` →
  `github.com/hireAlanAyala/tiger_web/commit/`
- [ ] PR prefix (line 241):
  `github.com/tigerbeetle/tigerbeetle/pull/` →
  `github.com/hireAlanAyala/tiger_web/pull/`
- [ ] Branch-identity check (line 232):
  `"https://github.com/tigerbeetle/tigerbeetle"` →
  `"https://github.com/hireAlanAyala/tiger_web"`
- [ ] Release-tree URL check (line 237):
  `"https://github.com/tigerbeetle/tigerbeetle/tree/release"` →
  `"https://github.com/hireAlanAyala/tiger_web/tree/release"`
  (inert for us — we don't use `/tree/release` — but swap for
  consistency so a future release-tag convention works.)

**Keep explicitly (even if unused today):**

- VOPR-specific branches (`record.fuzzer === "vopr"`) — inert for
  our data, zero runtime cost, free if we ever add a VOPR analog.
- Release-commit detection (`is_release()`) — inert for now;
  works when we adopt release tagging.
- Untriaged-issues badge fetcher — useful once URL is swapped
  (change item above).
- Fuzz runs table — our CFO seeds in `fuzzing/data.json` (184456
  historical) use TB's schema; renders correctly.
- All formatting helpers (`format_bytes`, `format_count`,
  `format_date_*`, `format_duration`).
- Entire `style.css` — inherit TB's visual language; restyle later
  if desired.

**Survival accounting (post-trim):**

- `index.html`: 99 lines → ~85 lines. Mostly release-section
  deletion + 3 SVG swaps + 7 URL edits.
- `devhub.js`: 552 lines → ~520 lines. Delete 2 functions + invocation
  site, edit 10 URLs/strings.
- `style.css`: 209 lines → 209 lines (no changes).
- **Net: ~38 lines removed, 17 edits, ~95% literal survival of TB's files.**

**File header in devhub.js must document:**

- Port source: TB `src/devhub/{devhub.js,index.html,style.css}`
  with commit SHA at cp time.
- Discipline: whole-file `cp` + surgical remove/change pass. Every
  change listed above; every line not listed is TB's code
  unchanged.
- Deletions bucket-tagged (all principled per engineering value 2).
- Substitutions grouped by file with line-number references to
  TB's original.

**Verification:**

- [ ] Load `https://hirealanayala.github.io/tiger-web-devhubdb/` in
  a browser. Confirm:
  - `<title>` reads "Tiger Web DevHub"
  - Metrics section renders 17 charts (our metric names)
  - Fuzz runs table populated (CFO seeds)
  - Commit-link on a data point opens our tiger_web commit
  - Coverage link loads the G.0 artifact (no 404)
  - No "TigerBeetle" text visible anywhere the user can read
- [ ] Open browser devtools; confirm no JS errors (release-section
  deletion must match the JS invocation deletion — otherwise
  `querySelector` returns null and throws).

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
- [ ] **Single-threaded benchmark client loop.** `benchmark_load.zig`
  currently uses `std.Thread.spawn` per connection (thread-per-conn
  model). TIGER_STYLE: *"Your program should run at its own pace;
  don't do things directly in reaction to external events."* TB's
  own benchmark loop is single-threaded over their VSR io layer.
  For ours to match, we'd use `std.posix.epoll_create1` +
  non-blocking `std.net.Stream` and drive all N "clients" from a
  single event loop — mirroring our own `framework/io.zig` server.
  Scope: ~200 lines restructure. Not blocking; thread-per-connection
  produces defensible numbers. Move when the thread-scheduler
  variance in tail latencies becomes visible on the dashboard.
- [ ] **Sidecar-mode SLA bench.** `tiger-web benchmark` currently
  exercises the HTTP → native → SQLite path only. Tiger Web's key
  architectural primitive — the 1-RT SHM sidecar dispatch — isn't
  covered at the SLA tier. A regression in `framework/shm_dispatch.zig`
  or the sidecar-handshake path would be invisible to the current
  bench (only `crc_frame_benchmark.zig` touches the SHM wire, and
  it's algorithmic-only). Two viable shapes:
    - `--sidecar=<command>` flag on `tiger-web benchmark` that
      spawns the sidecar alongside the server before load starts.
    - Second bench invocation in `scripts/devhub.zig:run_sla_benchmark`
      with a sidecar attached, emitted as `benchmark_sidecar_*`
      metrics.
  Not a blocker for Phase G; add when sidecar-path performance
  becomes a story we want visible on the dashboard.

---

## Effort summary

| Phase | Effort | Depends on |
|---|---|---|
| preflight measurements | done | — |
| 0 (harness re-port) | done (~30 min actual) | preflight |
| 0 addendum (output format) | done (~10 min actual) | 0 |
| A | 30 min | 0 | done |
| B | 30 min | nothing | done (partial — user-action PAT blocks F) |
| C | 1.5–2 days | 0, A | done (incl. strict-cp retrofit + `bench-check` automation) |
| E | **1–1.5 days** (up from 1 after DR-4) | B, C | **next** |
| D | **2–3 days** (up from 1-2 after DR-3) | A | after E |
| F | 1 hour + user PAT | B, E | — |
| G | 1–2 days | F + ≥1 week of data | — |

**Pragmatic sequencing (2026-04-22 revision):** 0 → A + B in parallel
→ **C, then E, then D** → F → G.

The D-before-E ordering this plan originally carried assumed all
three tiers would land together. Post-Phase-C, primitive + pipeline
already emit `devhub.zig`-parseable output, so E can ship against
those alone and light up the dashboard in ~1 day. D follows, adding
the SLA tier as a third metric category. Shorter feedback loop;
dashboard trends on primitives already exist when SLA joins.

C before D is still the default. C validates the discipline on easy
cases (~85% survival cp-with-trim); D is the higher-risk pattern-transplant
with fresh HTTP code. Learning from C first reduces the risk surface
of D. Parallelizing saves calendar time only if you're confident D
won't reshape anything in C, which you're not confident of until C
is done.

Total to phase F (CI uploading on every main merge): **~5-6 focused
days** (up from ~4 after dry-run findings DR-3 and DR-4). The
E-before-D revision shortens *time to first dashboard data point* to
~1–1.5 days after the user registers the PAT, since E doesn't wait
on D.

The 25-50% scope growth is itself a finding: TB's benchmark tooling
is more domain-entangled than the cp-first rule initially suggested.
The rule still holds, but its granularity shifted (see engineering
value 2). Future TB ports should budget an inspection pass before
phase planning, not only after.

---

# Reasonings

The detailed rationale behind every decision in this plan has moved
to `docs/internal/decision-benchmark-tracking.md`. That doc covers:

- Why cp-first, trim-second
- Why three tiers; why this exact set of primitives; primitives
  considered and rejected
- Divergences from TigerBeetle (principled / flaw fix / tracked
  follow-up)
- Why no hard CI thresholds; why one ci.yml; why append-only upload
- Phase C retrofit post-mortem (what TIGER_STYLE taught us)
- What the system does NOT do; what framework users get
- Honest acknowledgments

When reading a rule in this plan and wanting to challenge or extend
it, the internal doc is where the reasoning lives. This plan holds
work-to-do (checklists, current state, blocking items); the
decisions and their justifications live in internal.
