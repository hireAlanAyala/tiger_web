# Post-CFO Port — Remaining Work

## Done

- Integration test suite: 72 tests, all 24 handlers, full sidecar pipeline
- `zig build ci` build step: test, fuzz, clients, default modes
- GitHub Actions workflow: CI passes on push/PR
- `scripts/ci.zig` ported from TB: two-level testing (adapter + integration)
- `-Dprint-exe` build option
- Unified annotation routing: `// match`, `// query`, generated routes table
- Dispatch resilience: try/catch on all handler phases
- Framework TestRunner: `generated/testing.ts`
- Dispatch bugs fixed: prefetch mode `'one'`→`'query'`, method enum PUT/DELETE swap
- devhubdb repo created: `hireAlanAyala/tiger-web-devhubdb`
- Cross-language contracts: route_match_vectors.json, method_vectors.json

## Next: CFO deployment

The CFO code is ported but needs a machine running `cfo_supervisor.sh`
continuously to actually fuzz. Without this, the infrastructure exists
but produces no seeds.

### Machine sizing
Our fuzzers are single-process, sub-minute. 2-4 vCPU is plenty.
A 2-vCPU machine produces ~3,800 seeds/hour.

### Setup
1. Provision a VM (Hetzner CX22 ~€4/mo, or Oracle free tier ARM)
2. Install: git, C compiler (for sqlite3 linkage)
3. `scp scripts/cfo_supervisor.sh user@machine:~/`
4. Generate DEVHUBDB_PAT (GitHub classic token, `repo` scope)
5. `export DEVHUBDB_PAT=<token>`
6. `nohup sh cfo_supervisor.sh &` or systemd unit

### Optional: PR-branch fuzzing
- Generate GH_TOKEN (read-only, `repo` scope)
- `export GH_TOKEN=<token>` on the VM
- Add `fuzz` label to GitHub repo

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

**Docker image:** Framework + runtime base image. Port TB's docker
digest verification. Defer until framework is stable.

**Release/changelog:** Not needed until we ship artifacts.

**`--example=X` filter:** Add when we have 2+ example projects
(TB's flags.zig requires enums with >= 2 variants).

## Plans

- `docs/plans/framework-assert.md` — implemented (dispatch resilience)
- `docs/decisions/annotation-routing.md` — implemented (unified routing)
- `docs/decisions/import-strategy.md` — implemented (stdx module)
