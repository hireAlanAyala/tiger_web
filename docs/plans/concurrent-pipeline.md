# Concurrent Pipeline — Stage 3

> N sidecars, all active. Multiple requests in-flight. Throughput
> scales linearly with sidecar count.

## What this is

Stage 3 of sidecar scaling. Requires a concurrent pipeline in the
server — multiple `commit_stage` slots, each paired with a bus
connection. Round-robin dispatch across N sidecars.

## Architecture

```
tiger-web --sidecar-count=4 -- node dispatch.js

HTTP → Server (1 core) → Bus (4 connections)
         ↓               ├── Connection[0] → Sidecar A (1 core)
   N pipelines            ├── Connection[1] → Sidecar B (1 core)
         ↓               ├── Connection[2] → Sidecar C (1 core)
      SQLite              └── Connection[3] → Sidecar D (1 core)
```

| Sidecars | Throughput (TypeScript) | Cores | RAM |
|---|---|---|---|
| 1 | ~25K req/s | 2 | ~60MB |
| 2 | ~50K req/s | 3 | ~110MB |
| 4 | ~100K req/s | 5 | ~210MB |

## What changes from Stage 2

**Server (concurrent pipeline):**
- `commit_stage` becomes array of pipeline slots
- `process_inbox` dispatches to any free pipeline slot
- Each pipeline slot owns its commit_msg, commit_cache, etc.
- `commit_dispatch` takes a pipeline index
- Sidecar callbacks route to correct pipeline slot

**SidecarClient:**
- N clients (one per pipeline slot) — Stage 2 has one
- Each client paired with a bus connection

**Bus:**
- No change — already supports N connections
- `set_active` concept may evolve to round-robin dispatch

**SQLite:**
- Transactions serial (begin/commit one at a time)
- But prefetch + render overlap across pipelines

**Dispatch strategy:**
- Round-robin: `next_index = (next_index + 1) % connected_count`
- Skip disconnected sidecars
- If all busy, request waits in .ready until a pipeline frees
- Background CALLs use the same dispatch

## Dependencies

| Dependency | Required for |
|---|---|
| Multi-connection bus | ✓ DONE (Stage 2) |
| Per-connection READY state | ✓ DONE (Stage 2) |
| Multiple commit_stage slots | Concurrent pipeline |
| N SidecarClients | Per-slot protocol state |
| Round-robin dispatch | Load distribution |

## Related

- docs/internal/architecture-sidecar-seams.md
- docs/plans/background-dispatch.md (uses same bus)
- docs/plans/network-storage.md (concurrent pipeline design)
