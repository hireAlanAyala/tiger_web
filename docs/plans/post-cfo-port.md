# Post-CFO Port — Remaining Work

## Done

- CFO ported from TigerBeetle (Phases 1-7)
- CFO running locally (4 cores, seeds pushing to devhubdb)
- CFO found 8 real bugs on first run (fuzz dependency weights)
- Integration test suite: 72 tests, all 24 handlers, full sidecar pipeline
- `zig build ci` build step: test, fuzz, clients, default modes — all pass
- GitHub Actions CI: passes on push/PR
- Unified annotation routing: `// match`, `// query`, generated routes table
- Dispatch resilience: try/catch on all handler phases
- Framework TestRunner: `generated/testing.ts`
- Dispatch bugs found and fixed: prefetch mode, method enum, route matching
- Cross-language contracts: route_match_vectors.json, method_vectors.json
- devhubdb repo live: `hireAlanAyala/tiger-web-devhubdb`
- CFO gracefully skips missing release branch

## Known CI gaps

**manifest.json has two writers:**
Zig scan and TypeScript build both write to `generated/manifest.json`.
Only `routes.generated.zig` is freshness-checked. Fix: per-target
manifests or treat manifest as intermediate build artifact.

**dispatch.generated.ts not freshness-checked:**
Format regressions caught by adapter test (31 assertions), not by
`git diff`. Add freshness check after TS build in clients job.

**Orphan processes on CI kill:**
Integration tests spawn child processes. `finally` cleans up on normal
exit. SIGKILL skips cleanup. Fix: process groups or signal-trapping wrapper.

**Vendored zig audit:**
All invocations must use `./zig/zig`, never bare `zig`. Audit CLAUDE.md
commands and any scripts.

## Deferred features

**`ci -- smoke` mode:** `zig fmt --check`, tidy checks, doc building.

**devhub viewer:** Static site to visualize CFO seed data, benchmarks.
Copy TB's `src/devhub/` (3 files: index.html, style.css, devhub.js).
Two sections: fuzz runs table (seed records with repro commands) and
metrics charts (benchmark regressions over time via ApexCharts).

**Docker image:** Framework + runtime base image. Port TB's docker
digest verification. Defer until framework is stable.

**Release/changelog:** Not needed until we ship artifacts. Release
branch will be created at first release cut — CFO skips gracefully
until then.

**`--example=X` filter:** Add when we have 2+ example projects
(TB's flags.zig requires enums with >= 2 variants).

## Plans (not yet implemented)

- `docs/plans/framework-fuzzer.md` — `tiger-web fuzz`: zero-config
  fuzzing for any handler app. Annotation-driven request generation.
  Three phases: crash detection, entity tracking, auditor.

- `docs/plans/cfo-as-service.md` — hosted continuous fuzzing for
  framework users. 1 vCPU per customer, ~2,880 seeds/day, $5/mo.

- `docs/plans/devhub-setup.md` — `tiger-web setup --github`: automated
  devhubdb repo creation and PAT configuration.

- `docs/plans/framework-assert.md` — implemented (dispatch resilience).
  Could move to decisions/.

## Decisions (implemented)

- `docs/decisions/annotation-routing.md` — unified `// match` + `// query`
- `docs/decisions/import-strategy.md` — stdx as build module, no lib.zig
