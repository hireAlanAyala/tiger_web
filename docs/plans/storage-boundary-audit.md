# Storage Boundary Audit

What the framework actually owns at the storage boundary, what's hardened,
and what's not. Based on responsibilities defined in `storage-boundary.md`.

## 1. SQL-to-struct mapping

**What we own:** translating between Zig types and SQLite column types.

### Hardened

- `assert_column_count` — asserts SELECT column count == struct field count
  on the first row. Catches added/removed columns or fields immediately.
- `read_column` integer range assertions — `assert(val >= 0)` and
  `assert(val <= maxInt(T))` on every integer read. Catches truncation.
- `read_column` UUID blob size — `assert(column_bytes == 16)`. Catches
  schema corruption or wrong column.
- `read_column` NULL UUID assertion — `assert(blob_ptr != null)`. Crashes
  on NULL UUID rather than reading garbage.
- `read_column` text length — `assert(len <= array.len)` for fixed `[N]u8`
  fields. Catches oversized text before buffer overflow.
- `read_column` slice rejection — `@compileError` on `[]const u8`. Forces
  fixed-size arrays, avoiding dangling pointer bugs.
- `read_column` packed struct — reads backing integer, range-checks, bitcasts.
- `read_column` unsupported type — `@compileError` catch-all. No silent
  misinterpretation.
- `bind_param` unsupported type — same `@compileError` catch-all on writes.

### Gaps

- **Column order is convention, not verified.** `read_row` maps column 0 to
  field 0, column 1 to field 1, etc. If the SELECT column order doesn't match
  the struct field declaration order, data silently maps wrong. The column
  *count* is checked but the column *names* are not.
  - **Fix:** `assert_column_names` — at the same point we check count, also
    check `sqlite3_column_name(stmt, i)` matches the struct field name (or a
    declared alias). Comptime field names are free; the SQLite call is one
    string comparison per column on the first row only.

- **bind_param doesn't check param count.** If the SQL has 3 placeholders
  but the args tuple has 2, SQLite silently binds NULL to ?3. No assertion
  catches this.
  - **Fix:** After `bind_params`, assert `sqlite3_bind_parameter_count(stmt)`
    equals `args tuple length`. One comparison per query.

- **bind_param doesn't check bind return codes.** Every `sqlite3_bind_*`
  call discards its return code with `_ =`. A bind failure (wrong type, out
  of range) would be silent.
  - **Fix:** Assert `rc == SQLITE_OK` after every bind call.

- **query/query_all silently return null on any non-row result.** The caller
  can't distinguish "not found" from "prepare failed" from "step returned
  SQLITE_BUSY". All are `null`.
  - **Consider:** Returning a tagged result (`.not_found`, `.error`) instead
    of bare `?T`. This matches the `StorageResult` pattern the old interface
    uses. Low priority — the typed interface is new and callers are simple.

- **query_all doesn't detect truncation.** If the query returns more rows
  than `max`, `assert(result.len < max)` will fire. But this is a crash, not
  a graceful limit. The SQL should always have `LIMIT max` but nothing
  enforces that.
  - **Consider:** Comptime scan for `LIMIT` in the SQL string, or document
    that `query_all` asserts if the result exceeds `max`.

- **No assertion that `[N]u8` text columns are valid UTF-8.** `read_column`
  copies raw bytes from SQLite. If the database contains invalid UTF-8 (from
  a bug or external write), it flows through unchecked. `input_valid` checks
  inbound data, but nothing checks outbound reads.
  - **Low priority.** SQLite stores what we wrote. If we validated on write
    (input_valid does), reads should be clean. Only matters if external tools
    modify the database.

## 2. Framework invariants (prefetch/execute lifecycle)

**What we own:** the ordering guarantees between prefetch and execute.

### Hardened

- `prefetch` asserts `self.prefetch_result == null` — catches double-prefetch
  without a commit between them.
- `commit` reads `self.prefetch_result.?` — crashes if commit called without
  prefetch (the optional is null, `.?` panics).
- `commit` calls `defer self.reset_prefetch()` — guarantees prefetch cache is
  cleared after every commit, preventing stale data leaking.
- `commit` calls `defer self.invariants()` — structural cross-check after
  every commit.
- `begin_batch`/`commit_batch` wraps process_inbox — one SQLite transaction
  per tick, one fsync.
- Server calls prefetch then commit in strict sequence — no interleaving
  between connections within a tick.

### Gaps

- ~~**No assertion that prefetch doesn't write.**~~ DONE. ReadView
  enforces read-only at runtime. Scanner enforces prefetch SQL is
  SELECT at build time.

- ~~**No assertion that execute/handle doesn't read.**~~ DONE. WriteView
  only exposes execute(). Scanner enforces handle SQL is INSERT/UPDATE/DELETE
  at build time.

- **Handlers write through `apply_writes` dispatch, not directly.** Execute
  returns `ExecuteResult` with collected writes, and the dispatch loop applies
  them. This is good — handlers can't skip the transaction boundary. But
  nothing prevents a handler from calling `storage.put()` directly if it
  has access to the storage pointer.
  - **Low risk** while handlers go through `StateMachineType` dispatch. Higher
    risk as handlers move to the new API where they receive a `db` reference.

## 3. Availability behavior (StorageResult handling)

**What we own:** how the framework responds when storage returns non-ok.

### Hardened

- **busy → retry.** `prefetch` returns false on busy. Server keeps connection
  in `.ready` state, retried next tick. No data corruption.
- **corruption → panic.** `prefetch` calls `@panic("storage corruption")`.
  Correct — if the database is corrupt, crash immediately. Don't try to serve
  degraded data.
- **err → 503.** `commit` returns `message.MessageResponse.storage_error` on
  read errors, which renders as HTTP 503.
- **Fault injection exercises all three.** MemoryStorage's PRNG-driven
  busy/err faults hit every branch in the sim. Coverage marks link to test
  assertions.

### Gaps

- **No retry cap on busy.** If storage returns busy indefinitely, the
  connection stays in `.ready` forever. The idle timeout will eventually
  kill it, but there's no explicit "retried N times, give up" path.
  - **Already in todo.md** ("storage can retry forever on err, we should
    add an upper cap").

- **Write failures are treated differently per interface.** Old interface:
  writes don't fault (TigerBeetle convention — writes are infallible after
  prefetch). New typed interface: `execute()` returns `false` on error. No
  consistency between the two models for write failures.
  - **Clarify:** As handlers migrate to the new API, decide whether write
    failures are panics (TB convention) or returned errors (web convention).

- **No MemoryStorage fault injection on writes.** Per the TB convention,
  only reads fault. But the web use case is different — a database INSERT
  can fail (constraint violation, disk full). The sim never exercises
  write-path failures.
  - **Consider:** Adding write faults to MemoryStorage. This exercises a
    real failure mode that the current sim misses.

## 4. Input validation boundary

**What we own:** rejecting invalid data before it reaches storage.

### Hardened

- `input_valid` — exhaustive switch over all operations. Validates IDs > 0,
  string lengths in range, UTF-8 validity, reserved fields zeroed, NUL bytes
  rejected in text, enum values in range.
- `input_valid` runs before prefetch — invalid data never touches storage.
- NUL byte rejection in name_prefix — prevents SQLite `length()` truncation
  (documented with pair-assertion comment in SqliteStorage.list).
- Fuzzer generates ~10% random messages to exercise `input_valid` boundary.

### Gaps

- **input_valid is in state_machine.zig, not the framework.** It's
  domain-specific validation mixed into framework dispatch. As handlers move
  to annotations, input validation should move to the handler layer or
  become a comptime-verified contract.

- **No validation on the read path.** Data read from storage is trusted.
  If the database is modified externally (admin tool, migration bug, manual
  SQL), malformed data flows through. `read_column` asserts some invariants
  (integer range, blob size) but doesn't validate domain rules (name_len
  within bounds, flags padding zeroed).
  - **Low priority** per design doc — we trust the database. But worth
    noting as an explicit trust assumption.

## Summary: priority fixes

| Priority | Gap | Effort |
|----------|-----|--------|
| High | Assert bind parameter count matches SQL placeholders | 1 line |
| High | Assert bind return codes (rc == SQLITE_OK) | ~10 lines |
| Medium | Assert column names match struct field names | ~15 lines |
| ~~Medium~~ | ~~Read-only storage view for prefetch phase~~ | DONE — ReadView/WriteView in storage.zig |
| ~~Medium~~ | ~~Write fault injection in MemoryStorage~~ | N/A — MemoryStorage removed, faults at dispatch (app.zig) |
| Low | Retry cap on busy | ~5 lines |
| Low | query/query_all error discrimination | Interface change |
| Low | query_all truncation detection | Documentation or comptime |
