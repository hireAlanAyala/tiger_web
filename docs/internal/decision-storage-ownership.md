# Storage Ownership: Framework Doesn't Own the Database

## Decision

The framework is parameterized on storage at comptime. It doesn't own
the database, doesn't choose the backend, doesn't know the SQL dialect.
The user brings a database. The framework talks to it through a type
parameter.

## Why

TigerBeetle owns the full path from state machine to disk — raw bytes,
sectors, checksums, replication. Their storage layer IS the product.

We sit a layer above. The user brings SQLite (or Postgres, or anything
with SQL). The database is a dependency we configure, not infrastructure
we build. Testing our SQL against a hash map doesn't find real bugs —
it proves `INSERT` does the same thing as `hashmap.put()`.

## Consequences

| Decision | Consequence |
|---|---|
| Storage is a comptime type parameter | No runtime dispatch, no interface vtable |
| Storage defines its own ReadView/WriteView | Framework can't enumerate all read/write methods |
| Fault injection at dispatch boundary (app.zig) | Not in storage — wraps ReadView, returns null |
| ?T not StorageResult at handler boundary | Framework cares about cooperated-or-not, not why |
| Same type for prod and test | `SqliteStorage("data.db")` vs `SqliteStorage(":memory:")` |
| MemoryStorage removed | All tests use SqliteStorage(:memory:), faults at dispatch level |

## Composition root

`app.zig` binds all type parameters once. Nobody else imports storage.zig
or picks a storage backend. Same pattern as TigerBeetle's vsr.zig.

```zig
pub const Storage = @import("storage.zig").SqliteStorage;
pub const SM = StateMachineType(Storage);
```
