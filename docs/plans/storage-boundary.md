# Storage Boundary: Why We Depart from TigerBeetle

## We Sit a Layer Up

TigerBeetle owns the full path from state machine to disk — raw bytes,
sectors, checksums, replication. The storage layer IS the product.

We are a web framework. The user brings a database — SQLite today,
Postgres tomorrow — and we talk to it through SQL. The database is a
dependency we configure, not infrastructure we build.

```
TigerBeetle:   state_machine → storage (owned) → raw sectors
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ their problem

Tiger Web:     handler → framework → db.query(SQL) → user's database
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ our problem
                                                      ^^^^^^^^^^^ not ours
```

We trust the database executes SQL correctly. We do not trust that we
send the right SQL, interpret the response correctly, ask at the right
time, or handle the database being slow or unavailable.

## Where Our Bugs Live

1. **Handler logic.** Miscalculated inventory, missed dependent record
   in prefetch, incorrect state transition. Most real bugs live here.
2. **SQL-to-struct mapping.** Column count mismatch, wrong column order,
   type coercion, packed struct misreads. See storage-boundary-audit.md.
3. **Framework invariants.** Executing without prefetching, double
   commits, lost writes, connection lifecycle violations.
4. **Availability.** Database slow, returns errors, temporarily
   unavailable. Graceful degradation, not crash-and-burn.

## Why the Auditor Is User-Space

TigerBeetle's AccountingAuditor works because TigerBeetle IS the
domain. The auditor knows debits, credits, that they must balance.
It's deeply coupled to their business logic.

A framework-level auditor can only verify generic things: "create
returns what was created", "get returns what was previously created."
These are trivially true if the SQL is correct.

The moment an auditor becomes valuable — checking inventory conservation,
state transition validity, account balance constraints — it's checking
user domain logic. The framework can't know those invariants.

The auditor pattern is real and important, but it's a user-space
concern. The framework's job is to make it easy for users to write
their own auditor. See `simulation-testing.md` for the `[sim:*]`
annotation system that delivers this.

## Testing Strategy

| Risk | Owner | Strategy |
|---|---|---|
| Handler logic | User | `[sim:assert]` + `[sim:invariant]` (simulation-testing.md) |
| SQL-to-struct mapping | Framework | `assert_column_count`, bind assertions (storage-boundary-audit.md) |
| Framework invariants | Framework | Sim tests with fault injection (sim.zig), coverage marks |
| Availability | Framework | Fault injection at dispatch boundary (app.zig fault_prng) |

## The Departure

TigerBeetle's philosophy: "test the boundary you don't trust, by
simulating the thing on the other side of it."

For TigerBeetle, that boundary is the disk. They simulate sectors,
faults, and latency because that's where their bugs hide.

For us, that boundary is the database interface. We simulate
availability and timing. We don't simulate SQL correctness because
we trust the database — the same way TigerBeetle trusts the CPU.

Same principles. Different boundary. Correct departure.
