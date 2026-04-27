# Benchmark Tracking — Remaining Work

All phases through F are shipped (commits up to `345418d`). Primitive
+ pipeline + SLA tiers emit `devhub.zig`-parseable output; CI uploads
to `hireAlanAyala/tiger-web-devhubdb` on every main merge;
`https://hirealanayala.github.io/tiger-web-devhubdb/devhub/data.json`
returns HTTP 200.

Frozen context (port sources, DR-1..4 findings, engineering values,
per-phase histories) lives in
`docs/internal/decision-benchmark-tracking.md`. This plan holds only
what's left: retrofit the TB-audit divergences, then ship G.0 and G.1.

**Guiding bias (audit outcome, 2026-04-23):** we've been repeatedly
burned by omitting features "we don't need today" — project moves in
days, not months. Divergence from TB is suspicious, not virtuous.
Every dropped-from-TB decision in E's current `scripts/devhub.zig`
and D's current `benchmark_load.zig` gets revisited under this
lens. Retrofits below reflect the audit's under-justified divergences.

## Sequencing

TB's "right primitive first" lens: H.3 and H.4 are **corrective** —
every benchmark datapoint landing in `devhubdb` today is warmup-
masked (H.3) or thread-scheduler-jittered (H.4). The rest of H is
**additive** (new metrics, Nyrkiö destination, cleanup). Stop the
bleeding before adding instruments. G.0 is a parallel track
(coverage is orthogonal to benchmark correctness).

Ordered execution:

```
1. H.3 + H.4         stop the bleeding (parallelizable; corrects data)
2. G.0.a             build.zig split lands before build-time metrics
3. H.2               metrics, including build-time, now on stable base
4. H.1 + H.5         additive / cleanup (anytime after 1)
5. G.0.b             kcov wiring
6. [≥1 week clock starts from step 1 completion]
7. G.1               dashboard (reads clean week-of-data)
```

**Why the clock starts at step 1, not now:** G.1 renders time-series.
Charts whose early portion mixes pre-H.3/H.4 (tainted) and post
(clean) data show a step-function that isn't a real regression. The
first thing a viewer sees would be a discontinuity caused by the fix,
not by the code under test.

**Why G.0.a precedes H.2:** G.0.a adds a `unit-test-build` step to
`build.zig`. H.2's `build_time_ms` / `build_time_debug_ms` baselines
step-change the day G.0.a lands. Inverting the order puts a
discontinuity into the build-time metrics' first week.

**Why G.0.b is parallel, not a blocker:** kcov wiring affects
coverage artifact only; it does not produce or modify benchmark
datapoints. Can run alongside H.1/H.2/H.5 without ordering constraint
against them. Must land before G.1 (dashboard's Coverage link target).

---

## Phase H — retrofit audit divergences

Effort: ~1 day total. Dependencies: none for H.3/H.4 (they start
immediately). H.2 waits on G.0.a.

The TB-audit (2026-04-23, logged below) flagged six divergences
in shipped code. Two are **corrective** (H.3 warmup, H.4 client
loop) — they invalidate the data we're collecting *right now*.
Three are **additive** (H.1 Nyrkiö, H.2 metrics, H.5 cleanup) —
they add signal once the corrective work is in.

Order within H: **corrective → additive.** Every hour H.3/H.4 are
delayed, `devhubdb` accumulates another tainted datapoint that G.1
will have to render around.

### H.3 — Kill or flag-gate warmup [CORRECTIVE — DO FIRST] ✅ DONE

Status (2026-04-23): `--warmup-seconds` flag and warmup logic were
stripped from `benchmark_load.zig` post-D.5. Only a stale header
comment remained referencing warmup as "written fresh"; fixed.
`main.zig:762-769` already documents the decision. No runtime
change needed.

Phase D shipped `--warmup-seconds` as a "flaw fix" principled
addition. D.5 verification measured warmup's p50 impact at 0%
(our system reaches steady state in <1s). Shipping a feature
that measurably does nothing is "don't ship known-throwaway
code" (CLAUDE.md). It's also a determinism hazard — warmup that
discards measurements hides cold-path cost by design.

- [x] Deleted `--warmup-seconds` flag, warmup loop, and warmup
  time-window logic from `benchmark_load.zig` (pre-H.3 strip).
- [x] Updated `benchmark_load.zig` header to remove the
  "principled flaw fix: warmup" claim.
- [x] `main.zig:762-769` documents the decision and the 0% D.5
  measurement.

Verify: next CI run on main pushes a benchmark datapoint with no
warmup-masking. This datapoint is **t=0 for the ≥1-week clock**
that gates G.1.

### H.4 — Single-threaded client loop [CORRECTIVE — DO FIRST] ✅ DONE

Status (2026-04-23): rewrote `benchmark_load.zig` from
thread-per-connection (`std.Thread.spawn`) to single-threaded
async-completion loop driven by **`framework/io.zig`** (io_uring on
Linux, kqueue on macOS — the same IO layer the server uses).
Per-client state machine: `connecting → writing → reading →
writing | done | failed`. Callbacks fire on completion; each client
holds one `IO.Completion` reused across ops.

**Decision detour (logged for posterity):** a first-pass attempt
used `std.posix.epoll_*` directly. Audit flagged this as a
right-primitive violation — the project had one IO primitive
(io_uring/kqueue via `framework/io.zig`); raw epoll would have
been a second. Reverted (commit `b62d3ac`); replaced with an
extension of `framework/io.zig` that exposes the client-side
verbs (`open_client_socket`, `connect`) the server didn't need.
Net result: one IO abstraction across the project.

**Correction (deep audit 2026-04-24):** the original claim was that
the benchmark becomes "simulation-testable the day we want that
(drop in `SimIO` with no harness change)." Verified false. `SimIO`
in `sim_io.zig` exposes `connect_client(self, client_index,
target_listen_fd)` — a different signature from
`framework/io.zig`'s new `connect(fd, address, completion, context,
callback)`. Swapping SimIO for IO in `benchmark_load.zig` wouldn't
compile. Accurate claim: "simulation-testable once SimIO gains a
matching `connect` verb" — an extension in the same shape as the
framework/io.zig → framework/io/linux.zig pattern. Tracked as a
follow-up if/when we want sim-tested benchmark fault injection.

Smoke-test results (64 conns, 10k requests, local server):
- 9984 requests, 0 errors, 12.5k req/s
- p1=4ms, p50=5ms, p99=**6ms**, p100=10ms
- Tighter tail than the epoll version (p99 6 vs 7, p100 10 vs 11) —
  io_uring removes syscall overhead that epoll + read/write carry.

File growth: `benchmark_load.zig` 664 → 800 lines; `framework/io.zig`
197 → 245 lines (+48, added `open_client_socket` + `connect`
wrapper). No other file touched. Reconnect-on-failure removed;
failed connections terminate bounded per TIGER_STYLE.

Parallelizable with H.3 — different files, no shared code paths.

### H.2 — Add four missing metrics [ADDITIVE — AFTER G.0.a] ✅ DONE

Status (2026-04-23): added four of the originally-planned five
metrics to `scripts/devhub.zig`. Fifth (`ci_pipeline_duration_s`)
deferred on TB-lens review — see tracked follow-ups. Dashboard now
carries **22 metrics** across all three tiers + build-signals +
log-volume.

Ported from TB (`src/scripts/devhub.zig`, bucket tags inline):

- `executable_size_bytes` / `build_time_ms` / `build_time_debug_ms` —
  TB:107-127 verbatim pattern. Debug build timer → cache-clear →
  release build timer + `statFile("zig-out/bin/tiger-web").size`.
  Principled divergence (documented inline): dropped TB's
  `defer deleteFile("tigerbeetle")` — Zig's `addInstallArtifact`
  overwrites atomically, no stale-state risk.
- `bench_log_lines` — `replica log lines` analog (TB:193). Captured
  from SLA benchmark's stderr via `exec_stdout_stderr`;
  `std.mem.count(u8, stderr, "\n")`.

**Deferred: `ci_pipeline_duration_s`.** TB queries
`gh run list -e merge_group` which returns a completed prior run.
Our `push`-triggered CI runs devhub *inside* the workflow it would
measure, so `updatedAt - startedAt` is a partial duration, not the
whole pipeline. Shipping a metric whose value doesn't match its
name violates TIGER_STYLE's determinism + explicit principles —
deferred until we split devhub onto a `workflow_run` trigger.

Also removed the redundant second release build — the new
build-time measurement already produces `zig-out/bin/tiger-web` in
release mode, so the SLA bench reuses it.

Verification (local dry-run of `zig build scripts -- devhub
--sha=$HEAD --dry-run`):
- `executable_size_bytes = 10591752` (10.6 MB release).
- `build_time_ms = 48647` (cold-cache full release build).
- `build_time_debug_ms = 68` (warm-cache incremental; CI will see
  cold-cache full debug time).
- `bench_log_lines = 2` (info + warn from current benchmark).
- All 22 metrics present in the MetricBatch JSON payload.

### H.1 — Preserve `upload_nyrkio` token-optional [ADDITIVE] ✅ DONE

Status (2026-04-24): ported `upload_nyrkio` from
`tigerbeetle/src/scripts/devhub.zig:454-466` into our
`scripts/devhub.zig`. Near-verbatim — one principled divergence:

- **`env_get` → `env_get_option`.** TB's `shell.env_get` errors on
  a missing env var; the outer `catch |err|` at TB:370-372 catches
  + logs. We use `env_get_option` (returns null) so the skip is
  explicit at the call site: `orelse { log.info("...skipping..."); return; }`.
  End-to-end behavior identical to TB; intent (optional
  destination) visible locally instead of only in the caller's
  catch.

Call site added alongside `upload_run` with the same non-fatal
catch shape (TB:370-372). Dry-run branch untouched.

File header: `upload_nyrkio` moved from "Deletions" to
"Transplanted" with TB line citations + divergence note.

Preflight applied (new memory
`feedback_preflight_consumer_shape_before_porting.md`): confirmed
`shell.http_post`, `shell.fmt`, `shell.arena.allocator()`,
`env_get_option` all present verbatim from TB; URL + env-var name
carry no tiger-web conflicts; dashboard link already kept in G.1
plan. No consumer shape mismatch surfaced — port is clean.

**Tracked follow-up (already in the list):** register a Nyrkiö
account and set `NYRKIO_TOKEN` in CI. Zero code change; the metric
destination goes from "no-op" to "active change-point detection"
the moment the secret lands.

### H.5 — Silent divergence cleanup [ADDITIVE] ✅ DONE

Status (2026-04-24):

- [x] `CLIArgs.dry_run` bucket-tagged as tiger-web-specific with
  rationale inline (PR path needs no-push mode per
  `.github/workflows/ci.yml`'s "devhub" job; TB's CLIArgs carries
  only `sha` + `skip_kcov`; we don't carry `skip_kcov` because
  kcov orchestration lands as its own step in G.0.b, not as a
  flag inside this file).
- [x] `shell.git_env_setup(.{ .use_hostname = false })` verified
  preserved in `upload_run`.
- [x] `shell.open_section("metrics")` verified preserved at the
  top of `devhub_metrics`.
- [x] `feedback_revisit_decisions_when_justifications_expire.md`
  gained a "Part 4 — 'we don't need X' deletion rationale is
  almost always wrong" section covering the generalizable lesson
  from the H.1 + H.2 audit cycle.

---

## Phase G.0 — coverage pipeline

Effort: 2 hours. Dependencies: H complete (so dashboard metrics are
final before G.1 cps the dashboard).

The G.1 dashboard includes a **Coverage** link pointing at
`./coverage/index.html` served from the same Pages origin as
`devhub/data.json`. That file needs to exist or the link 404s.
TB has one at `tigerbeetle.github.io/devhubdb/coverage/index.html`;
G.0 ships ours.

### G.0.a — `unit-test-build` standalone binary (hard prerequisite) ✅ DONE

Status (2026-04-23): added `tiger_unit_tests.zig` aggregator (mirrors
TB's `src/unit_tests.zig` — `comptime { _ = @import(...); }` per
test-carrying file, OS-gated for Linux-only modules) plus a
`unit-test-build` step in `build.zig` that installs the artifact to
`./zig-out/bin/tiger-unit-test`.

Ported verbatim from TB:
- `addTest(.{ .name, .root_source_file, ... })` → `addInstallArtifact(...)` →
  `step.dependOn(...)` shape (`tigerbeetle/build.zig:904-918`).
- `comptime { _ = @import(...); }` aggregator pattern
  (`tigerbeetle/src/unit_tests.zig`).

Tiger-web-specific: `link_sqlite(binary)` + `linkLibC()` on the
aggregated test artifact (our per-module test step applies these
per-module; the single binary needs both). OS-gated imports via
`builtin.target.os.tag == .linux` for io_uring / unix-socket / SHM
modules.

Verification:
- `zig build unit-test-build` → `zig-out/bin/tiger-unit-test`
  (18 MB ELF, `with debug_info, not stripped`).
- Direct run: 345/345 tests pass.
- `kcov --include-path=./ /tmp/kcov-test ./zig-out/bin/tiger-unit-test`
  → runs all 345 tests under ptrace, writes `index.html`. Coverage
  pipeline (G.0.b) can now attach.
- `zig build unit-test` unchanged — still runs tests in-process
  (backward-compat preserved).

Scope: `build.zig` +31 lines, `tiger_unit_tests.zig` new (60 lines).
Net ~90 lines, within the post-preflight estimate.

### G.0.b — kcov wiring ✅ DONE (coverage runs + is downloadable; not yet linkable)

Status (2026-04-24): ported TB's `devhub_coverage()` from
`tigerbeetle/src/scripts/devhub.zig:58-95` into our
`scripts/devhub.zig`. `--skip-kcov` flag added (TB:45 verbatim).
CI workflow installs kcov + runs with `sudo -E`. Coverage artifact
archived via `actions/upload-artifact@v4` on every run (PR and
main), 30-day retention.

**Honest scope note:** the original plan framed G.0.b as producing
"the coverage link G.1 points at." What shipped is narrower —
coverage **runs** in CI and is **downloadable** as a per-run
build artifact, but not yet **linkable** from a stable URL. The
Pages-URL target requires deciding how to unify serving with
devhubdb (different repo, different Pages origin); tracked as the
G.1 Coverage-link follow-up. Viewers with repo access can download
coverage-$SHA from the Actions UI in the meantime.

Preflight applied per the consumer-shape memory: discovered
tiger-fuzz's CLI takes positional args directly, no `--` separator
(unlike my initial guess). Caught before CI — the initial inline
`-- --events-max=...` would have failed on the first main merge.
Also confirmed 100k events is sufficient for `state_machine`'s
feature-coverage check (smaller values panic
`assert_full_coverage`).

Ported verbatim (bucket tags inline on the function docblock):

- `kcov --version` probe with `error.NoKcov` fallback.
- `open_section("coverage")` log grouping.
- `--include-path=./` (principled: flat layout, no `src/`).
- Symlink-cleanup loop for Pages compatibility (TB:88-93).
- Seed `92` across all 5 fuzzers; events-max 100_000.

Principled divergences:

- Binary names `test-unit` → `tiger-unit-test`, `fuzz` →
  `tiger-fuzz` (our prefix).
- Build steps `test:unit:build` → `unit-test-build` (G.0.a),
  `fuzz:build` → `install` (our fuzz is a regular exe).
- Dropped VOPR + LSM invocations; replaced with our 5 fuzzers
  (state_machine, replay, message_bus, row_format, worker_dispatch).
- `events-max=500000` → `100000` (middle ground between
  smoke-mode and TB's LSM run; ~1-2 min per fuzzer).
- Output dir `./src/devhub/coverage` → `./coverage` (flat root).

CI workflow changes:

- `sudo apt-get install -y kcov` added before zig download.
- `sudo -E` prefix on the devhub invocation (TB's pattern;
  belt-and-suspenders against credential-helper regressions).
- `NYRKIO_TOKEN` added to env (H.1 landed the uploader; CI just
  needs to pass the secret through — currently unset, graceful
  skip fires).
- `actions/upload-artifact@v4` archives `coverage/` as
  `coverage-$SHA`, retained 30 days. Build-artifact (not Pages) —
  unified Pages serving with `devhub/data.json` needs an
  architectural decision (separate Pages-origin for tiger_web vs
  devhubdb); tracked as G.1 Coverage-link follow-up.

Verification (local):

- Built `unit-test-build` + `install` via `zig build`.
- All 5 fuzzers run cleanly at `--events-max=100000` seed `92`:
  `state_machine` (220ms), `replay` (135ms), `message_bus`
  (153µs), `row_format` (3.9s), `worker_dispatch` (20ms). Each
  exits 0 with no feature-coverage or assertion panics.
- `kcov --include-path=./ /tmp/kcov-smoke ./zig-out/bin/tiger-fuzz
  --events-max=100000 state_machine 92` produced `index.html`.
  Attach path confirmed.

End-to-end run of the full `devhub_coverage()` (install kcov +
build both binaries + 6 kcov passes + symlink-cleanup + upload)
happens on first CI run after this commit lands.

---

## Phase G.1 — dashboard ✅ DONE (2026-04-27, restructured to TB-aligned single-origin)

**Live at:** `https://hirealanayala.github.io/tiger_web/` (TB-aligned
single-origin Pages on the main repo, matching TB's `src/devhub/`
layout). Coverage colocates at `./coverage/`.

**Architectural history:** initial G.1 ship (commit `f6594d6` on
devhubdb) put dashboard files in the data repo — a structural
divergence from TB's pattern (TB hosts dashboard in main repo, uses
devhubdb for data only). Restructured to single-origin Pages on
`hireAlanAyala/tiger_web` once private-repo Pages was unblocked
(GitHub Pro upgrade). Devhubdb reverts to data-only role.

**Shipped via:** dashboard files in `tiger_web/devhub/{devhub.js,
index.html,style.css}`; CI publishes to Pages via
`actions/upload-pages-artifact` + `actions/deploy-pages`.
Source: TB commit `58b48aa9d`, whole-file cp + surgical edits.

**Survival:** 836 lines total (TB had ~860). 99→79 in index.html,
552→548 in devhub.js, 209→209 in style.css.

**Removes (1):** release-manager rotation section + `main_release_rotation()` +
`get_release_manager()`. `get_week()` retained as a free primitive.

**Surgical changes:** 15 URL swaps (devhubdb / tiger_web), 2 brand
swaps (title + nav heading), 1 Coverage-link target swap (per
locked option-1 decision).

**Preserved verbatim even when inert:** VOPR branches, `is_release()`,
`outlier_score()` red-highlighting, untriaged-issues badge, full
SVG template block.

**Two user-actions activate the unfinished pieces:**
1. Register Nyrkiö account, set `NYRKIO_TOKEN` in tiger_web repo
   secrets → Nyrkiö link + change-point detection both activate.
2. Enable Pages on `hireAlanAyala/tiger_web` with source "GitHub
   Actions"; subsequent PR adds `actions/upload-pages-artifact` +
   `actions/deploy-pages` to devhub job → Coverage link activates.

Effort: 3 hours. Dependencies: G.0 complete + ≥1 week of data in
devhubdb.

### Prerequisite decisions — LOCKED (2026-04-24, RESOLVED 2026-04-27)

**Coverage link: ✅ resolved via TB-aligned single-origin restructure.**
Dashboard moved from devhubdb to `tiger_web/devhub/`; CI publishes
both `devhub/` and `coverage/` to tiger_web's Pages. Coverage link
is now relative `./coverage/index.html` — same origin as dashboard,
matches TB's exact pattern.

**Nyrkiö link: option (c) — `<a>` points at the future public URL;
404s until account registration, auto-activates when registration
lands.**

`<a href="https://nyrkio.com/public/https%3A%2F%2Fgithub.com%2FhireAlanAyala%2Ftiger_web/main/devhub">`
— same URL shape TB uses. No dashboard code churn when registration
completes. Tracked follow-up below.

**Outstanding user-action:**
- Register Nyrkiö account + set `NYRKIO_TOKEN` → Nyrkiö link
  activates + change-point detection turns on.

**Discipline:** whole-file `cp` of TB's three dashboard files,
then surgical remove + change. Minimum edits for **honesty**
(renders our data, attributed to us). Inert TB code stays —
keep what doesn't hurt us.

- [x] `cp /home/walker/Documents/personal/tigerbeetle/src/devhub/devhub.js`
  → `tiger-web-devhubdb/devhub.js`.
- [x] `cp .../index.html` → `tiger-web-devhubdb/index.html`.
- [x] `cp .../style.css` → `tiger-web-devhubdb/style.css`.
- [x] **Preserve the `devhub.js` header comment verbatim** (lines
  1-8 — "no TypeScript, no build step, snake_case, `deno fmt`").
  Documents why the file looks un-TB-like; prevents future
  "rewrite in TS" impulse.

### One-time repo setup

- [x] Create a `triaged` label on `hireAlanAyala/tiger_web` and
  apply it to every reviewed open issue. New issues get the
  label when triaged. Without this, the "Issue triage N" badge
  counts every open issue as untriaged.

### Remove (1 item)

- [x] **Release manager section + rotation logic.** Solo project;
  TB's hardcoded roster (`batiati`, `cb22`, `chaitanyabhandari`,
  `fabioarnold`, `lewisdaly`, `matklad`, `sentientwaffle`,
  `toziegler`, `GeorgKreuzmayr`) renders other people's names as
  "this week's release manager." Delete:
  - HTML `<section id="release">` block (index.html:24-40)
  - JS `main_release_rotation()` + `get_release_manager()`
    (devhub.js:24-53)
  - Top-level invocation of `main_release_rotation()`
  - **Keep `get_week()` helper** even though its caller is gone.
    Deleting it invites a future rewrite-from-memory; cost is 6
    lines of dead code.

### Change — URL/brand swaps

`index.html`:

- [x] `<title>TigerBeetle DevHub</title>` → `Tiger Web DevHub`.
- [x] Nav branding (line 17-19): replace `<svg id="logo"><use
  href="#svg-logo">` with plain `<h1 class="brand">Tiger Web
  DevHub</h1>`.
- [x] **SVG template block (`<svg id="svg-logo">` lines 88-95):
  leave verbatim**, do not hand-edit `<path>` contents. The block
  is referenced by `#svg-logo`; leaving it intact costs nothing
  and avoids hand-SVG drift. The visible nav `<svg id="logo">`
  swap above is what the user sees.
- [x] "My code review" link →
  `github.com/hireAlanAyala/tiger_web/pulls/assigned/@me`.
- [x] "Issue triage" link →
  `github.com/hireAlanAyala/tiger_web/issues?q=is%3Aissue+is%3Aopen+-label%3Atriaged`.
- [x] **Keep the Nyrkiö link** in Metrics header — point it at our
  Nyrkiö URL (`nyrkio.com/public/https%3A%2F%2Fgithub.com%2FhireAlanAyala%2Ftiger_web/main/devhub`).
  H.1 preserves the uploader; link lets the dashboard surface
  Nyrkiö's change-point view.
- [x] "Raw data" link (fuzz + metrics sections):
  `tigerbeetle/devhubdb` → `hireAlanAyala/tiger-web-devhubdb`.

`devhub.js` (each is a literal string replacement):

- [x] Metrics data URL (line 218).
- [x] Fuzz data URL (line 57).
- [x] Logs base URL (line 61).
- [x] Issues API URL (line 59):
  `api.github.com/repos/tigerbeetle/tigerbeetle/issues` →
  `api.github.com/repos/hireAlanAyala/tiger_web/issues`.
- [x] Commit link URL (lines 171, 378).
- [x] PR prefix (line 241).
- [x] Branch-identity check (line 232).
- [x] Release-tree URL check (line 237). Inert until we adopt the
  `release/vN.N` tag convention; when we ship our first release,
  push the tag and `is_release()` starts annotating.

### Keep explicitly (even if inert)

Named so no future "tidy up" pass deletes them:

- VOPR branches (`record.fuzzer === "vopr"`) — zero cost; free
  when we add a VOPR analog (see `tb-alignment.md` item 8).
- `is_release()` — works when release tagging lands.
- `outlier_score()` red-highlighting logic — single most valuable
  dashboard feature after raw charting. Keep it named.
- `mean()`, `get_week()`, `format_bytes`, `format_count`,
  `format_date_*`, `format_duration`, `format_suffix`.
- Fuzz runs table — CFO seeds in `fuzzing/data.json` (184456
  historical) use TB's schema.
- Entire `style.css` — inherit TB's visual language; restyle
  later if desired.

### File header in devhub.js must document

- Port source: TB `src/devhub/{devhub.js,index.html,style.css}`
  with commit SHA at cp time.
- Discipline: whole-file `cp` + surgical remove/change. Every
  change listed above; every line not listed is TB's code
  unchanged.
- SVG template block left verbatim (not hand-edited).
- `get_week` intentionally retained as dead code.

### Verification

- [x] Load `https://hirealanayala.github.io/tiger-web-devhubdb/`
  in a browser. Confirm:
  - `<title>` reads "Tiger Web DevHub".
  - Metrics section renders all charts (23 metrics post-H.2:
    original 18 + 5 added).
  - Nyrkiö link opens our public Nyrkiö page.
  - Fuzz runs table populated (CFO seeds).
  - Commit-link on a data point opens our tiger_web commit.
  - Coverage link loads the G.0 artifact (no 404).
  - `outlier_score` red-highlighting visible on any metric with
    variance.
  - No "TigerBeetle" text visible anywhere the user can read.
- [x] Open browser devtools; confirm no JS errors (release-section
  HTML deletion must match JS invocation deletion — otherwise
  `querySelector` returns null and throws).

---

## Tracked follow-ups

Not shared exposures with TB. Temporary states with known end
conditions.

- [ ] **Open-loop load generator mode.** Blocking prerequisite for
  any public performance claim off the dashboard (README,
  marketing, external comparison). The failure mode is invisible
  by design; remediation is time-boxed to "before first public
  claim," not signal-driven. H.4's single-threaded client loop is
  a prerequisite shape.
- [ ] **CI observability pipeline (single bundled follow-up).**
  Three related items land together; separating them produced a
  stale dependency chain in an earlier plan draft, so they're
  consolidated here.
  1. Split devhub onto its own workflow triggered by
     `workflow_run: workflows: [CI], types: [completed]`. Unblocks
     a meaningful `ci_pipeline_duration_s` (the completed-run
     record carries `updatedAt = end-of-pipeline`).
  2. Restore `ci_pipeline_duration_s` metric to `scripts/devhub.zig`
     with TB's exact shape (TB:311-332). H.2 dropped it on TB-lens
     review — our `push` trigger ran devhub inside the workflow it
     would measure, making the metric misleading.
  3. Subscribe to GitHub Actions runner-image deprecation
     announcements; annotate the dashboard within 24h of any switch
     so the resulting discontinuity is explicit rather than misread
     as a regression. Depends on (2) for the underlying trend line.
  Estimated effort: ~1.5h total.
- [x] **Register Nyrkiö account + set `NYRKIO_TOKEN`.** Done
  2026-04-27 (token registered in `hireAlanAyala/tiger_web` Actions
  secrets). Next main-merge CI run uploads to Nyrkiö; dashboard
  link starts resolving to live change-point view. Flips H.1's
  token-optional upload from "no-op" to "active change-point
  detection." Zero code change.
- [x] **Enable GitHub Pages on `hireAlanAyala/tiger_web`** —
  done 2026-04-27 via `gh api ... pages -f build_type=workflow`
  (after GitHub Pro upgrade unblocked private-repo Pages). CI
  workflow now publishes `devhub/` + `coverage/` to
  `https://hirealanayala.github.io/tiger_web/` on every main merge.
- [x] **Tiger-unit-test aggregator exclusions to rescue.** ✅ DONE
  2026-04-27. Three categories all addressed:
  - **`framework/stdx/*`** — added a separate `tiger-stdx-test`
    target in `build.zig` rooted at `framework/stdx/stdx.zig`,
    matching TB's pattern (`tigerbeetle/build.zig:895-903`). Wired
    into `unit-test-build` (kcov-attachable) and `unit-test` step.
    `scripts/devhub.zig:devhub_coverage` adds it to the kcov pass
    with explicit ZIG_EXE-presence check (one stdx test reads it).
    Brings stdx's 67 tests into the unit-test pipeline + coverage
    report.
  - **`framework/bench.zig` + `framework/app.zig`** — wired
    `test_options` build-options module on `unit_test_binary` (TB's
    pattern, `tigerbeetle/build.zig:885-893`). Re-added both files;
    framework/app.zig's stale TestApp config needed
    `.MessageResponse = TestResponse` to match current AppType field
    requirements. Aggregator: 365 → 370 tests.
  - **`handler_test.zig`** — deleted (commit `ec16398`); the file
    tested an outdated 3-arg `route()` API plus an `EffectList`
    render shape neither of which exist in the current
    architecture. Integration is covered by `sim.zig` +
    `state_machine_test.zig`.

  TB-alignment intent of "unit-test binary contains every test
  block" now fulfilled. Catching these required porting TB's quine
  self-test (audit finding 2026-04-24).
- [ ] **`pending_index_benchmark.zig` and `ring_buffer_benchmark.zig`
  at API boundary.** Add if container-choice stabilizes and we
  want regression detection. Until then, pipeline-tier bench
  covers them implicitly.
- [ ] **Per-endpoint load shapes.** Default `--ops` mix will need
  tuning as domain grows.
- [ ] **tidy.zig codebase cleanup → CI-gating.** `tidy.zig`
  ported 1:1 from TigerBeetle (`src/tidy.zig` at commit `8977868dd`).
  Shipped as a standalone `zig build tidy` target with all surgical
  edits documented inline (vendor/ skip, sqlite blob exception,
  symlink-mode allowance, extension allowlist). 13/14 internal
  tests pass; the main `test "tidy"` fails on 1001 accumulated
  violations across ~100 files:
  - 661 long lines (>100 cols)
  - 156 defer-without-blank-line
  -  45 `@memcpy(` banned (use stdx.copy_disjoint)
  -  40+ dead-code imports (`std`, `assert`, `log`, `stdx`, etc.)
  -   6 `Self = @This()` banned (use proper type name)
  -   3 `mem.copyForwards` banned
  -  many "file never imported" / "imported file untracked"
  Until cleanup converges, tidy.zig is NOT in the
  `tiger_unit_tests.zig` aggregator (CI stays green).
  `scripts/style_check.zig` remains the active discipline gate.
  Cleanup path:
    1. Run `zig build tidy` to see current violations.
    2. Fix one category at a time (long lines first — mostly
       mechanical reflows).
    3. Once `zig build tidy` returns green, add
       `_ = @import("tidy.zig");` to `tiger_unit_tests.zig`
       (one-line edit), making tidy CI-gating.
    4. Delete `scripts/style_check.zig` (tidy subsumes its
       checks via TB's AST-based + comprehensive shape).
  This is the deepest TB-1:1 alignment work remaining.
- [ ] **Sidecar-mode SLA bench.** `tiger-web benchmark` exercises
  the HTTP → native → SQLite path only; the 1-RT SHM sidecar
  dispatch isn't covered at SLA tier. Two shapes: `--sidecar=<cmd>`
  flag, or a second bench invocation in
  `scripts/devhub.zig:run_sla_benchmark` emitting
  `benchmark_sidecar_*` metrics. Not a G blocker; add when
  sidecar-path performance becomes a dashboard story.

---

## Audit log (2026-04-23)

TB-lens audit flagged six under-justified divergences, all folded
into Phase H above:

| # | Divergence | Retrofit |
|---|---|---|
| 1 | `upload_nyrkio` dropped | H.1 (token-optional preserve) |
| 2 | `ci_pipeline_duration_ms` dropped | H.2 |
| 3 | `executable_size_bytes` / `build_time_ms` / `build_time_debug_ms` dropped | H.2 |
| 4 | log-line count metric dropped | H.2 |
| 5 | Warmup ships with measured 0% effect | H.3 |
| 6 | Thread-per-connection client loop | H.4 (promote from follow-up to blocker) |

Silent divergences (H.5): `--dry-run` bucket tag, verify
`git_env_setup` + `open_section` preservation, SVG template
verbatim in G.1, `get_week` keep-list, Nyrkiö link keep.

**Context that shaped the audit bias:** omitting features on "don't
need today" rationale has burned this project repeatedly — wanted
within days, not months. Copying works. 1:1 with TB is mission
critical. The null hypothesis on every TB divergence is "we'll
regret it within two weeks." Future audits apply the same lens.
