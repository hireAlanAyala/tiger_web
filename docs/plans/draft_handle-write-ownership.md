# Handle write-ownership annotations

Small primitive for preventing dissolution of write authority. Annotations
on `[handle]` only — no other handler types, no extension to reads.

## Use case

Dissolution: scattered SQL writes to the same column across many handlers,
each enforcing its own preconditions, drifting over time. Standard
HTTP-framework failure mode. Today the framework has no structural
defense; this primitive adds one.

## Surface

Two comment annotations on `[handle]` functions:

```js
// [handle]
// writes: claims.status, claim_audit_log.*
export function claim_lifecycle(ctx, db) { ... }
```

```js
// [handle]
// shared_writes: claims.last_touched_at
export function reserve_management(ctx, db) { ... }
```

## Rule

For each column written anywhere in the codebase:

- **Undeclared anywhere:** unowned, freely writable. No enforcement.
- **In `writes:` of exactly one handler, in no `shared_writes:`:** exclusive. Any other writer is a build error.
- **In `shared_writes:` of every handler that writes it, in no `writes:`:** shared. Valid.
- **In both `writes:` and `shared_writes:`:** error (mixed mode).
- **In `shared_writes:` for some writers but not all:** error (incomplete shared declaration).

## Phases

- [ ] **Spec** — write `docs/internal/decision-write-ownership.md` covering the rule, error messages, edge cases (dynamic SQL, helpers in same file, tests, migrations, append-only inserts).
- [ ] **Scanner** — extend annotation_scanner.zig to parse `writes:` and `shared_writes:` from `[handle]` comments, build the column→handlers map, apply the rule.
- [ ] **Errors** — produce build errors that name both files, state the rule, and give the actionable fix. Three shapes:
  - **Undeclared write:** handler writes a column declared by another. Error names the writing handler, the writing site (file:line), the declared owner(s), and offers two fixes (declare in this handler, or remove the write).
  - **Mixed mode:** column is in `writes:` somewhere and `shared_writes:` somewhere. Error names both handlers and explains that a column must be exclusive everywhere or shared everywhere.
  - **Incomplete shared declaration:** column is in `shared_writes:` of some writers but a write site exists in a handler without the declaration. Error names the missing handler and the existing declarers, and offers two fixes (add the declaration, or remove the write).
- [ ] **Migration helper** — `tiger-web suggest-ownership` walks the codebase, emits suggested annotations based on current write sites.
- [ ] **Sharedness report** — CI artifact listing columns by writer count; non-blocking, informational.
- [ ] **Docs** — one-page guide with the four common patterns (single owner, shared timestamp, audit log, contested column resolved by consolidation).
- [ ] **Sample migration** — annotate the ecommerce-ts handlers as a worked example.

## Non-goals

- No append-only mode (use Semgrep).
- No value constraints (use handler logic).
- No hierarchical declarations.
- No reads annotation (existing SQL read/write declarations cover it).
- No extension to other annotation types ([worker], [cron], [route]).
- No internal-vs-external command distinction (use module exports).

## Done when

A handler that writes a column declared by another handler fails the build
with a specific, actionable error. A column shared by N handlers requires
all N to declare it; adding an N+1th writer is a build error until it
declares too. The annotation is a single comment line per handler.
