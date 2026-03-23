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

## What This Means for the Codebase

### Framework (framework/)
- ReadOnlyStorage: deny-list wrapper, no db-specific methods
- No MemoryStorage
- No query/query_all awareness
- No BoundedList (moves to user space or SqliteStorage)

### SqliteStorage (user space, storage.zig)
- Owns column name matching, bind assertions, pair assertions
- Owns query/query_all/execute interface
- Owns BoundedList, read_row, read_column
- These are SQLite features, not framework features

### MemoryStorage (user space or deleted)
- Not a framework concern
- If kept: example-specific test double for legacy SM tests
- If deleted: replaced by SqliteStorage(":memory:") + FaultWrapper

### Handlers (user space, handlers/)
- Call storage.query() because the configured db is SqliteStorage
- Use flat row types because that's how SqliteStorage maps results
- Coupled to SQLite — that's the user's choice, not the framework's

### FaultWrapper (framework/ or user space)
- Generic wrapper: FaultWrapper(Storage) adds PRNG-driven faults
- Delegates all methods to inner storage
- Returns busy/err based on probability before calling the real method
- Replaces MemoryStorage's fault injection role

## Decisions Made

| Decision | Why |
|----------|-----|
| Framework doesn't own storage | We don't own the disk |
| Storage is a type parameter | Comptime composition, no runtime dispatch |
| ReadOnlyStorage is deny-list | Can't enumerate all read methods on all dbs |
| No MemoryStorage in framework | Cargo-culted from TB, unnatural for our layer |
| Handlers use storage: anytype | Db interface is the user's choice |
| SQL safety lives in SqliteStorage | Column matching, bind checks are db-specific |
| Same type for prod and test | Real users use one db with different instances |
| FaultWrapper replaces MemoryStorage | Preserves interface, adds faults generically |
