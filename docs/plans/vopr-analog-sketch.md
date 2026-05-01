# VOPR-Analog — Design Sketch

**Status (2026-04-30):** post-G.1 reference, not a current blocker.
G.1 (dashboard) shipped 2026-04-27; the prerequisite for VOPR-analog
is satisfied. The current testing model — sim tests + CFO-driven
swarm of boundary fuzzers (codec, render, replay-crash-restart,
message_bus, worker_dispatch, row_format, state_machine) + mutation
testing for assertion confidence — is the layered TB-1:1-in-spirit
investment we made instead. VOPR-analog remains the biggest
single-shot correctness win available; this doc holds the design.

**Scope of this document:** design sketch only, not build plan. The
TB-lens audit identified VOPR-analog as the biggest correctness win
available (see `tb-alignment.md` item 8). Weeks of build energy
should not commit to an answer without first sketching the
primitives needed, the state space to explore, and the integration
shape. This file is that sketch.

**What VOPR is (reference context).** TigerBeetle's VOPR (Viewstamped
Operation Replicator) is a state-space explorer that drives their
VSR cluster deterministically through millions of scenarios (node
faults, network partitions, message reorderings, disk faults, clock
skew), asserting global invariants after every step. Every PR on
TB's CI runs VOPR with a fresh PRNG seed; seeds that surface failures
are kept in `fuzzing/data.json` for regression replay. VOPR is what
lets TB claim "we believe our distributed correctness story"
without hand-proving it.

**Why we need the analog.** Tiger Web has:

- A server + sidecar architecture with 1-RT SHM dispatch.
- A WAL with hash-chain recovery under truncation/corruption.
- Session HMAC + cookie signing with a rotatable secret.
- Concurrent pipeline slots serialized by a `handle_lock`.
- ~27 hand-written sim scenarios that cover specific faults.

None of these have state-space exploration. A VOPR-analog would
exercise:

- Sidecar restart mid-dispatch (pending requests reconciling).
- HTTP parser fuzz against malformed requests.
- WAL recovery under concurrent writes + partial disk failures.
- SHM slot contention under adversarial reads/writes.
- Session secret rotation mid-request.

The gap this closes: **today we trust these paths because
hand-written scenarios cover specific cases**. A VOPR-analog asserts
*global invariants* after *every* step of *every* scenario the
PRNG can reach, which is categorically stronger.

---

## Primitives needed

### 1. Deterministic scheduler

The existing `SimIO` + `sim_sidecar.zig` already run single-threaded
with PRNG-driven fault injection. VOPR-analog builds on this:

- **Step function:** one call advances the system by one unit of
  work (one IO completion, one tick, one sidecar frame). Must be
  pure-PRNG-driven; no wall-clock, no OS-specific randomness.
- **Invariant check:** runs after every step. Failure = assertion
  panic with the scenario's full action log.

### 2. Scenario description

Each scenario is a sequence of actions parameterized by the PRNG:

```zig
const Action = union(enum) {
    client_request: struct { op: Operation, body: []const u8 },
    sidecar_restart: void,
    network_partition: struct { target: enum { sidecar, client } },
    disk_fault: struct { target: enum { wal, db }, kind: enum { busy, corrupt } },
    clock_skew: struct { ms: i64 },
    session_rotation: void,
};
```

The PRNG picks an `Action` variant per step, weighted by a fault
profile. The profile matters: 90% "normal request", 10% "something
goes wrong" produces different coverage than 50/50.

### 3. Invariants

Checked after every step. Start with these (order = stronger first):

- **Durability:** every request that received a 2xx response must
  be present in the WAL or flagged as a write-in-flight.
- **Idempotence:** replaying the WAL from any truncation point
  must reach the same DB state (modulo writes that hadn't
  completed at truncation).
- **Response ordering:** for a given session, responses arrive in
  request-submission order.
- **No double-commit:** the pending_dispatch index never carries
  two entries with the same request_id.
- **Session continuity:** a valid session cookie always
  authenticates the correct user-id, regardless of secret
  rotation.
- **HMAC integrity:** any forged cookie is rejected.

These six invariants are a v1 list. Expect to add 5-10 more as the
explorer surfaces failures that reveal hidden invariants.

### 4. PRNG seed management

Mirror TB's pattern exactly (`scripts/cfo.zig` already does this):

- Each VOPR run starts from a seed.
- Seeds that trigger failures are captured in
  `tiger-web-devhubdb:fuzzing/data.json` alongside the CFO seeds.
- Regression replay: `zig build vopr -- <seed>` reproduces the
  exact failure.

### 5. CI integration

Per-PR: fixed time budget (say 60s), PRNG picks a seed, runs as
many scenarios as fit.

Per-commit on main: longer budget (say 10 minutes), multiple
seeds, results uploaded to devhubdb.

New seeds with failures don't block the PR — they land in
`fuzzing/data.json` and become regression fixtures.

---

## State space

**Explicit scope statement (TB-style):** the state space to
explore is the product of:

| Dimension | Range |
|---|---|
| Pipeline slots | 1–16 |
| Sidecar count | 1–4 |
| Connection count | 0–128 |
| Request mix | `Operation` × (valid / malformed / adversarial) |
| Fault profile | normal (0.9) / disk-fault (0.05) / net-fault (0.03) / sidecar-crash (0.02) |
| WAL state | empty / populated / mid-truncation / post-crash |
| Clock skew | ±5s |
| PRNG seed | u64 |

Approximate state-space size: ~10^18 (dominated by the PRNG seed).
VOPR's value is not exhaustive exploration but *unbiased sampling*
— every scenario the PRNG reaches is as likely as any other.

---

## Integration shape

Three files, minimal surface:

- **`vopr.zig`** — main entry point. `zig build vopr [-- <seed>]`.
  Constructs the simulated universe (SimIO + sim_sidecar + in-mem
  WAL + in-mem storage), drives the step loop.
- **`vopr_actions.zig`** — the Action enum + PRNG-weighted
  selection + per-action execution logic.
- **`vopr_invariants.zig`** — the invariant checks. One function
  per invariant; each takes the simulated-universe handle and
  returns `!void` (panics on violation via assert).

Reuses existing infrastructure:
- `sim.zig`'s faultable SimIO.
- `sim_sidecar.zig`'s frame builder.
- `fuzz_lib.zig`'s PRNG discipline.
- `storage.zig`'s `:memory:` SQLite mode.

---

## Non-goals for v1

Deliberately excluded to keep the first version shippable:

- **Multi-replica.** TB's VOPR explores cluster scenarios; ours
  has no cluster. Single-server-plus-sidecar is the scope.
- **Network-level packet reordering.** Our transport is local
  (unix socket + SHM); out-of-order delivery at the TCP layer
  isn't a real failure mode. Frame-level reordering IS in scope.
- **Time travel.** VOPR-proper supports rewinding and branching
  from checkpoints. v1 is forward-only.
- **Exhaustive state-space search.** Random sampling only. TB
  itself is random; no reason to be fancier.

---

## Effort estimate

| Phase | Effort | What it produces |
|---|---|---|
| Design iteration | 1 day | This doc revised after review |
| Scenario framework + Action enum | 2 days | `vopr_actions.zig` + step loop |
| Invariants (6 listed above) | 3 days | `vopr_invariants.zig` |
| Integration with SimIO/sim_sidecar | 2 days | end-to-end scenario runs |
| Seed-tracking + CI wiring | 1 day | seeds lake in devhubdb |
| First 100 seeds surface failures | 2 days (rolling) | real bugs caught |
| **Total to v1** | **~2 weeks** | first correctness proof point |

This matches the "weeks" estimate in `tb-alignment.md` item 8.

---

## What "ship" means

v1 is done when:

1. `zig build vopr` runs 10 seeds in 60s locally with no failures.
2. A deliberately-injected bug (e.g., remove the WAL's CRC check)
   is caught by the explorer within 100 seeds.
3. CI wiring runs VOPR per-PR with failure capture to
   `fuzzing/data.json`.
4. At least one surfaced failure is reproducible from its seed
   alone.

Until (2) is demonstrated, we don't trust the explorer to be doing
real work. TB's own confidence in VOPR stems from deliberately-
injected bugs being caught reliably — we should demand the same.

---

## Why this isn't scheduled yet

G.1 (dashboard) is the prerequisite for all subsequent correctness
work — a VOPR that surfaces failures is only valuable when "seed
0xdeadbeef was new this week" is visible somewhere. G.1 shipped
2026-04-27, so the prerequisite is satisfied.

What we built instead, in the interim: a layered testing model —
sim tests for hand-picked scenarios, CFO-driven boundary fuzzers
across the wire surface (codec, render, replay-crash-restart,
message_bus, worker_dispatch), mutation testing for assertion
confidence. Each layer caught real bugs in the round-1..8 audit
sequence (2026-04-29..30); the model is TB-1:1 in spirit even
without exhaustive state-space exploration.

VOPR-analog remains the next single-shot correctness win — what it
adds beyond the layered model is *global invariants asserted after
every step* across every reachable scenario. Schedule when the
layered model's defect rate plateaus or when concurrent-pipeline /
WAL-truncation / session-rotation interactions surface a class of
bugs the boundary fuzzers can't reach.

---

## Relationship to `tb-alignment.md` item 9

Item 9 (generative sim-test scenario framework) is the first half
of this: move our ~27 hand-written `sim.zig` scenarios toward
scenario-generator patterns. That work is a *prerequisite* for the
Action-enum + PRNG-weighting described above — item 9's
scenario-generator IS this doc's Action framework under a different
name.

Recommended merge: item 9 becomes part of VOPR-analog's Phase 1
(scenario framework), not a separate tracked item.
