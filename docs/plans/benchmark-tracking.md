# Benchmark Tracking — Regression Detection Across Commits

Track throughput, latency, and resource usage on every main branch
commit. Detect regressions visually via a dashboard, not via hard CI
thresholds. Matches TigerBeetle's devhub pattern.

## Why no hard CI thresholds

TigerBeetle deliberately does NOT fail CI on benchmark regressions.
Benchmark numbers are noisy — kernel scheduling, disk cache state,
background processes all affect results. A hard threshold either
fires false positives (blocks valid commits) or is set so high it
misses real regressions.

Instead: collect metrics on every commit, store them, visualize trends,
highlight outliers. A human reviews the dashboard and decides whether
a regression is real. The data is the evidence. The human is the judge.

## Architecture (TigerBeetle's devhub pattern)

```
commit → CI runs benchmarks → metrics appended to devhubdb repo
                                       ↓
                              dashboard reads data.json
                                       ↓
                              charts with outlier highlighting
```

### Components

**1. Metrics collection (scripts/devhub.zig)**

A CI script that:
- Builds the server and load test in release mode
- Runs `zig build bench` (state machine, per-operation μs/op)
- Runs `zig build load` (full stack, req/s + latency percentiles)
- Captures: throughput, p50/p99/p100, RSS, db size, build time,
  executable size
- Outputs a JSON metric batch with git commit SHA and timestamp

**2. Metrics storage (devhubdb GitHub repo)**

A separate repository (`tiger-web-devhubdb` or similar) containing
one file: `devhub/data.json`. Each CI run appends one line (newline-
delimited JSON):

```json
{"timestamp":1711500000,"attributes":{"git_commit":"abc123","branch":"main"},"metrics":[{"name":"throughput","value":55000,"unit":"req/s"},{"name":"p99","value":2,"unit":"ms"}]}
```

Git-based append-only storage:
- Auditable — every data point has a commit
- No external database to operate
- Concurrent writes handled by git push retry loop (clone, append,
  push — retry on conflict, up to 32 attempts)

**3. Dashboard (static HTML + JS)**

A GitHub Pages site that:
- Fetches `data.json` from the devhubdb repo raw URL
- Renders charts with historical trends (ApexCharts or similar)
- Highlights top 3 metrics with highest week-on-week change in red
- Each data point links to the GitHub commit that produced it

Outlier detection (client-side):
```
score = abs(mean_this_week - mean_last_week) / mean_last_week
```
Pure visualization — no CI integration, no blocking.

**4. CI integration**

On main branch merge (not PRs):
```yaml
- name: devhub
  run: zig build scripts -- devhub --sha=${{ github.sha }}
  env:
    DEVHUBDB_PAT: ${{ secrets.DEVHUBDB_PAT }}
```

On PRs (dry-run, no upload):
```yaml
- name: devhub-dry-run
  run: zig build scripts -- devhub --dry-run
```

Dry-run computes all metrics but doesn't push to devhubdb. This
ensures the benchmark code compiles and runs, without polluting the
data with PR branch measurements.

## Metrics to collect

### From `zig build bench` (state machine)

| Metric | Unit | What it measures |
|---|---|---|
| get_product μs/op | μs | Read latency, pure logic |
| list_products μs/op | μs | Multi-row query cost |
| update_product μs/op | μs | Write latency, pure logic |

### From `zig build load` (full stack)

| Metric | Unit | What it measures |
|---|---|---|
| throughput | req/s | Server capacity ceiling |
| p50 | ms | Typical latency |
| p99 | ms | Tail latency |
| p100 | ms | Worst case |
| reconnections | count | Connection stability |
| RSS | bytes | Memory usage |
| db size | bytes | Storage footprint |

### Build metrics

| Metric | Unit | What it measures |
|---|---|---|
| build time (debug) | ms | Developer iteration speed |
| build time (release) | ms | CI/deploy speed |
| executable size | bytes | Binary bloat detection |

## Implementation checklist

### Phase 1: Metrics collection

- [ ] Add `devhub` subcommand to `scripts.zig`
- [ ] `scripts/devhub.zig` — run bench + load, collect metrics,
  format as JSON metric batch
- [ ] `--sha` flag for git commit attribution
- [ ] `--dry-run` flag for PR validation without upload
- [ ] Machine-readable output from `zig build bench` (currently
  prints to stderr, needs structured output)
- [ ] Machine-readable output from `zig build load` (currently
  prints human-readable text, needs JSON mode)

### Phase 2: Storage

- [ ] Create `tiger-web-devhubdb` GitHub repository
- [ ] Upload logic in `scripts/devhub.zig` — clone, append, push
  with retry loop for concurrent writes
- [ ] GitHub PAT with write access to devhubdb repo
- [ ] Store PAT as GitHub secret in tiger-web repo

### Phase 3: Dashboard

- [ ] Static HTML + JS page in `devhub/` directory
- [ ] Fetch data.json, render charts
- [ ] Week-on-week outlier highlighting
- [ ] Commit links for each data point
- [ ] Deploy via GitHub Pages on tiger-web repo

### Phase 4: CI integration

- [ ] Add `devhub` mode to `zig build ci`
- [ ] Run on main branch merges only
- [ ] Dry-run on PRs
- [ ] Secrets configuration (DEVHUBDB_PAT)

## Before implementation

- [ ] Review this plan through TigerBeetle's lens. Ask for critiques
  on the metric selection, storage format, outlier detection algorithm,
  and dashboard design. Refine before building.

## What framework users get

This is rare. Most web frameworks ship without any performance tooling:

- **Rails, Django, Laravel** — no built-in benchmarking. Developers
  use third-party tools (wrk, ab, k6) and have no framework-aware
  profiling. Performance is an afterthought.
- **Express, Fastify** — no benchmarking. Community benchmarks exist
  but aren't part of the framework.
- **actix-web, drogon** — community benchmarks (TechEmpower) but no
  built-in load testing or regression tracking.
- **TigerBeetle** — full devhub with benchmark tracking, but it's a
  database, not a web framework.

Tiger-web ships with:
- `zig build load` — full-stack throughput/latency measurement
- `zig build bench` — per-operation microsecond cost
- `zig build scripts -- perf` — CPU profiling with perf
- Benchmark tracking dashboard (this plan)

No other web framework provides all four out of the box. A framework
user can measure their app's performance, find bottlenecks, and track
regressions without installing any external tools.

This is a competitive advantage — not because the tools are complex,
but because they're integrated. The load test knows the server's
operations. The perf script builds release, starts the server, and
produces a report. The dashboard tracks the same metrics across
commits. The user doesn't assemble a toolchain — they use one.

## What this does NOT do

- Does not fail CI on regression (noise > signal for hard thresholds)
- Does not post PR comments (metrics without context mislead)
- Does not automatically rollback commits (human judgment required)
- Does not compare against baseline files (baselines drift with
  hardware changes)

The dashboard is the tool. The developer is the decision-maker.
