# Decision: Worker QUERY transport — SHM, not Unix socket

## Context

Workers can call `db.query()` during async execution. The QUERY/
QUERY_RESULT exchange needs a transport between the sidecar and
the server. Two options: reuse the worker SHM slot (bidirectional)
or use the existing Unix socket (SidecarBus).

## Decision: SHM

The QUERY exchange uses the same worker SHM slot as the CALL/RESULT.
The slot alternates between sidecar-writes (QUERY) and server-writes
(QUERY_RESULT). Seq counters track whose turn it is.

## Why not the Unix socket?

The socket path adds ~10µs per query (syscall overhead, kernel buffer
copy) vs ~1µs for SHM (mmap, no syscalls, no copies). Workers may
issue 1-10 queries per execution. The cumulative latency matters
because it extends the worker's slot occupancy — longer occupancy
means fewer concurrent workers, which affects dispatch throughput
when all 16 slots are in use.

Workers already have unbounded latency (external API calls), so
10µs per query is noise for a single worker. But under load with
16 concurrent workers each doing 5 queries, the socket path adds
800µs of total slot-occupancy time vs 80µs for SHM. At the margin,
this is the difference between fitting 16 workers or backing up.

## Why the complexity is acceptable

The bidirectional SHM exchange is complex for adapter authors —
they must track turns via seq counters. This is a one-time cost
per language adapter. The protocol spec documents the exchange
with a sequence diagram. The TS reference implementation shows the
polling pattern. The Zig server side (poll_completions) is decomposed
into handle_result and handle_query with clear assertions.

## Alternative considered: dedicated QUERY slots

A separate set of SHM slots for QUERY/QUERY_RESULT avoids the
bidirectional complexity. But it doubles the SHM memory for workers
and adds a second slot-type concept to the region layout. The
memory cost scales with max_in_flight_workers × frame_max × 2
(additional ~8MB for 16 slots). Not worth the simplification.
