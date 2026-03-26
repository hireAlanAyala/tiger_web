# Plan: CFO as a Service — continuous fuzzing for framework users

## Context

The CFO finds bugs that tests miss. We ran it for 5 minutes and found
8 real assertion failures. Every framework user should have this — not
just us. Run the CFO for them as a hosted service.

## Economics

CRUD app fuzzers are lightweight: single-process, sub-second seeds,
no consensus or B-tree compaction. One vCPU is enough per customer.

### Seeds per vCPU

| Metric | Value |
|---|---|
| Average seed duration | ~30 seconds (50K events) |
| Seeds per hour (1 vCPU) | ~120 |
| Seeds per day | ~2,880 |
| Seeds per month | ~86,400 |

86,400 unique paths explored per month from 1 vCPU. The value comes
from diversity over time, not parallelism. A 1-vCPU fuzzer running
for 30 days finds more bugs than a 16-core fuzzer running for 1 day.

### Infrastructure cost

Hetzner CX22 (2 vCPU, 4GB RAM): €4/month.
Run 4 customers per machine = €1/customer/month.

### Pricing tiers

| Tier | vCPUs | Seeds/day | Price | For |
|---|---|---|---|---|
| Free | 0.5 (shared) | 1,440 | $0 | Solo devs, open source |
| Pro | 2 | 5,760 | $5/mo | Small teams, faster coverage |
| Team | 4 | 11,520 | $10/mo | Teams wanting PR-branch fuzzing |

At $5/mo with €1/mo cost = 80% margin. The infrastructure cost is
negligible — the value is "we found a bug you didn't know you had."

## Architecture

### Per-customer isolation

- Each customer gets their own CFO process (concurrency = tier vCPUs)
- Each customer gets their own devhubdb repo (isolated seed data)
- Shared machine, isolated data — one customer's crash doesn't affect others
- The CFO supervisor already handles process isolation via process groups

### Onboarding flow

```
tiger-web setup --github        # creates devhubdb repo, configures token
tiger-web fuzz --cloud          # connects to hosted CFO service
```

Or self-hosted:
```
tiger-web fuzz --cfo            # runs CFO locally on their machine
```

### What the service runs

Per customer, continuously:
1. `git clone` their repo (read-only access)
2. `./zig/download.sh` (vendored Zig)
3. `./zig/zig build fuzz -- <fuzzer> <seed>` (random seeds)
4. Push results to their devhubdb repo (write access)
5. Repeat on refresh interval (5 minutes)

The CFO code is identical — same `cfo_supervisor.sh`, same merge
algorithm, same seed format. The service just manages multiple
supervisors on shared infrastructure.

### Multi-tenant supervisor

A wrapper that runs one CFO per customer:
```
for customer in customers:
    tmux new-session -d -s $customer \
        "DEVHUBDB_PAT=$token sh cfo_supervisor.sh"
```

Or a proper orchestrator (systemd units, containers) for production.

## What customers see

### devhubdb dashboard (devhub viewer)

- Failing seeds per commit (which fuzzer, which seed, repro command)
- Fuzzing effort over time (seeds per day, coverage)
- Pass rate trend (are we getting more stable?)
- One-click reproduction: copy seed command to clipboard

### Notifications

- Email/Slack when a new failure is found
- Link to devhub with the failing seed
- Repro command included in the notification

## Why this is a moat

No web framework offers hosted continuous fuzzing:
- Rails: you write tests or you don't
- Django: same
- Next.js: same
- Express: same

We provide: "Push your code, we find your bugs. $5/month."

The framework's annotation system makes this possible — we know
the routes, the statuses, the entity lifecycle. Generic fuzzers
(AFL, libFuzzer) can't do this because they don't understand HTTP
semantics. API testing tools (Schemathesis) require OpenAPI specs.
Our annotations ARE the spec.

## Dependencies

- `docs/plans/framework-fuzzer.md` — the generic fuzzer that tests
  any handler app from annotations alone (no hand-written fuzz code)
- `docs/plans/devhub-setup.md` — automated devhubdb repo creation
- devhub viewer — static site to visualize seed data
