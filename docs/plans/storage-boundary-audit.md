# Storage Boundary Audit

What the framework owns at the storage boundary, what's hardened, and
what gaps remain. Based on responsibilities defined in
`decisions/storage-ownership.md`.

## 1. SQL-to-struct mapping

### Hardened

- `assert_column_count` — struct field count vs SELECT column count
- `read_column` integer range assertions — no truncation
- `read_column` UUID blob size — `assert(blob == 16)`
- `read_column` NULL UUID assertion — crash, not garbage
- `read_column` text length — `assert(len <= array.len)`
- `read_column` slice rejection — `@compileError` on `[]const u8`
- `read_column` packed struct — range-check, bitcast
- `read_column`/`bind_param` unsupported type — `@compileError`

### Open gaps

- **Column order is convention, not verified.** Positional mapping means
  reordering columns in SELECT silently corrupts data. Fix: assert
  `sqlite3_column_name` matches struct field name on first row.

- **bind_param doesn't check param count.** 3 placeholders + 2 args =
  silent NULL bind. Fix: assert `bind_parameter_count == args.len`.

- **bind_param doesn't check return codes.** `_ = sqlite3_bind_*`.
  Fix: assert `rc == SQLITE_OK` after every bind.

- **query/query_all return null for all failures.** Can't distinguish
  not-found from prepare-failed from busy. Low priority — callers
  are simple, typed interface is new.

- **query_all doesn't detect truncation gracefully.** Asserts if
  result exceeds max. SQL should have LIMIT but nothing enforces it.

- **No UTF-8 validation on read path.** Trusted because we validated
  on write (input_valid). Only matters if external tools modify the DB.

## 2. Framework invariants (prefetch/execute lifecycle)

### Hardened

- prefetch asserts cache is null (no double-prefetch)
- commit reads cache via `.?` (crash if no prefetch)
- commit defers cache reset (no stale data)
- commit defers invariants() (structural cross-check)
- begin_batch/commit_batch wraps process_inbox (one txn per tick)
- ReadView enforces prefetch is read-only (runtime)
- WriteView enforces handle is write-only (runtime)
- Scanner enforces prefetch=SELECT, handle=INSERT/UPDATE/DELETE (build time)

### Open gaps

- **Handlers receive `db` reference in handle.** Nothing prevents
  calling storage directly if the handler has access to the storage
  pointer. Low risk while dispatch goes through HandlersType.

## 3. Availability behavior

### Hardened

- busy → retry (connection stays ready, retried next tick)
- corruption → panic (crash immediately)
- err → 503 (storage_error status)
- Fault injection at dispatch boundary (app.zig fault_prng)

### Open gaps

- **No retry cap on busy.** Indefinite busy = connection stuck forever.
  Idle timeout eventually kills it but no explicit cap.

- **Write failure model unclear.** `execute()` returns false on error.
  Decide: are write failures panics (TB convention) or returned errors
  (web convention)?

## 4. Input validation boundary

### Hardened

- `input_valid` — exhaustive switch, validates before prefetch
- NUL byte rejection in text fields
- Fuzzer generates 10% random messages to exercise boundary

### Open gaps

- **No validation on read path.** Data from DB is trusted. External
  modification flows through unchecked. Explicit trust assumption.

## Priority summary

| Priority | Gap | Effort |
|---|---|---|
| High | Assert bind parameter count | 1 line |
| High | Assert bind return codes | ~10 lines |
| Medium | Assert column names match struct fields | ~15 lines |
| Low | Retry cap on busy | ~5 lines |
| Low | query/query_all error discrimination | Interface change |
| Low | query_all truncation detection | Documentation or comptime |
