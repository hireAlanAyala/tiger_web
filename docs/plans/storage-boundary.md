# Storage Boundary: Why We Depart from TigerBeetle

## We Sit a Layer Up

TigerBeetle owns the full path from state machine to disk. It writes raw bytes
to sectors, controls the format, verifies checksums on read-back, and repairs
corruption from peer replicas. The storage layer *is* the product — every byte
on disk is TigerBeetle's responsibility.

We are a web framework. We do not own the disk. The user brings a database —
SQLite today, Postgres tomorrow — and we talk to it through SQL. The database
is a dependency we configure, not infrastructure we build. This is a
fundamental difference in where the trust boundary sits.

```
TigerBeetle:   state_machine → storage (owned) → raw sectors
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ their problem

Tiger Web:     handler → framework → db.query(SQL) → user's database
               ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ our problem
                                                      ^^^^^^^^^^^ not ours
```

We trust that the database executes SQL correctly. We do not trust that *we*
send the right SQL, that we interpret the response correctly, that we ask at
the right time, or that we handle the database being slow or unavailable.

## What the Storage Interface Is Actually For

The generic `Storage` interface exists so the framework can be parameterized on
its backing store at comptime. This gives us two concrete implementations:

**MemoryStorage** — hash maps, no SQL, no disk. Exists for three reasons:

1. **Speed.** Fuzz tests run thousands of full request cycles per second. SQLite
   overhead would make simulation testing impractical. The sim needs to be fast
   enough that we can throw millions of random operations at the system in
   seconds.

2. **Determinism.** No query planner, no filesystem, no kernel scheduling. Given
   the same PRNG seed, MemoryStorage produces the same results every time.
   Failures are reproducible by replaying the seed.

3. **Fault injection.** MemoryStorage can return "busy" or "error" on any
   operation, controlled by the PRNG. This is our equivalent of TigerBeetle's
   sector corruption and latency simulation. It lets the sim exercise every
   error path in the framework without needing a real database that misbehaves
   on command.

**SqliteStorage** (or any real database) — the production path. Used in
integration tests and the actual server. The framework makes no assumptions
about it beyond the interface contract.

## What MemoryStorage Is NOT

MemoryStorage is not an oracle for the database. We do not run both
MemoryStorage and SQLite side-by-side and compare their outputs.

In TigerBeetle, MemoryStorage vs real Storage catches storage-layer bugs:
sector alignment, checksum failures, torn writes, misdirected data. They own
that code, so there are real bugs to find there.

For us, comparing MemoryStorage to SQLite would only prove that our SQL
`INSERT` does the same thing as `hashmap.put()`. We already know that. The SQL
is trivial — the interesting bugs live elsewhere.

## Where Our Bugs Actually Live

The risks specific to a framework that sits above the database:

1. **Handler logic.** A handler that miscalculates inventory, misses a
   dependent record in prefetch, or applies a transfer incorrectly. This is
   where most real bugs will be.

2. **SQL-to-struct mapping.** Column count mismatches, wrong column order, type
   coercion errors, packed struct misreads. Bugs at the translation boundary
   between SQL rows and Zig structs.

3. **Framework invariants.** Executing without prefetching. Double commits.
   Lost writes. Connection lifecycle violations. The ordering and lifecycle
   guarantees the framework promises to handlers.

4. **Availability behavior.** How the framework behaves when the database is
   slow, returns errors, or is temporarily unavailable. Graceful degradation,
   not crash-and-burn.

## Why the Auditor Doesn't Belong in the Framework

TigerBeetle's AccountingAuditor works because TigerBeetle *is* the domain. The
auditor knows what a debit is, what a credit is, that they must balance, that
pending transfers expire. It's a second implementation of their specific
accounting rules. It's not generic — it's deeply coupled to their business
logic.

A framework-level auditor can only verify generic things:

- A create returns the thing that was created
- A get returns what was previously created
- A delete means a subsequent get returns nothing
- List results are consistent with prior creates and deletes

These are trivially true if the SQL is correct. They are "does the database
work" assertions dressed up as an oracle. Not worth the maintenance cost.

The moment an auditor becomes valuable — when it checks that inventory
transfers preserve totals, that orders can't be fulfilled twice, that account
balances never go negative — it's checking *user domain logic*. The framework
can't know those invariants. They belong to the application.

This means the auditor pattern is real and important, but it's a user-space
concern, not a framework concern. The framework's job is to make it easy for
users to write their own auditor and run it through the sim.

## What We Test and How

Each risk has a different testing strategy. The framework owns the harness and
the primitives. The user owns the domain-specific verification.

### Framework-owned: simulation with MemoryStorage

The sim exercises the full request pipeline — HTTP parsing, routing, prefetch,
execute, render — with PRNG-driven fault injection. MemoryStorage returning
busy/err forces every error path in the framework to fire. Coverage marks link
these paths to test assertions.

This is the direct equivalent of TigerBeetle's SimIO injecting partial sends
and disconnects. We're not testing storage correctness — we're testing that
the framework handles storage *misbehavior* correctly.

The current busy/err faults are a start. The sim should grow to cover:

- Latency variation (prefetch takes multiple ticks sometimes)
- Partial batch failures (3 of 5 operations succeed)
- Transient errors followed by recovery
- Operations that succeed but the result isn't visible yet

These don't test the database. They test that *our framework* degrades
gracefully when the database doesn't cooperate.

### Framework-owned: SQL-to-struct boundary assertions

`assert_column_count` catches column/struct mismatches at runtime. Round-trip
integration tests write a known struct through SQL, read it back, assert field
equality. These are targeted, not exhaustive — a handful of tests per type, not
a full oracle comparison.

### User-owned: domain auditor via framework primitives

The framework exposes the building blocks for users to write their own
simulation tests with domain-specific oracles. The primitives:

1. **Workload generator.** A PRNG-driven operation sequencer that the user
   configures with their operations and relative weights. "80% reads, 10%
   creates, 5% updates, 5% deletes" — the framework generates random sequences
   and feeds them through the pipeline.

2. **MemoryStorage with fault injection.** The fast, deterministic,
   PRNG-faultable backing store. The user's handlers run against it exactly as
   they would in production, except the database can misbehave on command.

3. **Auditor interface.** A hook point where the user plugs in their reference
   model. Before each operation, the auditor predicts the expected result.
   After each operation, it asserts the actual result matches. The framework
   drives the loop; the user defines what "correct" means.

4. **Seed-based reproducibility.** Every sim run is parameterized by a single
   u64 seed. When the auditor catches a mismatch, the user replays the exact
   same sequence to debug it. No flaky tests, no "it only happens sometimes."

The pitch to users: "bring your domain auditor, we'll run it through 10 million
random operation sequences with fault injection." The framework owns the
harness. The user owns the oracle.

## Why This Departure Is Correct

TigerBeetle's philosophy isn't "test the disk." It's "test the boundary you
don't trust, by simulating the thing on the other side of it."

For TigerBeetle, that boundary is the disk. They simulate sectors, faults, and
latency because that's where their bugs hide.

For us, that boundary is the database interface. We simulate availability and
timing because that's where *our* bugs hide. We don't simulate SQL correctness
because we trust the database to do its job — the same way TigerBeetle trusts
the CPU to execute instructions correctly.

The oracle pattern applies, but at a different layer. Our oracle is the
auditor, not a second storage implementation. Our fault injection targets
availability, not data integrity. Our simulation tests framework invariants,
not storage invariants.

Same principles. Different boundary. Correct departure.
