# Design 006: TB Patterns Worth Revisiting

None of these are critical — the system works correctly with all of them. The
question for each is whether the ceremony is justified for a CRUD web app vs
a replicated financial database.

## Tick model

Every 10ms the server scans all 128 connection slots whether or not anything
happened. TB needs tick-based processing for consensus determinism — every
replica must process the same operations in the same tick.

We don't have replicas. We could process connections immediately when epoll
signals them instead of polling on a fixed timer. The tick buys us batching
writes into one fsync per tick, but we could batch on "any connection became
ready" instead of a fixed interval.

## StorageResult.busy

SQLite in WAL mode on a single thread never returns busy. The entire busy
path — prefetch returning false, server retrying next tick — exists exclusively
for sim test fault injection. It's test infrastructure disguised as production
architecture.

Worth asking whether a simpler fault injection mechanism would give the same
test coverage with less plumbing through the state machine.

## Fixed-size everything

Product names capped at 128 bytes, descriptions at 512, lists at 50 items.
TB needs this because allocation failure in a financial database is
unacceptable — every buffer must be pre-allocated.

For a CRUD web app, a truncated product description is a user-visible bug.
Worth asking whether the rendering layer could use an arena allocator per
request without compromising the state machine's fixed-size discipline.

## No std.fmt in hot paths

Hand-rolled `format_u32`, `format_u128`, price formatting. TB does this
because they format millions of log entries per second across replicas.

Our hot path renders one HTML page per request. `std.fmt` would be fine and
would eliminate several hundred lines of hand-rolled formatters.
