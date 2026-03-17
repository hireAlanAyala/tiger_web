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

The WAL is append-only — it grows proportional to the number of mutations over the server's lifetime. Without rotation, disk fills up.

The simplest approach: the operator stops the server, copies the database and WAL as a pair, then restarts. The WAL already handles recovery on startup (backward scan, ftruncate corrupt tail). No framework machinery needed.

```
snapshot_2026-03-16.db      ← database state at rotation time
tiger_web_2026-03-16.wal    ← mutations from that point forward
```

The snapshot and WAL segment are a self-contained pair. The replay tool restores the snapshot, then feeds WAL entries into `commit()`. No version tracking needed — the snapshot guarantees the database schema matches the code that wrote the WAL entries. The root checksum catches incompatible Message layouts.

Retention is an operator concern — `find /backups -mtime +30 -delete` or equivalent.

If the operational burden of stop+copy+restart becomes too high, framework-coordinated rotation (rotate between ticks, no downtime) is a future option. Design that when there's a real constraint, not before.

## Replay tool

Implemented in `replay.zig`. Three modes:

- **verify** — read forward, validate checksums and hash chain, report corruption
- **inspect** — human-readable dump with `--op`, `--operation`, `--user` filters
- **replay** — restore snapshot, feed WAL entries into prefetch/commit, optional `--trace` and `--stop-at`

The tool passes opaque Messages to the state machine — same code path as production. It doesn't interpret body bytes.

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

### WAL disabled state is silent

When the WAL disables itself on write failure, the server continues serving. The operator might not notice for hours that replay coverage has a gap. The tracer should surface "WAL disabled" as a gauge or health check endpoint so monitoring can alert on it.

### No cluster field

The `cluster` field is cheap insurance — one u128 that prevents replaying a staging WAL against a production database. We have 15 bytes of reserved space on Message. The cost is negligible and the protection is real. Not critical for single-server, but worth adding before the framework ships to multiple users.

## Status

### Implemented
- `checksum.zig` — Aegis128L MAC, matches TB's `vsr/checksum.zig`
- `wal.zig` — WAL writer with root entry, hash chain, backward scan recovery, ftruncate, graceful degradation
- `message.zig` — extern struct with `set_checksum()`, `valid_checksum_header()`, `valid_checksum_body()`, `valid_checksum()`
- `server.zig` — WAL integration (prepare + append after commit for mutations)
- `replay.zig` — replay tool with verify, inspect, replay modes; unit and E2E tested
- Stability tests with hardcoded checksums (checksum + root)

### Not yet implemented
- Checksum header-only coverage (planned improvement)
- Root as `.root = 0` Operation variant (planned improvement)
