# Design 008: Debugging with the WAL

Three tools, each for a different stage of investigation.

## Tools

### `tiger-replay verify <wal>`

Validates the WAL file: checksums, hash chain, sequential ops, mutation-only entries. Run this first — if verify fails, the file is damaged and the other tools can't trust it.

```bash
tiger-replay verify tiger_web.wal
# ok: entries=4 ops=1..4 time=1773760686..1773760686 size=3920
```

### `tiger-replay inspect [options] <wal>`

Prints a filtered timeline of WAL entries. This is the primary debugging tool — most questions are answered here.

```bash
# Everything
tiger-replay inspect tiger_web.wal

# What happened to this product?
tiger-replay inspect --id=00000000000000000000000000000001 tiger_web.wal

# What did this user do?
tiger-replay inspect --user=aabbccdd11223344aabbccdd11223344 tiger_web.wal

# Only updates, with body details
tiger-replay inspect --filter=update_product --verbose tiger_web.wal

# Time window (by op number)
tiger-replay inspect --after=100 --before=200 tiger_web.wal
```

Filters: `--filter` (operation name), `--id` (entity UUID), `--user` (user UUID), `--after`/`--before` (op range). `--verbose` adds key body fields (name, price, version, etc.) to each line.

### `tiger-replay query <wal> <sql>`

Loads the WAL into an in-memory SQLite database and runs your SQL against it. The table has 5 header columns for filtering and a body column for context:

| Column | Type | Content |
|--------|------|---------|
| `op` | INTEGER | Sequential operation number |
| `timestamp` | INTEGER | Unix timestamp |
| `operation` | TEXT | Operation name (create_product, update_product, ...) |
| `id` | TEXT | Entity UUID (32 hex chars) |
| `user_id` | TEXT | User UUID (32 hex chars) |
| `body` | TEXT | Full entry body as readable JSON |

```bash
# Timeline for a specific entity
tiger-replay query tiger_web.wal \
  "SELECT op, operation, body FROM entries WHERE id='00000000000000000000000000000001'"

# Count operations by type
tiger-replay query tiger_web.wal \
  "SELECT operation, count(*) as n FROM entries GROUP BY operation ORDER BY n DESC"

# Recent mutations by a specific user
tiger-replay query tiger_web.wal \
  "SELECT op, operation, id FROM entries WHERE user_id='aabb...' ORDER BY op DESC LIMIT 20"
```

The body column is for display — you read it in the output to see what values were written. The header columns are for filtering and sorting.

### `tiger-replay replay [options] <wal> <snapshot>`

Replays WAL entries against a database snapshot, recreating the exact state at any point in time. Use this when you need the real database to answer a question.

```bash
# Replay everything
tiger-replay replay tiger_web.wal empty_snapshot.db

# Replay up to op 47 with per-operation trace logging
tiger-replay replay --stop-at=47 --trace tiger_web.wal empty_snapshot.db
```

After replay, the work database (`<wal>.replay.db`) has the full schema with typed columns and indexes. Query it with `sqlite3` directly.

## When to use what

| Question | Tool |
|----------|------|
| Is the WAL intact? | `verify` |
| What happened to entity X? | `inspect --id=X` |
| What did user Y do? | `inspect --user=Y` |
| What were the last N operations? | `inspect` piped to `tail` |
| Show me operations with values | `inspect --verbose` |
| How many creates vs updates? | `query` with GROUP BY |
| Find operations matching complex criteria | `query` with WHERE on header columns |
| What was the exact database state at op N? | `replay --stop-at=N` |
| Run real SQL against the data | `replay`, then `sqlite3` on the output |

## Why verify is separate

Verify is not run implicitly before inspect/query. Two reasons:

1. **Cost mismatch.** Verify reads the entire WAL to check the hash chain. Inspect with `--after=999990` only needs the tail. Implicit verify would force a full scan even when the question is small.

2. **Corrupt WALs are still useful.** A crash might corrupt the tail, but the first 50,000 entries are fine. Inspect already skips entries with bad checksums — it's tolerant by design. An implicit verify would refuse to show any data just because the chain is broken early. That's the wrong tradeoff for a debugging tool.

The developer who cares about integrity runs `verify` first. The developer who knows their WAL is clean skips to `inspect`.

## Progression

Most debugging follows this path:

1. **verify** — confirm the WAL is intact (optional but recommended)
2. **inspect** — find the relevant operations (90% of investigations end here)
3. **query** — when you need SQL aggregation or complex filtering on the timeline
4. **replay** — when you need the actual database state, not just the event log
