# Design 007: Replay Tool

## Problem

The WAL writer exists and is tested. But the WAL is write-only — nothing can read it, verify it, or replay it. Until the replay tool exists, we don't know if the format actually works for its intended purpose.

## Goals

1. Verify WAL integrity without a database (checksums, hash chain)
2. Replay a WAL segment against a snapshot to reproduce exact state
3. Inspect what happened — which operations, in what order, with what results
4. Generic — works for any application built on the framework, not just tiger_web

## Non-goals

- Real-time tailing of a live WAL (the server has the file open with `O_APPEND`)
- Diffing two WAL segments
- Modifying or rewriting WAL entries
- Replaying across versions (snapshot+WAL pair must be from the same deployment)

## CLI

Single binary, mode selected by first argument:

```
tiger-replay verify <wal-file>
tiger-replay replay <wal-file> <snapshot-file>
tiger-replay inspect <wal-file> [options]
```

### verify

Read the WAL file forward. Validate every entry:

- Root checksum matches this code's root
- Every entry's `valid_checksum()` passes (header and body)
- Hash chain is intact (`entry.parent == previous.checksum`)
- Op numbers are sequential and monotonically increasing
- No gaps, no duplicates

Output: entry count, file size, first/last op, first/last timestamp. Exit 0 on success, exit 1 on any failure with a description of what broke and at which op.

No database needed. No state machine. Pure file + checksum validation.

### replay

Restore a snapshot, then replay the WAL segment through the state machine:

1. Copy snapshot file over the working database path (SQLite file copy)
2. Open the WAL, verify root
3. Read entries forward from op 1
4. For each entry: `state_machine.set_time(entry.timestamp)`, `state_machine.prefetch(entry)`, `state_machine.commit(entry)`
5. Assert every `commit()` succeeds — if any entry produces an unexpected status, panic with the op number and the status

Replay is silent on success. Output is either "replay complete, N entries" or a crash at the first divergence. This follows TigerBeetle's approach — recovery either succeeds or panics. There's no "show me what happened" mode; that's what `--trace` and `inspect` are for.

With `--trace`, the tracer's per-operation logging is enabled — the same logging production uses. This is how you debug a specific operation: replay with trace, read the log.

The binary is parameterized on the storage backend: `ReplayType(Storage)`. The default binary uses `SqliteStorage`. If someone swaps databases, they build their own replay binary with their own storage backend — same pattern as `ServerType(IO, Storage)`. The type system enforces that the storage backend and the replay tool match. No shell hooks, no runtime configuration.

Options:
- `--stop-at=<op>` — stop after replaying this op number
- `--trace` — enable per-operation trace logging

### inspect

Read the WAL and print human-readable entry summaries without replaying:

```
op=1  t=1710583200  create_product    id=a1b2c3...  user=d4e5f6...
op=2  t=1710583200  transfer_inventory id=a1b2c3...  user=d4e5f6...
op=3  t=1710583201  create_order      id=f7e8d9...  user=d4e5f6...
```

This mode does deserialize the body (to show the operation and id), but only reads fields that are in the Message header — `operation`, `id`, `user_id`, `op`, `timestamp`. It doesn't interpret the body bytes beyond what the Message struct provides.

Options:
- `--filter=<operation>` — only show entries matching this operation (e.g., `create_order`)
- `--after=<op>` — only show entries after this op number
- `--before=<op>` — only show entries before this op number
- `--user=<id>` — only show entries from this user_id
- `--json` — output as JSON lines (for piping to jq or other tools)

## Shared code

The replay tool reuses existing modules:

| Module | Used by | Purpose |
|--------|---------|---------|
| `message.zig` | All modes | Message struct, checksums |
| `checksum.zig` | All modes | Aegis128L verification |
| `wal.zig` | All modes | `read_entry()`, `root()` |
| `flags.zig` | All modes | CLI argument parsing |
| `state_machine.zig` | replay | `prefetch()`, `commit()` |
| `storage.zig` | replay | SQLite backend (default; user swaps via `ReplayType(Storage)`) |
| `auditor.zig` | replay tests | Independent reference model for correctness assertions |
| `tracer.zig` | replay | Trace logging |

### New code

| Component | Purpose |
|-----------|---------|
| `replay.zig` | Binary entry point, mode dispatch, forward reader |

The forward reader is trivial — `read_entry()` already exists in `wal.zig`, just call it with sequential offsets. No new data structures needed.

## Build integration

```zig
// build.zig — new step
const replay_exe = b.addExecutable(.{
    .name = "tiger-replay",
    .root_source_file = b.path("replay.zig"),
    .target = target,
    .optimize = optimize,
});
replay_exe.linkSystemLibrary("sqlite3");  // only for replay mode
replay_exe.linkLibC();
b.installArtifact(replay_exe);
```

Run with: `zig build run-replay -- verify path/to/file.wal`

## Testing

### Verify mode
- Write a WAL with known entries, verify passes
- Corrupt a single byte in an entry, verify reports the correct op and failure
- Truncate the file mid-entry, verify reports the truncation
- Corrupt the root, verify reports version mismatch
- Break the hash chain (swap two entries), verify reports the break

### Replay mode
- Write entries via state machine + WAL, replay and assert every commit succeeds
- Replay with `--stop-at` and check intermediate state
- Replay a WAL against the wrong snapshot — should panic at first divergence
- Replay with `--trace` and verify tracer output matches expected operations

### Inspect mode
- Write known entries, inspect output matches expected format
- Filter by operation, verify only matching entries shown
- Filter by user_id, verify only matching entries shown
- JSON output parses correctly

### Integration test (auditor-based)

The definitive test follows TigerBeetle's auditor pattern:

1. Create a state machine and an auditor
2. Run a sequence of mutations through the state machine, appending each to the WAL
3. Take a snapshot (copy the SQLite database)
4. Restore the snapshot into a fresh state machine
5. Replay the WAL segment — for each entry, call `commit()` and feed the response to the auditor
6. The auditor asserts correctness after every operation

No file comparison. No application-specific queries. The auditor is the oracle — same as in the fuzz tests. This reuses `auditor.zig` directly.

This test exercises the full pipeline: state machine → WAL writer → snapshot → restore → replay → auditor. If this passes, the system works.

## Open questions

- **`read_entry` visibility**: Currently `fn` (private) in `wal.zig`. The replay tool needs it. Options: make it `pub`, or add a `pub fn read_forward()` iterator that wraps it.
- **Exit codes**: Should verify/replay use distinct exit codes for different failure types (checksum failure vs chain break vs truncation)?
