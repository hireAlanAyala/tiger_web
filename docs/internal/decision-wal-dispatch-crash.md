# Decision: WAL dispatch crash semantics

## Context

The WAL records worker dispatch entries atomically with SQL writes.
The WAL has no fsync — the kernel flushes on its own schedule. SQLite
is fsynced. On crash, SQLite wins.

## The gap

If the process crashes after SQLite commits but before the WAL entry
reaches disk, the SQL writes survive but the dispatch entry is lost.
The order exists in the database but no worker runs. The payment is
never charged.

## Decision: accept the gap

The framework does not guarantee that every dispatch survives a crash.
The WAL remains a diagnostic notebook with operational dispatch
tracking as a best-effort addition. No fsync.

**Why not fsync?** Fsync per commit kills throughput. The WAL is not
a replication log — SQLite handles durability. Adding fsync to the
WAL for dispatch reliability changes the WAL's contract for one
feature.

**Why not a SQLite table?** A `_pending_dispatches` table would be
atomic with handler writes (same transaction). But it's mutable
derived state that can diverge from the log, and a user can corrupt
it with `sqlite3`. The WAL's single-writer property is worth keeping.

**Why this is OK:** Completion handlers are already idempotent by
design. The developer's schema should make stuck states detectable.
An order in `processing` with no completion after N minutes is an
orphan — the application can find and re-dispatch it. This is the
same recovery model as any system where the queue is less durable
than the database.

## Application-level recovery pattern

```sql
-- Find orders stuck in processing (no worker completed them).
SELECT id FROM orders
WHERE status = 'processing'
  AND updated_at < datetime('now', '-5 minutes');
```

The framework provides the mechanism (dispatch + completion +
deadline). The application provides the policy (what "stuck" means
and how to recover). This is explicit — the developer knows the
failure mode and designs for it.

## What the framework guarantees

1. If the WAL entry survives, the dispatch eventually resolves
   (success, failure, or dead).
2. The pending index is rebuilt from the WAL on startup — no lost
   in-flight state from a clean restart.
3. Completion handlers always run for resolved dispatches.
4. The scanner proves `ctx.worker_failed` is handled at build time.

What it does NOT guarantee: that every `worker.xxx()` call survives
a crash. The crash window is small (between SQLite commit and kernel
WAL flush), but it exists.
