# Cloud Offerings

## Repo split

`framework/` is the open source project (MIT). Everything else is private — the application, fuzz suite, sidecar infra, ops tooling, and cloud platform.

### Open source (framework/)

The framework includes its assertions and unit tests. They're marketing, not IP. They show the framework is built seriously, help users self-serve without filing issues, and attract engineers who think "I want to work on this." The real moat is the fuzz oracle, sidecar, and cloud platform — not the framework's test suite.

Contents: server, connection, HTTP parser, IO (epoll), WAL, tracer, auth, marks, PRNG, time, flags, bench, checksum, stdx. All with inline tests.

### Private (everything else)

- Application core (app, message, codec, render, state_machine, storage)
- Sidecar infra (codegen, protocol, annotation scanner, adapters)
- Fuzz/sim suite (sim, auditor, all *_fuzz files, fuzz_tests, fuzz_lib)
- Ops tooling (replay, worker, loadtest, benchmark)
- Examples, plans, decisions, docs

The sidecar protocol and a basic local runner ship with the framework so developers can build locally. Managed sidecar orchestration (restart, health, deploys) is cloud-only.

## Framework boundary

The framework detects failure and reports it. The cloud layer decides what to do about it.

- **WAL** stays in framework — pure append-on-commit mechanics. Cloud reads the WAL file for dashboards.
- **Tracer** stays in framework — collects timing/counts, emits to stderr. Cloud captures stderr and routes to dashboards.
- **Sidecar restart** is NOT in framework — framework detects closed socket and fails in-flight requests. Restarting is a supervisor concern (systemd, cloud orchestrator). No fork/exec in the event loop.

## Cloud features

### Correctness dashboard

Surface the fuzz suite results. The auditor runs continuously on cloud infra, exercises every operation with PRNG-driven inputs, and validates state machine responses against the reference model. Dashboard shows: operations tested, seeds passed, coverage marks hit, last failure (if any).

No one self-hosting will rebuild this. It's person-years of test infrastructure presented as a one-click feature.

AI-generated auditors: the cloud generates auditor logic from entity declarations (auto for CRUD, AI-assisted for custom operations). For custom prefetch SQL, AI analyzes the query against the schema and known data to detect bugs — bad joins, missing filters, soft-delete leaks, type mismatches. The user gets fuzz coverage for their custom queries without writing mocks or auditor code.

### Determinism dashboard

Replay testing — run the same seed twice, compare every response byte-for-byte. Dashboard shows: seeds replayed, divergences detected, which operation diverged, which sidecar handler introduced non-determinism.

This is the "is my sidecar handler pure?" answer that developers can't easily get locally.

### Managed sidecar

- Auto-restart on crash
- Health monitoring
- Zero-downtime deploys (drain connections, start new sidecar, cut over)
- Log streaming
- Latency tracking per handler

### Managed WAL

- WAL replay debugging in the browser (inspect, query, replay operations)
- Time-travel: "show me the state at operation N"
- WAL shipping for backup/DR
- Disk usage projections and alerts
- `tiger-replay diff` — replay WAL into a fresh DB, compare against live DB (row counts, checksums per table). Detects external writes that bypassed the framework. Run periodically on the correctness dashboard to flag drift

### Managed workers

- Worker orchestration (poll scheduling, retry, dead letter)
- External API call monitoring
- Determinism boundary enforcement (flag non-mocked calls)

### Deploy pipeline

- Push to deploy (merge to main triggers build + deploy)
- Migration runs on startup (ensure_schema)
- Rollback = start old binary (additive-only migrations guarantee compatibility)
- Single VPS, single writer, millisecond downtime
