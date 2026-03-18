# Idea: WAL as Source of Truth

Today SQLite is the authority and the WAL is a secondary log (no fsync, skip on
failure). This document captures why the WAL should become the source of truth
if we move toward serverless infrastructure.

## The problem with memory-only compute

Serverless compute is ephemeral. State lives in memory during a session and is
destroyed on scale-to-zero. The state machine is deterministic — given the same
sequence of messages, it always produces the same state. So we don't need to
persist the state itself. We need to persist the inputs: the WAL.

## Why the WAL, not the database

The WAL is a strictly ordered sequence of Messages. Each entry is a fixed-size
extern struct with a checksum. The state machine replays them to reconstruct
any point in time.

A database (SQLite, Postgres) stores the *result* of computation. The WAL stores
the *computation itself*. This distinction matters:

- **Replay**: given the WAL, you can rebuild the database from scratch. Given
  only the database, you cannot reconstruct the WAL. The WAL is the more
  fundamental artifact.

- **Branching**: fork the WAL at any offset, apply different writes, get a
  divergent database. Instant preview/staging environments. Impossible if the
  database is the authority.

- **Time travel**: replay to any WAL offset to see historical state. No need
  for temporal tables, audit logs, or soft deletes — the WAL already is the
  complete history.

- **Debugging**: reproduce a production bug by replaying the WAL locally.
  Determinism guarantees the same state machine reaches the same state.

- **Portability**: the WAL is infrastructure-independent. It's just bytes.
  Move it between S3, local disk, or a replication stream. The database
  format is an implementation detail of whichever storage backend replays it.

## Durability boundary

The WAL must be durably stored before the client gets a response. This is the
contract: if the client sees success, the WAL entry is safe.

Today's tick loop already separates mutation from response:

```
process_inbox()  — prefetch, commit, buffer WAL entries
flush_outbox()   — send responses to clients
```

The durability hook goes between them:

```
process_inbox()  — prefetch, commit to memory, buffer WAL entries
ship_wal_batch() — send batch to durable storage, wait for ack
flush_outbox()   — send responses (only after WAL is safe)
```

If compute dies before the WAL ships, no responses were sent. Clients see a
disconnect and retry. No data is lost, no phantom writes.

## Batching amortizes the cost

The tick collects all mutations from all connections, then ships them as one
WAL batch. One network round trip per tick, not per request. The 10ms tick
interval that exists for SQLite fsync amortization works equally well for
network amortization.

## Snapshots bound cold start

Replaying the entire WAL on every cold start is too slow as the WAL grows.
Periodic snapshots (serialized state machine) checkpoint the state. Cold start
becomes: load snapshot + replay WAL tail since snapshot.

Snapshot frequency is a cost/latency tradeoff:
- Frequent snapshots: fast cold start, more storage writes
- Infrequent snapshots: slow cold start, cheaper storage

For small-state apps (ecommerce catalog + orders), the WAL tail is short and
cold start is milliseconds regardless.

## What changes in the codebase

- `wal.zig` gains durability (today: no fsync, best-effort append)
- `server.zig` gains a `ship_wal_batch()` step between process_inbox and
  flush_outbox
- SQLite becomes optional — one storage backend among many, not the authority
- The state machine and user code (operations, types, prefetch/execute) do
  not change at all

## What this enables as a product

If the framework takes off and we offer managed infrastructure:
- Users deploy their state machine, we store their WAL
- Scale to zero: no traffic = no compute, just WAL storage (pennies)
- Replay debugging and branching come free
- Replication is WAL shipping to followers (determinism guarantees identical state)
- The WAL is the product. Everything else is derived.
