# Decision: Worker architecture

## Context

Workers handle background tasks (payment processing, image resizing,
external API calls). A handler dispatches a worker; the worker runs
asynchronously on the sidecar; completion flows through the normal
pipeline (prefetch → handle → render).

## Key decisions

**WAL is the queue.** No `_worker_queue` table. The WAL is the single
writer — mutable tables can be corrupted with `sqlite3`. Dispatch
entries are recorded atomically with handler SQL writes. Pending
index is rebuilt from WAL on recovery.

**No retries.** Automatic retries add hidden state and hide failures.
Dead resolution (deadline expiry) is the minimum mechanism for
liveness. Every dispatch resolves: success, failure, or dead.

**Separate SHM region.** Request handling (data plane) is bounded
latency. Worker dispatch (control plane) is unbounded latency. Mixing
them in one SHM region violates the boundedness principle. Two regions,
same binary protocol, independent lifecycles.

**WorkerDispatch doesn't reuse ShmBus.** ShmBus has IoUring coupling,
message pool allocation, and a callback model designed for the HTTP
pipeline. WorkerDispatch inlines ~30 lines of SHM protocol (same
extern struct layout, same CRC convention) with raw futex syscalls.

**Two-phase completion.** When a worker completes: Phase 1
(process_worker_completions) injects into the sidecar pipeline with
`worker_completes_op` tagged on the ShmDispatch Entry. Phase 2
(execute_shm_writes) records the WAL completion entry and resolves the
pending index — atomic with the completion handler's SQL writes.

**Completion handlers are normal handlers.** Same annotations
(`[route]`, `[prefetch]`, `[handle]`, `[render]`), same pipeline. The
scanner suppresses the missing-match check for completion operations.
The scanner enforces `ctx.worker_failed` is checked in the handle body.

**Backpressure is comptime.** `max_in_flight_workers` (16) is a
comptime constant. Static allocation. The developer declares the bound.
When all slots are full, dispatch stops — entries stay pending in WAL.

**Completion handlers use 1-RT without prefetch.** The server sends
a handle_render CALL with the worker result as body and zero row
sets. The sidecar's handle function receives empty `ctx.prefetched`.
Idempotency uses conditional SQL (`WHERE status != 'paid'`), not
prefetch-then-check. This is simpler and correct under concurrent
completion delivery — the SQL WHERE clause is the atomic guard.

**Crash can lose dispatches.** No fsync. The application recovers
orphans via schema-level checks. See `decision-wal-dispatch-crash.md`.

**`entry_flags` as parallel discriminator.** The WAL header uses
`entry_flags` (normal/completion/dead_dispatch) alongside `operation`.
The operation field identifies the handler; the flags field identifies
the entry type. This avoids consuming Operation enum values for
framework-internal concepts.

**Workers are reusable.** Any handle can dispatch any worker. The
scanner generates one global `worker` object with a method per
`[worker]` annotation.
