# Storage Resilience — Graceful Degradation on Corrupted Data

## Problem

`read_column` in storage.zig uses assert to validate data read from
SQLite. If the database is modified externally (sqlite3 CLI, migration
script, data import, backup restore), these asserts crash the server —
dropping all 128 connections, killing every in-flight request.

Tiger-web has no replication. One process, one core. A crash means
the website is down. For an ecommerce server, that's lost revenue
and lost trust. Users cannot trust a server that crashes because
someone ran a SQL migration.

## What was fixed

**Text length overflow** — the most likely crash path. A product
name or description exceeding the domain constant (128/512 bytes)
crashed the server on the next query. Now truncates and logs a warning.
The user sees slightly wrong data. The operator sees the warning.
The server stays up.

## Remaining risk surfaces

All in `read_column` (storage.zig), all triggered by external database
modification:

| Assert | Trigger | Likelihood | Impact |
|---|---|---|---|
| `col_type == SQLITE_TEXT` | Text in an integer column | Low — requires wrong-type INSERT | Crash |
| `col_type == SQLITE_INTEGER` | Integer where text expected | Low | Crash |
| `col_type == SQLITE_BLOB` | Wrong type in UUID column | Low | Crash |
| `blob_ptr != null` | NULL in a UUID column | Low — requires explicit SET NULL | Crash |
| `column_bytes == 16` | Wrong-size blob in UUID | Very low | Crash |
| `val >= 0` | Negative value in unsigned column | Low | Crash |
| `val <= maxInt(T)` | Value exceeding type range | Low — u32 max is 4 billion | Crash |

These require putting fundamentally wrong-typed data into columns,
not just oversized valid data. Less likely than the text length
issue but still possible via migration scripts or bulk imports.

## What's air-gapped

The handler layer cannot trigger these asserts through normal API
usage:

- **HTTP parsing** — returns errors on malformed requests, no assert
- **JSON codec** — returns null on invalid input, no assert
- **Handler route functions** — return null on bad data, no assert
- **Handler INSERT/UPDATE** — validates domain constraints before write
- **Connection state machine** — asserts on internal state only
- **WAL replay** — checksums reject corruption, no data-driven assert

The risk surface is exclusively `read_column` — the boundary between
SQLite's dynamic type system and Zig's static types.

## Remaining tidy-up

Change `read_column` to return `?T` instead of `T`. On type mismatch,
NULL violation, or range overflow: log a warning, return null. The
calling `query` function already returns `?T` — null means "row not
found" or "row unreadable." The handler sees null and returns
"not found" — a graceful degradation.

This requires:
1. Change `read_column` return type to `?T`
2. Change `read_row_mapped` to propagate null (any corrupt column →
   skip the row)
3. `query` already returns `?T` — no change
4. `query_all` skips corrupt rows instead of including them
5. Add a test: insert corrupt data via raw SQL, verify query returns
   null and logs a warning

Estimated effort: ~50 lines changed in storage.zig, no handler changes.

## Prevention as architecture grows

The root cause: SQLite has no schema-level type enforcement. `TEXT`
columns accept any length. `INTEGER` columns accept text. The Zig
type system assumes the data matches — the assert is the only bridge.

As new query result types are added (new handlers, new entities),
every `[N]u8` field and every integer field in a Row struct is a
potential crash path if the database is modified externally.

**Rules to prevent regression:**

1. **Never assert on data read from SQLite.** Use `if` checks with
   log warnings. Asserts are for programming errors (wrong schema,
   wrong query). External data is not a programming error.

2. **The text length fix is the pattern.** Check the value, log if
   wrong, truncate or return null. Apply to every type in read_column.

3. **Add a fuzz test for corrupt data.** Insert random values of
   wrong types and sizes via raw SQL, then query via the typed API.
   The server must not crash — it should return null and log warnings.

4. **Document in the checklist.** Add to docs/internal/checklist.md:
   "New query result types: verify read_column handles corruption
   gracefully for every field type."
