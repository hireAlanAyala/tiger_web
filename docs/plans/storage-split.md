# Storage Split — Separate Interface from SQLite Implementation

## Problem

`storage.zig` is 2,371 lines containing three things:

1. **The storage interface** — `ReadView`, `WriteView`, `query`,
   `execute`, `query_all`. What any storage backend must expose.
2. **The SQLite implementation** — statement cache, PRAGMAs, schema
   management, C bindings, `read_column`, `bind_params`. How SQLite
   specifically implements the interface.
3. **Legacy domain methods** — `get`, `put`, `list`, etc. Old API
   being migrated to the typed query interface.

These are mixed in one file. A framework user who wants a different
backend (PostgreSQL, in-memory for testing, mock for unit tests) has
to understand 2,371 lines of SQLite-specific code to know what to
implement.

## Why now

1. **The statement cache added SQLite-specific complexity.** FNV-1a
   hashing, `sqlite3_sql()` collision detection, `sqlite3_reset` —
   all invisible to the interface consumer.

2. **Domain constants are trapped in framework code.** `list_max`,
   `product_name_max`, `product_description_max` are in `message.zig`
   (framework) but are user-domain decisions. The storage split
   naturally moves domain constants to the App binding.

3. **The comptime buffer assertion couples domain to framework.**
   `list_max * product_card_rendered_max <= send_buf_max` is in
   message.zig but should be in the user's app — the user defines
   their list size, the framework defines the buffer size, the
   assertion bridges them.

4. **A second backend is coming.** Drawing the boundary now prevents
   the split from being a surprise refactor later.

## What changes

### Composition root (app.zig) — 1 line

```zig
// Before:
pub const Storage = @import("storage.zig").SqliteStorage;

// After:
pub const Storage = @import("storage_sqlite.zig").SqliteStorage;
```

Every other file uses `App.Storage` or receives storage as `anytype`.
Nothing else changes.

### File split

| New file | Contents | Lines (est.) |
|---|---|---|
| `storage_sqlite.zig` | SqliteStorage struct, init, deinit, statement cache, PRAGMAs, schema, C bindings, read_column, bind_params, legacy methods, tests | ~2,200 |
| `storage.zig` | Deleted — becomes storage_sqlite.zig |

The interface is implicit — defined by what the framework calls via
`anytype`. There's no explicit `StorageInterface` struct. The compiler
enforces the contract: if `storage_sqlite.zig` is missing a method the
framework calls, the build fails. Same as today. This follows TB's
pattern — no interface type, just comptime duck typing.

### Domain constants move to App

| Constant | From | To |
|---|---|---|
| `list_max` | message.zig | App-level (user's domain) |
| `product_name_max` | message.zig | App-level (user's domain) |
| `product_description_max` | message.zig | App-level (user's domain) |
| `collection_name_max` | message.zig | App-level (user's domain) |

The comptime buffer assertion moves to the App binding:
```zig
comptime {
    assert(App.list_max * App.product_card_rendered_max
        <= http.send_buf_max - http_response.header_reserve);
}
```

The framework provides `send_buf_max`. The user provides `list_max`
and the rendered row size. The compiler checks they fit.

### What does NOT change

- Handler code — handlers call `storage.query(T, sql, args)` via
  `anytype`. The concrete type is invisible.
- Server code — server calls `App.Storage` methods. The import path
  changes in app.zig, nowhere else.
- State machine — parameterized on `Storage` type. No change.
- Tests — sim tests, unit tests, fuzz tests all work because they
  construct `SqliteStorage` directly. The import path changes.
- Load test — exercises the full stack, doesn't import storage.

### Rename, don't restructure

The file is renamed, not reorganized internally. The legacy methods
stay in `storage_sqlite.zig` until the handler migration is complete.
No code is moved between files. One rename, one import path change.

## Implementation checklist

- [ ] Rename `storage.zig` → `storage_sqlite.zig` (git mv)
- [ ] Update `app.zig` import: `@import("storage_sqlite.zig")`
- [ ] Update any direct imports of `storage.zig` in tests
- [ ] Move `list_max` and domain constants to App binding
- [ ] Move comptime buffer assertion to App binding
- [ ] Verify all tests pass
- [ ] Verify load test passes
- [ ] Update CLAUDE.md file table

## What a second backend looks like

A new backend (e.g., `storage_postgres.zig`) implements the same
methods: `init`, `deinit`, `query`, `query_all`, `execute`, `begin`,
`commit`, `ReadView`, `WriteView`. The App binding changes one line:

```zig
pub const Storage = @import("storage_postgres.zig").PostgresStorage;
```

The compiler verifies the new backend has every method the framework
calls. No interface file, no vtable, no runtime dispatch. Comptime
duck typing — the same pattern TigerBeetle uses for IO (real IO vs
simulated IO).

## Risk

Low. The split is a rename + one import change. No logic moves. No
interfaces are extracted. The compiler catches any missing method. The
test suite (unit + sim + load) exercises every code path through the
storage layer.

The domain constant move is slightly more involved — `list_max` is
referenced in message.zig (ProductList struct sizing), handler code
(query limits), and the comptime assertion. All references need to
point to the App-level constant. The compiler catches any missed
reference.
