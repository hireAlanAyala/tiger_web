# Post-CFO Port — Features to Implement

After the CFO port plan (Phases 1-8) completes, these are the capabilities
we deleted or deferred that need to come back.

## Scripts subcommands (deleted from scripts.zig)

We deleted 5 subcommands from TB's scripts.zig. These are the ones we need
and when.

### `ci` — immediately after plan
TB's `scripts/ci.zig` orchestrates the full CI pipeline: smoke tests, unit
tests, fuzz smoke, VOPR (commit-SHA-as-seed), client library tests, tidy
checks. This is what their GitHub Actions calls (`zig build ci -- test`).

We need our own version that runs:
- `zig build unit-test`
- `zig build test` (sim tests)
- `zig build fuzz -- smoke`
- `zig build scan -- handlers/` (annotation scanner)

Copy TB's `scripts/ci.zig`, strip their test targets, wire ours. Add the
`ci` variant back to scripts.zig CLIArgs. Then add a GitHub Actions workflow
that calls `zig build scripts -- ci`.

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
