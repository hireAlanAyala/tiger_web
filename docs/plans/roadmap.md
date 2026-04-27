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

### devhub setup (`tiger-web setup --github`)
Automated devhubdb repo creation + PAT configuration. One command from
zero to continuous fuzzing. See `docs/plans/devhub-setup.md`.

### Workers and crons
Workers and crons as framework primitives, not hand-written HTTP clients.
Two new annotations complete the set:

- `[worker]` — async function dispatched from handle via `worker.<name>(args)`.
  Takes args in, returns data, framework delivers result to a completion
  route. `_worker_queue` table is the queue — no Redis, no SQS.
- `[cron]` — handle triggered by schedule instead of HTTP request.
  Replaces `db.after()`/delayed dispatch with a simpler, more powerful
  primitive: the developer writes the query that defines "what's due,"
  the cron dispatches workers.

No delayed jobs in the queue. Delays are domain data — a `send_at`
column in the developer's table, checked by a cron. Queryable,
cancellable, visible, owned by the developer.

See `docs/plans/worker.md` and `docs/plans/cron.md`.

### JSON API responses
The only missing response primitive. Everything else is covered:

| Need | How it works today |
|---|---|
| HTML page | Render returns HTML string |
| HTML fragment | Render returns partial HTML (SSE/Datastar) |
| Redirect | Render returns `<script>window.location='...'</script>` |
| Empty response | Render returns `""` |
| SSE streaming | Built in (`render.zig` handles `Connection: close`) |
| JSON API | **Not supported** — render always returns HTML |

JSON enables: mobile apps, SPAs, third-party integrations — all
hitting the same handlers with the same state machine and fuzz coverage.

Two approaches:
- `// format json` annotation on render — explicit per-handler
- `Accept: application/json` header detection — automatic, same handler
  returns HTML or JSON based on what the client asks for

Same handler logic, same state machine, same fuzz coverage —
different serialization.

### File uploads
User-generated content: profile avatars, product images, document
attachments, CSV imports. Every CRUD app with user content needs this.

### WebSockets
Bidirectional real-time: chat, collaborative editing, multiplayer.
SSE already covers server-push (live dashboards, notifications,
real-time updates). WebSockets are for the cases where the client
also sends real-time messages — not common in CRUD, but expected
in modern apps.

## Later

### CFO as a service
Hosted continuous fuzzing for framework users. 1 vCPU per customer,
~2,880 seeds/day, $5/mo. Includes the framework fuzzer (`tiger-web fuzz`)
as the core addon — zero-config fuzzing from annotations, no test code
required. See `docs/plans/cfo-as-service.md` and `docs/plans/framework-fuzzer.md`.

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

- [Annotation routing](../internal/decision-annotation-routing.md) — `// match` + `// query`
- [Import strategy](../internal/decision-import-strategy.md) — stdx as build module
