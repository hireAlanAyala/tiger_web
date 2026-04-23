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

- [ ] Delete `--warmup-seconds` flag, warmup loop, and warmup
  time-window logic from `benchmark_load.zig`.
- [ ] Update `benchmark_load.zig` header to remove the
  "principled flaw fix: warmup" claim.
- [ ] Update `docs/internal/decision-benchmark-tracking.md` Phase
  D.5 section with: "Warmup shipped, measured 0% effect, removed
  in H.3. Lesson: D.5 measurement should have gated D shipping,
  not followed it."
- [ ] Alternative (if the team disagrees with deletion): gate
  behind `--warmup-seconds=0` default AND add a comment in
  `benchmark_load.zig` above the warmup block: `// Warmup is
  off-by-default; D.5 measured 0% p50 impact. Kept for future
  cold-cache scenarios where first-request cost matters.` But
  default must be 0, not 5.

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
Net result: one IO abstraction across the project, and the benchmark
becomes simulation-testable the day we want that (drop in `SimIO`
with no harness change).

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

### H.2 — Add five missing metrics [ADDITIVE — AFTER G.0.a] ✅ DONE

Status (2026-04-23): added all five metrics to `scripts/devhub.zig`.
Dashboard now carries **23 metrics** across all three tiers + build
+ CI. Ordering constraint honored — G.0.a landed first, so the
first real `build_time_*` datapoint sits on a stable build graph.

Ported from TB (`src/scripts/devhub.zig`, bucket tags inline):

- `executable_size_bytes` / `build_time_ms` / `build_time_debug_ms` —
  TB:107-127 verbatim pattern. Debug build timer → cache-clear →
  release build timer + `statFile("zig-out/bin/tiger-web").size`.
- `ci_pipeline_duration_s` — TB:311-332. Event name changed
  (`merge_group` → `push`; our trigger). Falls back to 0 when run
  locally (no `gh` auth).
- `bench_log_lines` — `replica log lines` analog (TB:193). Captured
  from SLA benchmark's stderr via `exec_stdout_stderr`;
  `std.mem.count(u8, stderr, "\n")`.

Also removed the redundant second release build at line 138 — the
new build-time measurement already produced `zig-out/bin/tiger-web`
in release mode, so the SLA bench reuses it.

File header updated: the five metrics moved from "Deletions" to
"Transplanted" with TB line citations.

Verification (local dry-run of `zig build scripts -- devhub
--sha=$HEAD --dry-run`):
- `executable_size_bytes = 10591752` (10.6 MB release).
- `build_time_ms = 48647` (cold-cache full release build).
- `build_time_debug_ms = 68` (warm-cache incremental; CI will see
  cold-cache full debug time).
- `ci_pipeline_duration_s = 0` (graceful local fallback).
- `bench_log_lines = 2` (info + warn from current benchmark).
- All 23 metrics present in the MetricBatch JSON payload.

### H.1 — Preserve `upload_nyrkio` token-optional [ADDITIVE]

TB double-publishes every `MetricBatch` to Nyrkiö
(`nyrkio.com/api/v0/result/devhub`) — a hosted change-point
detection service. Raw dashboard data is human-eyeballed; Nyrkiö
flags the exact commit where a metric's distribution shifts. We
dropped the uploader in E ("single-target"). First p99 drift we
fail to notice by eye, we'll regret it.

- [ ] `cp` TB's `upload_nyrkio` function verbatim from
  `/home/walker/Documents/personal/tigerbeetle/src/scripts/devhub.zig:454-466`
  into our `scripts/devhub.zig`.
- [ ] `cp` TB's call site from `devhub.zig:370-372` (invoked per
  run; errors logged but not fatal).
- [ ] Make token-optional: wrap `shell.env_get("NYRKIO_TOKEN")`
  with a graceful skip when missing (TB's own pattern tolerates
  this implicitly via the `catch |err|` at line 370). Log one
  line at info level: `"NYRKIO_TOKEN not set; skipping Nyrkiö
  upload"`. No error, no CI failure.
- [ ] Update the file header's "Deletions" list: move Nyrkiö from
  "dropped" to "transplanted verbatim, token-optional".
- [ ] Tracked follow-up (separate from this phase): register a
  Nyrkiö account at
  `https://nyrkio.com/public/https%3A%2F%2Fgithub.com%2FhireAlanAyala%2Ftiger_web/main/devhub`,
  set `NYRKIO_TOKEN` in CI. When we want automated drift
  detection, flip the secret on — no code change needed.

### H.5 — Silent divergence cleanup [ADDITIVE]

Small items, each is one-line or one-comment.

- [ ] `scripts/devhub.zig` — bucket-tag the `--dry-run` CLI field
  as a tiger-web addition, not TB's pattern. Add a comment above
  `CLIArgs`: `// dry_run is tiger-web-specific (principled — PR
  path needs a no-push mode). TB's CLIArgs carries only sha +
  skip_kcov.`
- [ ] Confirm `shell.git_env_setup(.{ .use_hostname = false })` is
  preserved in `upload_run` (audit noted as risk; grep confirms
  line 325 has it — verify no future edit removes it).
- [ ] Confirm `shell.open_section("metrics")` is preserved (line
  106 has it).
- [ ] Audit memory note: add a line to
  `feedback_revisit_decisions_when_justifications_expire.md`:
  "E's header 'we don't need X' deletions re-audited 2026-04-23;
  five metrics + `upload_nyrkio` retrofitted. Generalizable: any
  deletion rationale of the shape 'we don't ship a binary / don't
  publish / don't need yet' requires a named failure mode within
  days-to-weeks, not months."

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

### G.0.b — kcov wiring

**Discipline:** `cp` TB's `devhub_coverage()` function from
`/home/walker/Documents/personal/tigerbeetle/src/scripts/devhub.zig:58-95`
into our `scripts/devhub.zig`, then trim with bucket tags. Do
not re-derive from memory — the binary list, events-max, seed
(`92`), symlink-cleanup are TB decisions we may not fully
understand, and cp-first preserves them.

- [ ] `cp` TB's `devhub_coverage` (TB:58-95) verbatim.
- [ ] Surgical trims (each inline bucket-tagged):
  - `./zig-out/bin/test-unit` → `./zig-out/bin/tiger-unit-test`
    (principled — our binary name).
  - Drop TB's LSM fuzz invocations (`lsm_tree`, `lsm_forest`).
    Principled — no LSM subsystem.
  - Drop TB's VOPR invocation. Principled — no VOPR.
  - **Replace with our full fuzzer set**, seed `92`, events-max
    100_000 each:
    ```
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 state_machine 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 replay 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 message_bus 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 row_format 92
    {kcov} ./zig-out/bin/tiger-fuzz -- --events-max=100000 worker_dispatch 92
    ```
    Rationale for all five: cross-language boundaries
    (`row_format`, `message_bus`) > concurrent paths
    (`worker_dispatch`) > durable-format boundaries (`replay`) >
    pipeline logic (`state_machine`). A subset gives false
    confidence.
  - Keep: `kcov` invocation shape, `--include-path=./src`, output
    directory, seed `92`, symlink cleanup.
- [ ] `cp` TB's `--skip-kcov` CLI flag shape (TB:43-46). Default
  `false` on main.
- [ ] Add `sudo apt-get install -y kcov` to the devhub CI step
  above `zig/download.sh`.
- [ ] Change devhub job's run line from
  `./zig/zig build scripts -- devhub --sha="$SHA"` to
  `sudo -E ./zig/zig build scripts -- devhub --sha="$SHA"` (and
  dry-run variant). Belt-and-suspenders against runner-image
  credential-helper regressions. Matches TB.
- [ ] Upload `coverage/` directory to Pages alongside
  `devhub/data.json` via `actions/upload-pages-artifact` +
  `actions/deploy-pages` (TB pattern; (a)-option of git-diffing
  HTML bloats history).
- [ ] Verify: after next main merge,
  `curl -sI https://hirealanayala.github.io/tiger-web-devhubdb/coverage/index.html`
  returns 200.

---

## Phase G.1 — dashboard

Effort: 3 hours. Dependencies: G.0 complete + ≥1 week of data in
devhubdb.

**Discipline:** whole-file `cp` of TB's three dashboard files,
then surgical remove + change. Minimum edits for **honesty**
(renders our data, attributed to us). Inert TB code stays —
keep what doesn't hurt us.

- [ ] `cp /home/walker/Documents/personal/tigerbeetle/src/devhub/devhub.js`
  → `tiger-web-devhubdb/devhub.js`.
- [ ] `cp .../index.html` → `tiger-web-devhubdb/index.html`.
- [ ] `cp .../style.css` → `tiger-web-devhubdb/style.css`.
- [ ] **Preserve the `devhub.js` header comment verbatim** (lines
  1-8 — "no TypeScript, no build step, snake_case, `deno fmt`").
  Documents why the file looks un-TB-like; prevents future
  "rewrite in TS" impulse.

### One-time repo setup

- [ ] Create a `triaged` label on `hireAlanAyala/tiger_web` and
  apply it to every reviewed open issue. New issues get the
  label when triaged. Without this, the "Issue triage N" badge
  counts every open issue as untriaged.

### Remove (1 item)

- [ ] **Release manager section + rotation logic.** Solo project;
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

- [ ] `<title>TigerBeetle DevHub</title>` → `Tiger Web DevHub`.
- [ ] Nav branding (line 17-19): replace `<svg id="logo"><use
  href="#svg-logo">` with plain `<h1 class="brand">Tiger Web
  DevHub</h1>`.
- [ ] **SVG template block (`<svg id="svg-logo">` lines 88-95):
  leave verbatim**, do not hand-edit `<path>` contents. The block
  is referenced by `#svg-logo`; leaving it intact costs nothing
  and avoids hand-SVG drift. The visible nav `<svg id="logo">`
  swap above is what the user sees.
- [ ] "My code review" link →
  `github.com/hireAlanAyala/tiger_web/pulls/assigned/@me`.
- [ ] "Issue triage" link →
  `github.com/hireAlanAyala/tiger_web/issues?q=is%3Aissue+is%3Aopen+-label%3Atriaged`.
- [ ] **Keep the Nyrkiö link** in Metrics header — point it at our
  Nyrkiö URL (`nyrkio.com/public/https%3A%2F%2Fgithub.com%2FhireAlanAyala%2Ftiger_web/main/devhub`).
  H.1 preserves the uploader; link lets the dashboard surface
  Nyrkiö's change-point view.
- [ ] "Raw data" link (fuzz + metrics sections):
  `tigerbeetle/devhubdb` → `hireAlanAyala/tiger-web-devhubdb`.

`devhub.js` (each is a literal string replacement):

- [ ] Metrics data URL (line 218).
- [ ] Fuzz data URL (line 57).
- [ ] Logs base URL (line 61).
- [ ] Issues API URL (line 59):
  `api.github.com/repos/tigerbeetle/tigerbeetle/issues` →
  `api.github.com/repos/hireAlanAyala/tiger_web/issues`.
- [ ] Commit link URL (lines 171, 378).
- [ ] PR prefix (line 241).
- [ ] Branch-identity check (line 232).
- [ ] Release-tree URL check (line 237). Inert until we adopt the
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

- [ ] Load `https://hirealanayala.github.io/tiger-web-devhubdb/`
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
- [ ] Open browser devtools; confirm no JS errors (release-section
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
- [ ] **Runner-image change detection.** When GitHub deprecates a
  runner class, annotate the dashboard with the switch date so the
  discontinuity is visible rather than misread as regression.
  Subscribe to GitHub Actions deprecation announcements; annotate
  within 24h. Depends on H.2's `ci_pipeline_duration_ms` metric.
- [ ] **Register Nyrkiö account + set `NYRKIO_TOKEN`.** Flips H.1's
  token-optional upload from "no-op" to "active change-point
  detection." Zero code change.
- [ ] **`pending_index_benchmark.zig` and `ring_buffer_benchmark.zig`
  at API boundary.** Add if container-choice stabilizes and we
  want regression detection. Until then, pipeline-tier bench
  covers them implicitly.
- [ ] **Per-endpoint load shapes.** Default `--ops` mix will need
  tuning as domain grows.
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
