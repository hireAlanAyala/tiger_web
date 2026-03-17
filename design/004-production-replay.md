# Design 004: Production Replay

## Problem

Sim tests are fully reproducible — a PRNG seed determines all inputs, faults, and ordering. Production has none of that. When a bug hits, we can't reproduce it because we don't have the sequence of operations or the state they ran against.

TigerBeetle gets production replay for free through consensus replication — the WAL records every operation in order, and any replica can replay the full history to reach the same state. We don't have replication, but the prefetch/commit architecture gives us the same single entry point for all state changes.

## Design

An append-only WAL records every committed mutation as a fixed-size `Message`. The framework owns the WAL, coordinates rotation with database snapshots via hooks, and provides a replay tool. The database is the authority — the WAL is a diagnostic notebook.

### Two layers

Every database uses some form of WAL + replay for crash recovery. Postgres has WAL archiving + base backups. MySQL has redo log + binlog. SQLite has WAL mode. LiteFS streams SQLite WAL frames for replication.

These all operate at the **physical layer** — page-level changes. They tell you *what* changed but not *why*.

Our WAL operates at the **logical layer** — application-level Messages. It records "user X called create_product with this body at this timestamp." This is the layer physical WALs can't give you.

Both layers coexist. The physical layer (SQLite WAL, LiteFS, pg_basebackup) handles crash recovery and replication. The logical layer (our WAL) handles replay, debugging, auditing, and migration testing. They don't compete — they serve different purposes.

This is the same split MySQL has: the redo log (physical, ring buffer, crash recovery) and the binlog (logical, append-only, replication and PITR).

### Entry format

Each entry is a fixed-size 784-byte `Message` (extern struct, no padding):

| Field | Type | Purpose |
|-------|------|---------|
| `checksum` | u128 | Aegis128L over header+body (everything after this field) |
| `checksum_body` | u128 | Aegis128L over body region only |
| `parent` | u128 | Previous entry's checksum (hash chain) |
| `id` | u128 | Entity ID |
| `user_id` | u128 | Identity of the user who initiated the operation |
| `op` | u64 | Sequential counter, monotonically increasing |
| `timestamp` | i64 | Wall clock from `set_time()` at commit |
| `body` | [672]u8 | Typed event payload (Product, OrderRequest, etc.) |
| `operation` | Operation | Which handler ran (enum, 1 byte) |
| `reserved` | [15]u8 | Reserved for future use |

The `operation` field determines the body's type. Access through `body_as(T)` with runtime tag assertion.

### Hash chain

Each entry's `parent` field is the previous entry's `checksum`. Reading forward from the root, you can verify the entire chain — any inserted, deleted, or reordered entry breaks the chain. The WAL is a tamper-evident ledger.

```
root (op 0)  →  entry 1  →  entry 2  →  entry 3  →  ...
  checksum=C0    parent=C0    parent=C1    parent=C2
                 checksum=C1  checksum=C2  checksum=C3
```

### Root entry

Op 0 is a root entry following TigerBeetle's `Header.Prepare.root()` pattern. The root has operation byte 0 (not a valid Operation variant) and all-zero fields. Its checksum is fully deterministic — same code always produces the same root.

On recovery, if the root checksum doesn't match what this code produces, the WAL was written by an incompatible version. A stability test with a hardcoded expected checksum catches any accidental changes.

### Two checksums

Following TigerBeetle's pattern, each entry has two checksums:

- `checksum_body` — Aegis128L MAC over the body region
- `checksum` — Aegis128L MAC over everything after the checksum field (header bytes + body)

`set_checksum()` computes body first, then header (which includes `checksum_body`). This means `checksum` transitively covers the body.

Recovery uses `valid_checksum_header()` (one Aegis pass over header+body) to quickly find valid entries during backward scan. The replay tool uses `valid_checksum()` (both passes) for full verification.

### Recovery

On startup, `Wal.init()` either creates a new file (writes root, starts at op 1) or recovers an existing one:

1. Verify root checksum matches this code's root (version check)
2. Scan backwards from the last complete entry
3. Find the last entry with a valid header checksum
4. Resume the hash chain from that entry (set `op` and `parent`)
5. `ftruncate` the corrupt tail so new appends follow cleanly

The root is verified before the scan, so the scan always finds at least one valid entry (`else unreachable`).

### Graceful degradation

If a write fails (disk full, IO error), the WAL disables itself and logs a warning. The server continues serving. The WAL is secondary to the database — it never takes down the primary.

The server checks `wal.disabled` before calling `prepare()`/`append()`. Once disabled, the WAL stays disabled for the lifetime of the process. Restart to re-enable.

## Rotation and snapshots

### The problem

The WAL is append-only — it grows proportional to the number of mutations over the server's lifetime. Without rotation, disk fills up.

### Framework-coordinated rotation

The framework owns the tick loop and the single-writer constraint. It knows exactly when it's safe to rotate — between ticks, when no batch is in progress. The user can't get the timing wrong because the framework controls when rotation happens.

```
tick loop:
    process_inbox()
    commit_batch()
    wal.append()
    ...
    maybe_rotate()          ← framework decides when
        hooks.backup()      ← user defines what "backup" means
        wal.close()
        wal.open_new()      ← fresh root, op 1
```

### Backup and restore hooks

The framework provides the timing. The user provides the database operations:

| Hook | When | Who calls it | Default |
|------|------|-------------|---------|
| `backup` | WAL rotation, between ticks | Framework (tick loop) | `sqlite3_backup` to paired file |
| `restore` | Before replay | Framework (replay tool) | Copy snapshot over working database |

The hooks are the DB-agnostic boundary. The framework never touches the database directly. SQLite users get working defaults. Users who swap to Postgres swap the hooks.

### Snapshot + WAL segment pairing

After rotation, a snapshot and WAL segment form a self-contained pair:

```
snapshot_2026-03-16.db      ← database state at rotation time
tiger_web_2026-03-16.wal    ← mutations from that point forward
```

The snapshot carries the schema and the data at the point of rotation. The WAL segment contains the mutations recorded against that exact schema by that exact code version. They match by construction — the framework coordinated both sides in a single sequence between ticks.

This eliminates the need for version tracking on Messages. The replay tool doesn't interpret body bytes itself — it feeds opaque Messages into `commit()` through the same code path as production. The state machine knows how to interpret its own body bytes. The snapshot guarantees the database schema matches.

### No version field needed

In a pure event sourcing system, the event log is the authority and the replay tool must deserialize every entry independently. That requires version tracking — each entry must be self-describing so the tool knows which struct layout to use.

Our system is different. The database is the authority, not the events. The replay tool restores a snapshot first, then feeds Messages into `commit()`. It never deserializes the body — the state machine does. Since the snapshot was captured at the same time as the WAL segment, the code that reads the body is the same code (or compatible code) that wrote it.

The root checksum is sufficient for version detection. If the Message layout changes (field reordering, size change), the root checksum changes, and `Wal.init()` rejects the old file. This prevents appending incompatible entries. For replay, the pairing handles it — wrong snapshot + wrong WAL can't happen because the framework coordinates both.

### Retention

Old snapshot+WAL pairs can be archived or deleted based on the user's retention policy. The framework doesn't impose a policy — it provides the rotation mechanism and lets the operator decide how long to keep history.

## Replay tool

A generic binary that works for any application built on the framework:

1. Calls `restore_hook()` to restore the paired snapshot
2. Reads WAL entries forward from op 1, verifying checksums and hash chain
3. Feeds each Message into `commit()` through the normal prefetch/execute path

The tool doesn't know what a Product or Order is. It passes opaque Messages to the state machine — the same code path as production. For visibility, the state machine's own logging and tracing shows what each operation did.

Optional modes: stop at a specific op number, filter by operation type, enable trace logging for per-operation detail.

Not yet implemented.

## Why not a ring buffer?

TigerBeetle uses a fixed-size ring buffer. Entries wrap and old entries are overwritten. This is correct for TB — they need a recovery window, not a history. Once an entry is committed across the cluster and checkpointed, the WAL slot can be reused.

We use append-only because the replay history is the feature. A ring buffer would destroy exactly the thing we're building — debugging, auditing, migration testing all depend on entries surviving long enough to be paired with a snapshot and replayed.

The rotation mechanism gives us the same operational property as a ring buffer (bounded disk usage) without losing history. Old segments are archived or deleted by explicit operator decision, not silently overwritten.

## Why not pure event sourcing?

In pure event sourcing, the event log is the authority. Materialized views (the database) are derived from it. If the database is corrupt, rebuild from events.

We invert this. The database is the authority. The WAL is secondary. This means:

- WAL write failures disable the WAL, not the server
- The WAL doesn't need fsync — the database handles durability
- Recovery truncates corrupt WAL entries — the database is still correct
- No version tracking needed — the snapshot+WAL pair is self-consistent
- The system works without the WAL at all (sim tests pass `null`)

The diagnostic benefits of event sourcing (replay, auditing, debugging) are preserved. The operational burden (making the event log durable and the single source of truth) is avoided.

## Divergences from TigerBeetle

### Deliberate — reinforced by this design

| Divergence | TB | Ours | Why |
|-----------|-----|------|-----|
| File structure | Ring buffer, fixed size, wraps | Append-only, grows with rotation | Replay history is the feature; rotation bounds disk usage |
| File location | Zones embedded in single data file | Separate `.wal` file | DB-agnostic — backup hooks can't work if WAL is inside the database |
| Redundancy | Dual header copies, 16-case recovery table | Single copy, backward scan | Snapshot is our redundancy; database is the authority |
| Remote repair | VSR protocol fetches from other replicas | Corrupt tail is truncated | Single server; database has the correct state |
| Entry scope | Every prepare (reads and writes) | Mutations only | Reads don't change state; replay skipping them is correct |
| Fsync | Storage layer provides durability guarantees | No fsync, kernel flushes | Diagnostic notebook; database handles durability |
| Graceful degradation | WAL failure is fatal | WAL disables, server continues | WAL is secondary; database is the authority |

### Structural — could be closer

| Divergence | TB | Ours | Impact |
|-----------|-----|------|--------|
| Header/body separation | Separate zones on disk | Single 784-byte entry | Recovery reads full entry; negligible at our scale |
| Sector alignment | 4KB aligned, Direct I/O | No alignment, buffered I/O | Can't use O_DIRECT; doesn't matter for diagnostic log |
| Checksum coverage | `checksum` covers header only (240 bytes) | `checksum` covers header+body (768 bytes) | Planned fix — see "Planned improvements" |
| Entry size | Variable (`size` field, padded to max) | Fixed 784 bytes | Wastes space for void-body operations; only log mutations so minimal |
| Root operation | `.root` enum variant | Byte 0, outside enum | Planned fix — see "Planned improvements" |

### Missing fields — not needed

| Field | TB purpose | Our status |
|-------|-----------|------------|
| `version` / `release` | Identifies code version that produced entry | Not needed — snapshot+WAL pairing handles version compatibility |
| `cluster` | Prevents cross-cluster confusion | Not implemented. Low risk for single-server |
| `command` | Message type (prepare, reply, ping) | Not needed — all entries are committed mutations |
| `view` / `replica` / `commit` / `epoch` | VSR consensus protocol | N/A — single server, no consensus |
| `request` / `request_checksum` / `client` | Idempotency and reply matching | Not needed — diagnostic replay, not recovery |
| `checkpoint_id` | Binds prepare to checkpoint | N/A — no checkpointing |
| Checksum padding fields | Future u256 support | Not needed |

## Planned improvements

Two things TigerBeetle's design does genuinely better that we should adopt:

### Checksum should cover header only

TB's `checksum` covers 240 bytes of header. Body integrity is independently verified by `checksum_body`. The two checksums cover different regions — they're complementary, not redundant.

Ours covers header+body (768 bytes). This means `valid_checksum_header()` does a full-entry hash — there's no way to validate just the header without also hashing the body. The two checksums are nearly redundant. We lose the ability to verify header integrity (op, parent, timestamp) without trusting the body, and recovery hashes more bytes than necessary.

Fix: change `checksum` to cover only the bytes between the checksum field and the body (the header region). Update `valid_checksum_header()` to be a true header-only check. Update stability tests. This makes the two checksums independent — `checksum` for the header, `checksum_body` for the body — matching TB's design.

### Root should be a real Operation variant

TB has `.root` as a proper `Operation` enum variant. It's type-safe, shows up in exhaustive switches, can't collide with anything.

Ours uses operation byte 0, which is outside the `Operation` enum. If anyone adds an `Operation` variant with value 0, the root becomes ambiguous and version detection silently breaks. It's a latent bug.

Fix: add `.root = 0` to the `Operation` enum. Handle it in every switch (the compiler enforces this). The root entry becomes type-safe and self-documenting.

## Known risks

### Backup hook failure leaves a broken pair

The framework rotates the WAL and calls `backup_hook()` in a single sequence between ticks. But what happens when the backup hook fails? The WAL has already rotated — the old segment is closed, the new one is open. If the snapshot wasn't captured, the old segment has no paired snapshot and the new segment starts from an unrecorded state.

Options: roll back the WAL rotation on hook failure (complex — the old file may already be moved/archived), treat hook failure as fatal (too aggressive for a diagnostic system), or accept the gap and log a loud warning. The last option is consistent with graceful degradation — but the operator must know about it. This error path needs to be designed and tested.

### Backup hook blocks the tick loop

`sqlite3_backup` can take seconds or longer for a large database. During that time, the tick loop is stalled — no requests processed, no connections accepted, no timeouts checked. TigerBeetle would never block the tick loop for an unbounded operation.

Options: run the backup in a subprocess or background thread (breaks single-threaded model), use SQLite's incremental backup API (bounded per-step, but complicates the hook interface), or schedule rotation during a low-traffic window (operational, not architectural). The hook interface should document the stall and let the operator choose an appropriate implementation.

### WAL disabled state is silent

When the WAL disables itself on write failure, the server continues serving. The operator might not notice for hours that replay coverage has a gap. The tracer should surface "WAL disabled" as a gauge or health check endpoint so monitoring can alert on it.

### Replay tool is unbuilt and untested

The WAL writer is tested (create, recover, hash chain, truncation, corruption). But nothing tests the read-forward-and-replay path — hash chain verification during forward scan, checksum validation of every entry, the interaction with `prefetch()`/`commit()` during replay. Until the replay tool exists and is tested, we don't know if the format actually works for replay. The WAL is write-only until proven otherwise.

### No cluster field

The `cluster` field is cheap insurance — one u128 that prevents replaying a staging WAL against a production database. We have 15 bytes of reserved space on Message. The cost is negligible and the protection is real. Not critical for single-server, but worth adding before the framework ships to multiple users.

## Open questions

- **Rotation policy**: When should the framework rotate? Fixed interval (daily)? File size threshold? Op count? Configurable?
- **Backup hook failure**: Roll back rotation, accept the gap, or something else?
- **Backup stall**: Incremental backup, subprocess, or documented operational constraint?

## Status

### Implemented
- `checksum.zig` — Aegis128L MAC, matches TB's `vsr/checksum.zig`
- `wal.zig` — WAL writer with root entry, hash chain, backward scan recovery, ftruncate, graceful degradation
- `message.zig` — extern struct with `set_checksum()`, `valid_checksum_header()`, `valid_checksum_body()`, `valid_checksum()`
- `server.zig` — WAL integration (prepare + append after commit for mutations)
- Stability tests with hardcoded checksums (checksum + root)
- Unit tests: create/recover, root determinism, hash chain, truncation recovery, corrupt tail recovery, version mismatch detection

### Not yet implemented
- Checksum header-only coverage (planned improvement)
- Root as `.root = 0` Operation variant (planned improvement)
- Rotation and snapshot coordination
- Backup/restore hooks
- Replay tool
