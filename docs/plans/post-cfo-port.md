# Post-CFO Port — Features to Implement

After the CFO port plan (Phases 1-8) completes, these are the capabilities
we deleted or deferred that need to come back.

## Current priority: integration test suite + ci build step

**Blocked on:** `examples/ecommerce-ts/test.ts` — the integration test suite
that exercises all 24 handlers through the full sidecar pipeline. This is the
foundation that makes the ci build step meaningful.

**Sequence:**
1. Write `examples/ecommerce-ts/test.ts` (full handler integration tests)
2. Add `"test": "npx tsx test.ts"` to example `package.json`
3. Implement `zig build ci` step in build.zig (matching TB's pattern)
4. Add GitHub Actions workflow calling `./zig/zig build ci -- test`

**Already done:**
- `scripts/ci.zig` ported from TB (two-level testing: adapter + integration)
- `dispatch.generated.ts` bug fixed (`'one'` → `'query'` prefetch mode)
- Sidecar end-to-end pipeline verified working (server + sidecar + HTTP)
- `build_ci_step` and `build_ci_script` helpers available from TB port

## Scripts subcommands

We deleted 5 subcommands from TB's scripts.zig. `ci` has been ported.
The rest need to come back when needed.

### `ci` — immediately after plan

TB's CI is a **build.zig step** (`zig build ci -- test`), not a scripts
subcommand. The build step invokes other build steps as subprocesses via
`build_ci_step` and `build_ci_script` helpers. `scripts/ci.zig` only
handles client library testing — the orchestration lives in build.zig.

We should match this pattern: `zig build ci -- <mode>`.

#### CI modes (matching TB's pattern)

**`zig build ci -- test` (default):**
- `zig build scan` — regenerate routes.generated.zig + manifest.json
- `git diff --exit-code generated/` — freshness check (committed files must match)
- `zig build test` — sim tests (27 scenarios + PRNG fuzz)
- `zig build unit-test` — unit tests
- `zig build fuzz -- smoke` — all 4 fuzzers, small event counts

**`zig build ci -- fuzz`:**
- `zig build fuzz -- smoke`
- `zig build fuzz -- state_machine <commit-sha>` — per-commit seed
  (TB runs VOPR with commit SHA; we run state_machine with commit SHA.
  Same idea: every commit gets one deterministic fuzz pass. The seed is
  the commit hash truncated to u64, matching TB's parse_seed().)

**`zig build ci -- smoke` (future):**
- Formatting checks (zig fmt --check)
- Linting / tidy checks
- Doc building

#### Two levels of sidecar testing

We are higher in the stack than TB. TB's client libraries are thin
protocol wrappers — they serialize requests and deserialize responses.
If the protocol doesn't change, the client doesn't break. Testing the
adapter boundary is sufficient.

Our sidecar runs **user-space business logic**. TypeScript handlers call
framework APIs (storage queries, auth, WAL recording), receive binary
row data, make decisions, and render HTML. A framework bug in
`storage.zig`'s `query_raw`, a binary encoding change in `protocol.zig`,
or a subtle change in how `WriteView` records WAL entries could cause
handlers to return wrong data, silently corrupt state, or crash the
sidecar. The adapter test only checks the binary protocol round-trips
correctly — it doesn't exercise handler logic.

This means we need two levels of testing, both on every commit:

**Level 1: Adapter tests (protocol boundary)**
- `zig build test-adapter` — runs `npx tsx adapters/typescript_test.ts`
- Verifies: binary protocol encoding/decoding, type tag mapping, row
  format round-trip, frame IO between Zig and TypeScript
- Equivalent to TB's client library tests
- Catches: protocol breaking changes, serde bugs, type mismatches

**Level 2: Example integration tests (full handler logic)**
- `cd examples/ecommerce-ts && npm test` — runs the full handler suite
  against a real server with sidecar
- Verifies: create product → query product → update product → create
  order → verify inventory decremented → search → SSE updates → etc.
- Catches: framework bugs that surface through user-space logic. A
  change to `state_machine.zig`'s prefetch ordering, or `storage.zig`'s
  prepared statement caching, or `auth.zig`'s session handling — any of
  these can break handler behavior without touching TypeScript code.
- **Must run on every commit** — framework changes are the primary risk,
  and the diff won't show TypeScript files

When we add more examples (e.g., `examples/ecommerce-python/`), each
gets both levels — same as TB's `inline for (Languages)` pattern.

**`zig build ci -- clients` (future):**
- Level 1 + Level 2 for all example projects
- Equivalent to TB's `zig build ci -- clients`

#### Deferred CI features

**`test:fmt` / `check` (smoke mode):**
TB runs `zig build test:fmt` (formatting check) and `zig build check`
(compilation check without running) in smoke mode. We should add:
- `zig fmt --check *.zig framework/*.zig` — formatting
- Tidy checks (e.g., no `std.debug.print` in non-test code)

**`devhub` / `devhub-dry-run`:**
TB runs devhub (benchmarks + kcov + dashboard deploy) on main after
merge. PRs run devhub-dry-run (same but no upload). We'd add this
when we build the devhub viewer.

**Doc building:**
TB builds docs and link-checks them in smoke mode. We'd add this
when we have documentation to build.

**Readme generation / freshness checks:**
TB's ci.zig runs `client_readmes.test_freshness` to verify that
generated client READMEs are up to date. If we generate any docs
from code (e.g., handler API docs, sidecar protocol docs), add a
freshness check here to catch stale generated files.

**Docker image:**
TB ships `ghcr.io/tigerbeetle/tigerbeetle` — a single binary in a
container. Their CI verifies `latest` tag matches the release tag
and the container prints the correct version.

Our Docker image would be the framework + runtime (Zig, SQLite,
compiled server, sidecar runtime). Users add their handlers:
`FROM tiger-web:latest` + `COPY handlers/ /app/handlers/`.
Add when we're ready to ship — not before the framework is stable.
When added, port TB's docker digest verification pattern.

**`--example=X` filter for ci.zig:**
TB's ci.zig supports `--language=X` to test a single client. We
deferred this because TB's flags.zig requires enums with >= 2
variants. When we add a second example project, add the `Example`
enum and `--example` CLI arg.

### `devhub` — after ci
TB's devhub builds the dashboard that visualizes CFO seed data, benchmark
results, and kcov coverage. Deployed to GitHub Pages. This is what makes
CFO results visible and actionable.

Without devhub, seeds accumulate in devhubdb but nobody sees them unless
they read the JSON. We need at minimum a viewer for:
- Failing seeds per commit (which fuzzers, which seeds, how long)
- Fuzzing effort over time (total seeds per commit)
- Benchmark regression detection

Copy TB's `scripts/devhub.zig` as starting point, adapt to our fuzzers
and benchmark.

### `release` — when we ship
Not needed until we have publishable artifacts (npm package, Docker image,
etc.). Defer.

### `changelog` — when we ship
Not needed until we cut releases with changelogs. Defer.

### `amqp` — not applicable
TB-specific protocol testing. We don't have AMQP. Skip permanently.

## CFO features (kept in code, activated in Phase 8)

These are in the copied cfo.zig but inactive until we configure them:

### PR-branch fuzzing
- Needs `GH_TOKEN` on CFO machine
- Needs `fuzz` label in our GitHub repo
- Code already handles it — just add the token

### Release commit pinning
- Needs a release branch
- Code already handles it — just cut a release

### Log capture
- Needs a multi-process fuzzer with `capture_logs() = true`
- Code already handles it — just set the flag on a fuzzer

## Build infrastructure (needed for ci subcommand)

### `-Dprint-exe` build option
Done — ported in Phase 5.

### GitHub Actions workflow
TB's `.github/workflows/ci.yml` calls `zig build ci -- test`. We need
our own workflow that does the same with our ci subcommand.

### Audit: vendored zig usage
We vendor Zig at `./zig/zig` (downloaded via `zig/download.sh`). All
build invocations must use `./zig/zig build`, never bare `zig build`.
Audit every place we reference the zig binary:
- `CLAUDE.md` quick reference commands
- `scripts/cfo_supervisor.sh` (done — uses `./zig/zig`)
- `scripts/cfo.zig` display command (done — uses `./zig/zig`)
- CI workflow (when created)
- Any Makefiles, shell scripts, or docs that invoke zig

`ZIG_EXE` env var must be set to `./zig/zig` wherever Shell.zig is
used — Shell.zig reads it at init and panics if it's null when
`exec_zig` or CFO's build step is called.

## CFO deployment — 24/7 fuzzing VM

The CFO code is ported but needs a machine running `cfo_supervisor.sh`
continuously to actually fuzz. Without this, the infrastructure exists
but produces no seeds.

### Machine sizing
TB runs "a cluster of machines" (HACKING.md) — each identifies itself
by hostname in git commits (`use_hostname = true`). No specs in their
codebase. Their VOPR fuzzers are CPU-hungry (30min timeout, weight 8),
so they likely use 16+ core machines.

Our fuzzers are single-process, sub-minute, no massive comptime
instantiation. 2-4 cores is plenty — each core runs one fuzzer in
parallel. A 2-vCPU machine running 2 fuzzers continuously produces
~3,800 seeds/hour (2 fuzzers × ~30s average × 60min).

### Setup
1. Provision a VM (Hetzner CX22 ~€4/mo 2 vCPU, or Oracle free tier 4 ARM cores)
2. Install: git, C compiler (for sqlite3 linkage)
3. `scp scripts/cfo_supervisor.sh user@machine:~/`
4. Generate DEVHUBDB_PAT (GitHub classic token, `repo` scope)
5. On the VM: `export DEVHUBDB_PAT=<token>`
6. Run: `nohup sh cfo_supervisor.sh &` or create a systemd unit

### Optional: GH_TOKEN for PR-branch fuzzing
- Generate a second PAT (read-only, `repo` scope)
- `export GH_TOKEN=<token>` on the VM
- Add `fuzz` label to the GitHub repo
- CFO automatically picks up labeled PRs

### Monitoring
Once devhub viewer is built, check `devhubdb/fuzzing/data.json` for
seed accumulation. Until then: `gh api repos/hireAlanAyala/tiger-web-devhubdb/commits?per_page=5`
to verify the CFO is pushing.
