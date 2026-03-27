# Roadmap

## Now: Infrastructure is live

CI passes on GitHub Actions. CFO runs 24/7 on local machine, pushing
seeds to devhubdb. 72 integration tests cover all 24 handlers through
the full sidecar pipeline. Annotation-driven routing is unified across
Zig and TypeScript.

## Next

### devhub viewer
Static site to visualize CFO seed data. Copy TB's 3-file pattern
(index.html, style.css, devhub.js). Deploy to GitHub Pages.
- Fuzz runs table: seed records with repro commands, failing seeds highlighted
- Benchmark charts: performance regression detection over time (ApexCharts)
- Deploy via GitHub Actions on main push

### Framework fuzzer (`tiger-web fuzz`)
Zero-config fuzzing for any handler app. The framework reads annotations,
generates random valid requests, exercises the full sidecar pipeline.
No test code required. See `docs/plans/framework-fuzzer.md`.

### devhub setup (`tiger-web setup --github`)
Automated devhubdb repo creation + PAT configuration. One command from
zero to continuous fuzzing. See `docs/plans/devhub-setup.md`.

## Later

### CFO as a service
Hosted continuous fuzzing for framework users. 1 vCPU per customer,
~2,880 seeds/day, $5/mo. See `docs/plans/cfo-as-service.md`.

### CI improvements
- `ci -- smoke` mode: `zig fmt --check`, tidy checks
- Per-target manifests (fix two-writers problem)
- dispatch.generated.ts freshness check
- Orphan process cleanup on CI kill

### Shipping
- Docker image (framework + runtime base)
- Release/changelog scripts
- `--example=X` filter for ci.zig (when 2+ examples)
- First release cut (creates release branch, CFO fuzzes both)

## Decisions

- [Annotation routing](../decisions/annotation-routing.md) — `// match` + `// query`
- [Import strategy](../decisions/import-strategy.md) — stdx as build module
