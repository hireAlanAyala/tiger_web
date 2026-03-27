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

### Annotation-driven workers
Workers as framework primitives, not hand-written HTTP clients.
Same annotation pattern as routes:
```
// [worker] .process_emails
// poll GET /emails?status=pending
// interval 5s
```
The framework generates the polling loop. The developer writes the
handler. Database state is the queue — no Redis, no SQS. Delayed
jobs via timestamp columns (`send_at`, `retry_at`). Queryable,
auditable, survives crashes, fuzz-tested through the state machine.

Alternative or complement: `db.after()` sugar in the handle phase:
```typescript
db.after("5m", "send_confirmation", { order_id: ctx.id });
db.after("24h", "expire_order", { order_id: ctx.id });
```

Under the hood: `INSERT INTO _scheduled (operation, params, run_at, status)`.
Framework owns the table. Worker polls `WHERE run_at <= now()`. Developer
sees one line. Framework sees a database row. Fuzzer sees a write.
No hidden state — the scheduled table is queryable, cancellable
(`UPDATE SET status = 'cancelled'`), recorded in WAL, exercised by CFO.

Both approaches close the ergonomics gap with Laravel Queue while
keeping the correctness advantages (one source of truth, visible state,
deterministic transitions).

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
