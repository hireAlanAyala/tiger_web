# Production

## Environments: Local + Prod

No staging. Two environments: local development and production.

Staging solves one problem: "will this work in production?" This
system answers that question locally:

- **Real data.** Pull the prod database or WAL, test against it.
- **Same execution model.** Single-threaded, deterministic, same
  binary, same SQLite — local and prod are identical.
- **Migration testing.** Run the migration against a prod database
  copy locally. 13ms to verify.
- **Fault injection.** Sim tests with PRNG-driven faults are more
  thorough than staging traffic.

Staging would drift from prod (different data, timing, load), require
maintenance, and solve a problem already solved by deterministic
local testing.

## Deploy

Merge to main triggers deploy to a single VPS. One migration slot,
one deploy at a time. Sequential by construction — git merge order
is deploy order.

### Deployment steps

1. Stop the old binary.
2. Start the new binary.
3. `ensure_schema` runs the migration (if any) on startup.
4. Prepared statements validate the schema.
5. Server starts serving.

Downtime is the restart — milliseconds.

### Rollback

Start the old binary. Additive-only migrations mean the old code
works against the new schema — it doesn't know about new columns
and doesn't reference them.

### Schema migrations

See [database.md](database.md).

## Single VPS, Single Writer

The tick loop owns all database mutations. No concurrent writers,
no locks, no coordination. The VPS is the deployment target, SQLite
is the database, the binary is the single process. Everything is one.
