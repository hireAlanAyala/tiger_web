# Database Migrations

SQLite is the authority. The WAL is a diagnostic notebook.

## Invariant: Additive Only

Schema changes are forward-rolling and additive:

- `CREATE TABLE`
- `ALTER TABLE ADD COLUMN`
- `UPDATE ... SET ... WHERE` (backfill)

No drops, no renames, no type changes. If a destructive change is
truly necessary, do it manually, outside the framework. The friction
is intentional.

## How It Works

Two pieces:

- **`schema.sql`** — the current schema, captured from prod after each
  deploy. Fresh databases load this on first startup via `@embedFile`.
- **`next_migration`** — a function pointer in `storage.zig`. `null`
  when there's nothing to migrate. Set to a function when the next
  deploy needs a schema change. Runs on every startup (prod and dev).

```
ensure_schema:
  if fresh database → load schema.sql, mark as initialized
  if next_migration set → run it
```

## Workflow

**During development:**

1. Write the migration function in `storage.zig`.
2. Set `next_migration` to point to it.
3. Update `schema.sql` to include the change.
4. Same commit — migration, schema, and application code together.
5. `zig build test` — tests create fresh databases from `schema.sql`
   and exercise the full stack.

**Deploy:**

6. Deploy the binary. `next_migration` runs against prod on startup.

**Post-deploy:**

7. Capture prod schema: `sqlite3 prod.db .schema > schema.sql`
8. Clean up formatting (SQLite's ALTER TABLE output is ugly).
9. Set `next_migration` back to `null`.
10. Commit.

## Examples

**Add a column:**

```zig
// storage.zig
const next_migration: ?*const fn (*c.sqlite3) void = &migrate_add_weight;

fn migrate_add_weight(db: *c.sqlite3) void {
    exec(db, "ALTER TABLE products ADD COLUMN weight_grams INTEGER NOT NULL DEFAULT 0;");
}
```

```sql
-- schema.sql (add weight_grams to the products table)
CREATE TABLE products (
    ...
    weight_grams INTEGER NOT NULL DEFAULT 0
);
```

**Replace a column** (rename `x` to `y`, or change semantics):

```zig
fn migrate_rename_x_to_y(db: *c.sqlite3) void {
    exec(db, "ALTER TABLE products ADD COLUMN y INTEGER NOT NULL DEFAULT 0;");
    exec(db, "UPDATE products SET y = x WHERE y = 0;");
}
```

Update application code to read/write `y`. Stop using `x`. It stays
in the table, inert.

## Why

- **No migration files.** One slot, one function, cleared after deploy.
- **No ordering conflicts.** Two developers both edit `storage.zig`
  and `schema.sql`. Normal git merge.
- **No untested migrations.** Tests create databases from `schema.sql`
  and exercise the full stack. Same code path as prod.
- **No expand-contract.** Changes happen on startup. No phase two.
- **No version chain.** No numbered history accumulating in the codebase.
- **Schema is always visible.** `schema.sql` shows exactly what prod
  looks like. Not reconstructed from migration history — captured
  directly.
