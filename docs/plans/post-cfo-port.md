# Post-CFO Port — Features to Implement

After the CFO port plan (Phases 1-8) completes, these are the capabilities
we deleted or deferred that need to come back.

## Scripts subcommands (deleted from scripts.zig)

We deleted 5 subcommands from TB's scripts.zig. These are the ones we need
and when.

### `ci` — immediately after plan

TB's CI is a **build.zig step** (`zig build ci -- test`), not a scripts
subcommand. The build step invokes other build steps as subprocesses via
`build_ci_step` and `build_ci_script` helpers. `scripts/ci.zig` only
handles client library testing — the orchestration lives in build.zig.

We should match this pattern: `zig build ci -- <mode>`.

#### CI modes (matching TB's pattern)

**`zig build ci -- test` (default):**
- `zig build test` — sim tests (27 scenarios + PRNG fuzz)
- `zig build unit-test` — unit tests
- `zig build fuzz -- smoke` — all 4 fuzzers, small event counts
- `zig build scan` — annotation scanner

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

#### Example project testing (our equivalent of TB's client tests)

TB tests each client library (dotnet, go, rust, java, node, python) to
verify the SDK works against the server. Our equivalent: test each
example project in `examples/` to verify the sidecar SDK works.

Currently one: `examples/ecommerce-ts/`. Pattern:
```zig
const examples = .{ "ecommerce-ts" };
inline for (examples) |example| {
    // npm install, npm run build, npm test
    build_ci_step(b, step_ci, .{"test-adapter"});
}
```

When we add more examples (e.g., `examples/ecommerce-python/`), each
gets a CI entry — same as TB's `inline for (Languages)` pattern.

**`zig build ci -- clients` (future):**
- Build + test all example projects
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
