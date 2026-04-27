# SQLite :memory: Is Fast Enough

## Measured (2026-03-26)

| Events | TigerBeetle | Tiger Web | Per-event TB | Per-event ours |
|---|---|---|---|---|
| 10K | 526ms | 214ms | ~53μs | ~21μs |
| 50K | 2,235ms | 999ms | ~45μs | ~20μs |

Both measured on the same machine, same session. TigerBeetle seed
12345, ours seed 12345 (10K used random seed). State machine fuzzer
in both cases — random operations through prefetch/commit, PRNG-driven
fault injection.

## Why we're faster

Not because SQLite is faster than their LSM tree. Because our system
is simpler:

- **No replication.** Their fuzzer exercises multiple simulated
  replicas with consensus rounds. Ours is single-process.
- **No network simulation.** Their packet simulator adds latency,
  drops, reordering between replicas. Ours has no network layer.
- **No LSM compaction.** Their storage does B-tree lookups, bloom
  filter checks, compaction bookkeeping. Ours does prepared statement
  execution against an in-memory database.
- **No I/O.** SQLite :memory: never touches disk. Their storage
  simulates sector-level I/O.

The per-event cost difference (~20μs vs ~45μs) reflects architectural
complexity, not storage engine quality.

## Why this matters

The old `storage-boundary.md` worried that "SQLite overhead would make
simulation testing impractical." This was wrong. 50K events in under a
second is more than enough for CI smoke tests. TigerBeetle runs 10K
events per commit in their CI smoke mode — we can run 50K in less time
than they run 10K.

## Not an apples-to-apples comparison

These numbers can't be used to claim "SQLite is faster than TB's
storage." The systems solve different problems at different layers.
TB's per-event cost buys consensus, durability, and replication that
we don't have. We pushed durability to the WAL and replication to
"not our problem."

The only valid conclusion: SQLite :memory: with prepared statements
is fast enough that it's not the bottleneck for simulation testing.
The fuzzer's event budget is limited by CI time, not by storage speed.
