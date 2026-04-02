# Concurrent Pipeline — Stage 3

> N sidecars, all active. Multiple requests in-flight. Throughput
> scales linearly with sidecar count.

## Core insight: slot index = connection index

TB's pipeline queue uses ordered slots. Op N goes to slot N. No
mapping. Our equivalent: pipeline slot 0 → bus connection 0,
slot 1 → connection 1. When a RESULT arrives on connection[2],
it goes to pipeline slot 2. No routing table, no request_id
mapping. Direct pairing.

## Architecture

```
tiger-web -Dsidecar-count=4 -- node dispatch.js

HTTP → Server (1 core) → Bus (4 connections)
         ↓               ├── Connection[0] → Sidecar A (1 core)
   4 pipeline slots       ├── Connection[1] → Sidecar B (1 core)
         ↓               ├── Connection[2] → Sidecar C (1 core)
      SQLite              └── Connection[3] → Sidecar D (1 core)
```

| Sidecars | Throughput (TypeScript) | Cores | RAM |
|---|---|---|---|
| 1 | ~25K req/s | 2 | ~60MB |
| 2 | ~50K req/s | 3 | ~110MB |
| 4 | ~100K req/s | 5 | ~210MB |

## Architecture matches TB

```
TB:   prefetch (async) → execute (sync, exclusive) → compact (async)
Ours: prefetch (async) → handle (sync, exclusive) → render (async)
```

Both have a fast synchronous exclusive step between two async steps.
Both serialize writes while overlapping reads. Both are single-threaded
with no locks — just a stage gate. TB uses io_uring for storage IO,
we use sidecar CALL/RESULT for handler IO. Both callback-driven,
non-blocking.

## TB patterns applied

### 1. Reads overlap, writes are exclusive

TB prefetches the next op while the current one executes. Our
pipeline stages:

```
Slot 0: [route]→[prefetch]→[handle]→[render]
Slot 1:          [route]→[prefetch]→[  wait  ]→[handle]→[render]
Slot 2:                   [route]→[prefetch]→[  wait  ]→...
```

- **route, prefetch, render:** IO-bound (sidecar CALL). Multiple
  slots can be in these stages simultaneously. Each slot's CALL
  goes to its paired connection.
- **handle:** CPU-bound (SQLite write). Exclusive — only ONE slot
  at a time. Others stall in `.handle_wait` until the lock is free.
  TB's pattern: `commit_stage == .execute` is exclusive.

SQLite in WAL mode allows concurrent reads (prefetch) but one
writer (handle). This is the natural fit.

### 2. Async state machine with resume

Each pipeline slot has its own `commit_stage`. When it hits an
async stage (sidecar CALL in-flight), it returns. The server
processes other slots. When the RESULT arrives:

```
sidecar_on_frame(ctx, connection_index=2, frame)
  → pipeline_slots[2].resume()
  → commit_dispatch(slot=2) continues from where it left off
```

TB's `commit_dispatch_resume()` pattern — the callback resumes
the specific slot, not a global dispatch.

### 3. No routing tables

The `active` concept from Stage 2 disappears. Stage 2: one active
connection, `send_message()` routes to it. Stage 3: all connections
active, each slot calls `bus.send_to_connection(slot_index, msg)`.

`send_message()` still works for Stage 2 compatibility (routes to
`connections[active]`). Stage 3 pipeline slots bypass it.

## Pipeline slot struct

```zig
const PipelineSlot = struct {
    stage: CommitStage,
    connection: ?*Connection,     // HTTP connection being served
    msg: ?App.Message,
    cache: ?Handlers.Cache,
    identity: ?CommitOutput.Identity,
    pipeline_resp: ?PipelineResponse,
    pending_since: u32,
    client: SidecarClient,        // per-slot protocol state machine
    connection_index: u8,         // paired bus connection (== slot index)
};
```

Server changes from scalar fields to array:
```zig
// Stage 2 (current):
commit_stage: CommitStage,
commit_connection: ?*Connection,
commit_msg: ?App.Message,
// ... 7 fields

// Stage 3:
pipeline_slots: [connections_max]PipelineSlot,
handle_lock: ?u8,  // which slot holds the write lock (null = free)
```

Memory per slot: ~768KB (SidecarClient.state_buf) + ~1KB (commit
state). 4 slots ≈ 3MB total. Acceptable.

## Server changes

### process_inbox

Currently dispatches one connection to one pipeline. Stage 3:

```zig
fn process_inbox(server: *Server) void {
    for (server.connections) |*conn| {
        if (conn.state != .ready) continue;
        // Find a free pipeline slot.
        const slot = server.find_free_slot() orelse continue;
        slot.stage = .route;
        slot.connection = conn;
        slot.pending_since = server.tick_count;
        server.commit_dispatch(slot);
    }
}
```

Multiple connections dispatch to multiple slots in the same tick.

### commit_dispatch(slot)

Same state machine as today, but per-slot:

```zig
fn commit_dispatch(server: *Server, slot: *PipelineSlot) void {
    switch (slot.stage) {
        .route => {
            // CALL "route" on slot.connection_index
            slot.client.call_submit(
                bus.send_to_connection_fn(slot.connection_index),
                ...
            );
        },
        .handle => {
            // Exclusive write lock.
            if (server.handle_lock != null) {
                slot.stage = .handle_wait;
                return;
            }
            server.handle_lock = slot.connection_index;
            // Execute synchronous SQLite write.
            ...
            server.handle_lock = null;
            // Wake next waiting slot.
            server.wake_handle_waiters();
        },
        ...
    }
}
```

### sidecar_on_frame routing

Connection index IS slot index. Direct dispatch:

```zig
fn sidecar_on_frame(ctx, connection_index: u8, frame: []const u8) void {
    const slot = &server.pipeline_slots[connection_index];
    slot.client.on_frame(frame, ...);
    if (!slot.client.is_handler_pending()) {
        server.commit_dispatch(slot);
    }
}
```

No mapping. No lookup. The connection index selects the slot.

### sidecar_on_close failover

If sidecar on connection[2] crashes:

```zig
fn sidecar_on_close(ctx, connection_index: u8, reason) void {
    const slot = &server.pipeline_slots[connection_index];
    // If this slot had an in-flight request, 503 it.
    if (slot.stage != .idle) {
        slot.connection.?.set_response(503_response);
        slot.reset();
    }
    // Slot is disabled until sidecar reconnects + READY.
    // Remaining N-1 slots handle all traffic.
    // Supervisor respawns the dead process.
}
```

### Round-robin dispatch

```zig
fn find_free_slot(server: *Server) ?*PipelineSlot {
    // Start from next_slot to distribute evenly.
    var i: u8 = 0;
    while (i < connections_max) : (i += 1) {
        const idx = (server.next_slot + i) % connections_max;
        const slot = &server.pipeline_slots[idx];
        if (slot.stage == .idle and
            server.sidecar_connections_ready[idx])
        {
            server.next_slot = (idx + 1) % connections_max;
            return slot;
        }
    }
    return null; // All slots busy or disconnected.
}
```

## SQLite serialization

SQLite WAL mode:
- **Concurrent reads:** Multiple slots in .prefetch read simultaneously.
  Each gets a consistent snapshot. No coordination needed.
- **Exclusive writes:** One slot in .handle at a time. `handle_lock`
  guards entry. Other slots stall in `.handle_wait`.
- **begin_batch / commit_batch:** TB batches N ops into one commit.
  We can do the same: `begin_batch` before the first .handle in a
  tick, `commit_batch` after the last. All writes in one tick share
  one SQLite transaction.

## What doesn't change

- Handler interface (same pure functions)
- Wire format, CALL/RESULT protocol
- Bus transport (already supports N connections)
- Supervisor (already manages N processes)
- READY handshake (already per-connection)
- SimIO (already supports N client slots)

## Implementation order

1. **PipelineSlot struct** — extract these fields from server.zig
   (lines 125-141) into a PipelineSlot struct:
   - `commit_stage` → `slot.stage`
   - `commit_connection` → `slot.connection`
   - `commit_msg` → `slot.msg`
   - `commit_pipeline_resp` → `slot.pipeline_resp`
   - `commit_cache` → `slot.cache`
   - `commit_identity` → `slot.identity`
   - `commit_dispatch_entered` → `slot.dispatch_entered`
   - `commit_pending_since` → `slot.pending_since`
   Server gets `pipeline_slots: [1]PipelineSlot` (single slot,
   backward compatible). All `server.commit_*` refs become
   `slot.*` (~30 sites in commit_dispatch and helpers).
2. **Per-slot commit_dispatch** — dispatch takes a slot pointer, not
   server scalars. Stage 2 uses slot[0] only.
3. **Per-slot SidecarClient** — each slot has its own client. Client
   calls send_to_connection(slot.connection_index).
4. **sidecar_on_frame routing** — connection_index selects slot.
5. **handle_lock** — exclusive write stage. handle_wait + wake.
6. **process_inbox multi-dispatch** — find_free_slot, round-robin.
7. **begin_batch / commit_batch** — batch writes per tick.
8. **Sim tests** — N SimSidecars, concurrent requests, verify
   throughput scales and handle_lock serializes correctly.
9. **Benchmark** — verify throughput scales linearly with N.

## Dependencies

| Dependency | Required for |
|---|---|
| Multi-connection bus | ✓ DONE (Stage 2) |
| Per-connection READY state | ✓ DONE (Stage 2) |
| Supervisor N processes | ✓ DONE (Stage 2) |
| PipelineSlot struct | Foundation |
| Per-slot SidecarClient | Concurrent CALLs |
| handle_lock | SQLite write serialization |
| Round-robin dispatch | Load distribution |

## Related

- docs/internal/architecture-sidecar-seams.md
- docs/plans/handler-timeout.md
