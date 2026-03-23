# Database Configuration: The Framework Doesn't Own Storage

## The Revelation

We sit a layer above TigerBeetle. TigerBeetle owns the disk — it writes
raw bytes to sectors, controls the format, verifies checksums. We don't
own the disk. The user brings a database.

This has a deeper consequence than we initially realized: the framework
should have no opinion on what the database is, what interface it exposes,
or how queries are written. The database is a type parameter. The framework
wraps it for access control and passes it through.

## What the Framework Owns

The framework owns the **pipeline**, not the storage:

1. **Phase separation** — prefetch is read-only, execute can write.
   Enforced at compile time by ReadOnlyStorage wrapper.
2. **Ordering** — prefetch before execute, one message at a time.
   Enforced by the SM lifecycle.
3. **Transactions** — begin_batch/commit_batch wraps the tick.
4. **Cross-cutting** — auth, tracer, followup, invariants.
5. **Handler validation** — correct signatures at comptime.

The framework does NOT own:
- What methods the database has
- What query language handlers use
- How results are mapped to types
- What safety assertions the database provides

## How a User Configures a Database

The database is a Zig type passed to ServerType:

```zig
const Server = ServerType(App, IO, SqliteStorage);
```

That's it. SqliteStorage is a struct with methods. The framework wraps it
in ReadOnlyStorage for prefetch and passes it to handlers. Handlers call
whatever methods the storage type exposes:

```zig
// Handler written for SQLite:
pub fn prefetch(storage: anytype, msg: *const Message) ?Prefetch {
    return .{ .product = storage.query(ProductRow, "SELECT ...", .{msg.id}) };
}

// Handler written for an ORM:
pub fn prefetch(storage: anytype, msg: *const Message) ?Prefetch {
    return .{ .product = storage.find("products", msg.id) };
}
```

The framework doesn't know which pattern the handler uses. It doesn't
parse, validate, or translate queries. It's a passthrough with phase
enforcement.

## ReadOnlyStorage: Deny-List, Not Allow-List

The wrapper blocks known write methods. Everything else passes through.
This is the opposite of our earlier approach (forwarding an explicit
allow-list of read methods).

Why deny-list:
- The framework can't enumerate all possible read methods on all
  possible databases. An allow-list would need to be extended for
  every new db type.
- Write methods are a small, known set: execute, put, update, delete,
  insert, begin, commit, rollback.
- If a db has a read method the framework doesn't know about, it should
  work. If a db has a write method the framework doesn't know about,
  the handler can still call it — but that's the user's choice to
  bypass phase separation, not a framework bug.

## Production vs Test: Same Type, Different Instance

A real user doesn't have two database implementations. They have one
database with two connection modes:

```zig
// Production:
const storage = try SqliteStorage.init("data.db");

// Test:
const storage = try SqliteStorage.init(":memory:");
```

Same type, same interface, same handlers. The framework never knows
the difference.

For fault injection in sim tests, a thin wrapper adds PRNG-driven
busy/error returns around the real database:

```zig
var inner = try SqliteStorage.init(":memory:");
var storage = FaultWrapper(SqliteStorage).init(&inner, prng);
```

FaultWrapper preserves the interface. Handlers can't tell.

## Error Signatures: ?T, Not StorageResult

The old storage interface returned `StorageResult` — an enum with five
variants: `ok, not_found, err, busy, corruption`. This was over-specified
for a framework that doesn't own the storage.

The framework cares about one thing: **did the storage cooperate?**
The handler cares about two things: **did I get data, or didn't I?**

The typed SQL interface already encodes this correctly:
- `query(T, sql, args) → ?T` — got a row, or didn't
- `query_all(T, max, sql, args) → ?BoundedList(T, max)` — got rows, or didn't

`null` means "no result" — not found, busy, error, corruption. The handler
doesn't know which, and it doesn't need to. For prefetch, null means "I
can't proceed" — the SM retries or skips. For execute, the handler got
what it got and decides from there.

This simplifies fault injection to one signal: **return null sometimes.**
No need to distinguish busy from err from corruption at the framework level.
The PRNG rolls, and if it hits, the read returns null. The handler sees null,
returns null from prefetch, the SM treats it as busy. One type, one signal,
one injection point.

StorageResult survives inside SqliteStorage as an internal type — it helps
SqliteStorage decide whether to retry, log, or panic based on the SQLite
error code. But it doesn't cross the handler boundary. Handlers see `?T`.

This means:
- Handler prefetch returns `?Prefetch` (null = storage didn't cooperate)
- Handler handle receives non-null Prefetch (framework guarantees it)
- Fault injection returns null from ReadView methods
- No StorageResult in the framework, no StorageResult in handler signatures

## Why MemoryStorage Was Wrong

MemoryStorage was a TigerBeetle pattern we cargo-culted. TigerBeetle
builds MemoryStorage because they own the storage layer and need to
inject sector-level faults (corruption, misdirected writes, torn pages).
Their MemoryStorage and real Storage implement the same raw-bytes
interface because TB defined both sides.

We don't own the storage layer. Our "storage" is a user-provided
database. Building a hash-map-based test double with a completely
different interface, then trying to make handlers work with both, was
an unnatural problem. No real framework user would have a hash map
backend and a SQL backend for the same app.

MemoryStorage moves out of the framework. It becomes either:
- An example-specific test double (the ecommerce app's concern)
- Deleted entirely (replaced by SQLite :memory: + FaultWrapper)

## Why Handlers Don't Use Raw SQL Anymore (and Then Do Again)

We went through this evolution:

1. **Legacy methods** (get, list, search) — both backends implement them.
   Works but the framework is opinionated about storage methods.

2. **Raw SQL** (query, query_all) — handlers write SQL directly.
   Clean for SQLite, impossible for MemoryStorage. Blocked the dispatch
   wiring because the sim couldn't run handlers.

3. **DB-agnostic interface** — considered but leads to query builders
   and ORMs. The framework shouldn't be a database abstraction.

4. **Storage is a passthrough** — handlers call whatever the configured
   db provides. The framework wraps it for access control, nothing more.
   Handlers written for SQLite use SQL. The framework doesn't care.

The resolution: handlers DO use raw SQL, because their configured db is
SQLite. The framework doesn't know or care that it's SQL. It sees
`storage: anytype` and wraps it. If the user configured Postgres instead,
handlers would write Postgres SQL. If they configured an ORM, handlers
would call ORM methods. The framework is uninvolved.

## MemoryStorage Is a Configurable DB, Not a Framework Concern

MemoryStorage isn't deleted. It's just another database the user can
configure — same as SQLite or Postgres. The framework doesn't care
which one is configured.

MemoryStorage has ReadView. It has get/list/search methods. Handlers
written for MemoryStorage call those methods. Handlers written for
SQLite call query(). Different db, different handler code. The framework
is uninvolved in this choice.

For the ecommerce example: production uses SQLite. The 1:1 local
equivalent is `SqliteStorage(":memory:")` — same type, same interface,
same handlers. This is what the sim/fuzz/benchmark use.

MemoryStorage survives as an option for users who want a zero-dependency
in-memory backend with fault injection built in. It has its own ReadView,
its own methods. The framework treats it identically to any other db.

## What This Means for the Codebase

### Framework (framework/)
- ReadView pattern: Storage types define their own read-only view
- `assertReadView(Storage)` — comptime check that Storage exports ReadView
- FaultWrapper(Storage) — generic PRNG fault injection around any db
- No db-specific method awareness (no query, no get, no BoundedList)

### SqliteStorage (user space, storage.zig)
- Owns column name matching, bind assertions, pair assertions
- Owns query/query_all/execute interface
- Owns BoundedList, read_row, read_column
- Defines ReadView exposing query/query_all + legacy reads
- These are SQLite features, not framework features

### MemoryStorage (user space, memory_storage.zig)
- A configurable db option, not framework infrastructure
- Defines ReadView exposing get/list/search
- Has built-in PRNG fault injection (busy/err on reads)
- Handlers written for MemoryStorage call its interface directly

### Handlers (user space, handlers/)
- Call storage.query() because the configured db is SqliteStorage
- Use flat row types because that's how SqliteStorage maps results
- Coupled to SQLite — that's the user's choice, not the framework's

### Fault Injection (framework/, at dispatch boundary)
- Fault injection wraps ReadView at the dispatch boundary in HandlersType
- Not a separate storage type — the storage is clean, the handler is clean
- The Handlers interface wraps ReadView in FaultReadView before passing to handler
- FaultReadView returns null from read methods based on PRNG probability
- One signal (null), one injection point (ReadView), one mechanism (PRNG)
- Production: Handlers passes raw ReadView (no faults)
- Sim: Handlers passes FaultReadView wrapping ReadView

### Ecommerce Example (sim/fuzz/benchmark)
- Switches from MemoryStorage to SqliteStorage(":memory:")
- Handlers use SQL — same code path as production
- FaultWrapper adds sim-time faults around the real SQLite calls

## Decisions Made

| Decision | Why |
|----------|-----|
| Framework doesn't own storage | We don't own the disk |
| Storage is a type parameter | Comptime composition, no runtime dispatch |
| Storage defines its own ReadView | Framework can't enumerate all read methods |
| MemoryStorage is a db option, not framework | It's a user choice, same as SQLite |
| Handlers use storage: anytype | Db interface is the user's choice |
| SQL safety lives in SqliteStorage | Column matching, bind checks are db-specific |
| Same type for prod and test | Real users use one db with different instances |
| Fault injection at dispatch boundary | Wraps ReadView, returns null, one signal |
| ?T not StorageResult at handler boundary | Framework cares about cooperated-or-not, not why |

## Implementation Status

### Done (committed)
- Design doc (this file)
- ReadView concept and assertReadView in read_only_storage.zig
- Handler dispatch switch in app.zig (TigerBeetle-style)
- PrefetchCache tagged union in app.zig
- HandlersType interface for SM parameterization
- Write/ExecuteResult moved to module-level state_machine.zig
- SM parameterized on (Storage, Handlers)
- All handlers have pub const Context
- resolve_credential/apply_auth_response made pub on SM

### In Stash (27 compile errors, needs next session)
- ReadView on SqliteStorage (written, needs MemoryStorage removal from fuzz/sim)
- ReadView on MemoryStorage (written)
- SM prefetch/commit using Handlers interface
- enum support in read_column
- undefined instead of zeroes in read_row_mapped

### Not Started
- FaultReadView — PRNG fault injection wrapping ReadView at dispatch boundary
- Migrate handlers from StorageResult to ?T return pattern
- Switch sim/fuzz/benchmark from MemoryStorage to SqliteStorage(":memory:")
- Delete old SM prefetch/execute dispatch (~800 lines)
- Update extract_cache for new SM shape (sidecar path)
- Wire handler dispatch into server process_inbox
