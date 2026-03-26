# Simulation testing — implementation spec

## What this is

An implementation spec for user-space simulation testing. Covers
the annotation system (`[sim:*]`), the reference model, assert
callbacks, invariants, shared predicates, scanner integration, and
delivery phasing. Ready to implement — all design decisions are
resolved with reasoning captured in the design exploration section.

## What this is not

- Not a framework internals spec. The framework's pipeline testing
  (prefetch/commit ordering, fault injection, HTTP framing) is
  separate. This spec covers user-space domain logic testing only.
- Not an API reference. The examples show the intended usage but
  exact function signatures may change during implementation.
- Not a testing tutorial. Assumes familiarity with property-based
  testing and reference model patterns. The testing paradigm origins
  section provides background for those new to the concepts.

## Problem

The framework tests its own pipeline (prefetch/commit ordering, fault
injection, HTTP framing) but cannot test user domain logic. A
cancel_order handler that forgets to restore inventory is invisible to
the framework — it's a domain bug, not a pipeline bug.

Hand-written scenario tests only cover what the developer thinks of.
The interleaved writes debugging session proved the cost: a test that
checked the wrong property passed for months and misdirected debugging
toward phantom infrastructure issues.

TigerBeetle solves this with a reference model: random operations
execute against the real system, each response is reconciled against an
independent model. We adapt this for a framework where users own the
domain logic.

## Annotations

Eight annotations total. Four run the app, four test it. The `sim:`
prefix is the boundary.

```
Production:    [route]  [prefetch]  [handle]  [render]
Simulation:    [sim:model]  [sim:attempt]  [sim:assert]  [sim:invariant]
```

| Annotation | Per-operation | Count | Receives |
|---|---|---|---|
| `[sim:model]` | no | exactly 1 | — |
| `[sim:attempt] .op` | yes | 1 per operation | model, random |
| `[sim:assert] .op` | yes | 1 per operation | model, req, status |
| `[sim:invariant]` | no | any number | model, db |

### What each annotation means

| Annotation | Description |
|---|---|
| `[sim:model]` | What does the world look like? A function returning the initial state — entity maps, counters, derived state. Called once at sim start. |
| `[sim:attempt] .operation` | What does a typical attempt at this operation look like? Given a random number generator and the current state of the world, produce a plausible input. Sometimes valid, sometimes not — the system should handle both. |
| `[sim:assert] .operation` | Given the current state of the world, was that the right answer? The operation just ran and returned a status. Does that status match what the world says should have happened? If it was correct, update the world to reflect what changed. |
| `[sim:invariant]` | Rules that must always remain true. Forget what just happened. Look at everything. Do the numbers add up? Are the relationships intact? Are things that should never change still the same? Has access to the DB for grounded checks that don't trust the model. |

### Relationship to production annotations

`[sim:assert]` is to `[handle]` what a judge is to a decision-maker.
Handle decides and writes. Assert observes the decision, checks it
against the model's state, and asserts correctness. Assert is not a
second implementation of handle — it doesn't compute outcomes, it
verifies them.

`[sim:invariant]` is the user-space equivalent of the framework's
`defer self.invariants()` pattern. The framework has tick-level
structural invariants (connection pool consistency, send buffer bounds).
The user has domain-level invariants (inventory conservation, terminal
permanence). Same pattern, different layer, promoted to an annotation
because the framework needs to discover and schedule it.

`[sim:attempt]` has no production analogue — nothing in the handler
pipeline generates inputs. The framework builds HTTP requests from
handler annotations. Attempt generates the body content.

`[sim:model]` has no production analogue — the production system's
state is the database. The model is an independent shadow of that state,
maintained by assert callbacks.

## File layout and colocation

Sim annotations live in handler files, after the production annotations:

```typescript
// handlers/cancel_order.ts

// [route] .cancel_order
// match POST /orders/:id/cancel
export function route(req) { ... }

// [prefetch] .cancel_order
export function prefetch(msg, db) { ... }

// [handle] .cancel_order
export function handle(ctx, db) { ... }

// [render] .cancel_order
export function render(ctx) { ... }

// [sim:attempt] .cancel_order
export function attempt(random, model) { ... }

// [sim:assert] .cancel_order
export function assert(model, req, status) { ... }
```

Model and invariants are cross-cutting — they live in separate files:

```
handlers/
  cancel_order.ts       — route, prefetch, handle, render, attempt, assert
  create_order.ts       — route, prefetch, handle, render, attempt, assert
  get_product.ts        — route, prefetch, handle, render (no sim)
  list_products.ts      — route, prefetch, handle, render (no sim)

tests/
  model.ts              — [sim:model]
  predicates.ts         — plain functions (terminal, pending)
  invariant/
    inventory.ts        — [sim:invariant]
    terminal.ts         — [sim:invariant]
    price_math.ts       — [sim:invariant]
```

Most operations won't have sim annotations. Only operations with
interesting state transitions, cross-entity side effects, or
conservation implications need `[sim:attempt]` and `[sim:assert]`.
A typical codebase: 4-8 of 24 handlers get sim annotations.

### Why colocation (reversed decision)

The earlier design exploration (attempt 3) rejected colocation: "test
code in production files crosses a boundary most developers expect to
be separate." That rejection assumed mandatory test code in every
handler with a central model class requiring the scanner to strip test
code from production builds.

The current design is different:
- `sim:` annotations are opt-in and sparse (4-8 handlers, not all 24)
- They're inert in production — the framework only invokes them during
  sim runs. No stripping needed.
- The developer sees the complete story of a high-risk operation in
  one file: what it does and how it's verified.
- The `sim:` prefix makes the boundary visible at a glance.

Cross-cutting pieces (model, invariants, predicates) can't colocate
because they don't belong to any operation. They live in separate files.

## Model

No `Model.declare`. The model is a function returning a plain object:

```typescript
// tests/model.ts

// [sim:model]
export function model() {
  return {
    product: new Map(),
    order: new Map(),
    counters: { inventory_created: 0 },
  };
}
```

The framework calls it once at sim start. The returned object is passed
to every attempt, assert, and invariant. Assert callbacks populate the
Maps. Invariant callbacks read them. The framework doesn't need a schema
declaration — it carries the object.

For auto-verification (model fields vs DB), the framework queries the
entity after each operation and compares every field that exists in both
the model entry and the DB row. Fields are discovered at runtime from
the first `.set()` call. Fields in the DB but not in the model produce
advisory warnings (not errors, since the model is intentionally a
subset).

TypeScript type inference on the return value provides autocomplete
without a declaration API.

## Shared predicates

Status predicates shared across assert callbacks and invariants.
Plain functions, not an engine, not annotated:

```typescript
// tests/predicates.ts
export const terminal = (s) =>
  s === "confirmed" || s === "failed" || s === "cancelled";
export const pending = (s) => s === "pending";
```

Used in both assert (to check transitions) and invariant (to check
permanence). If a new terminal status is added and the predicate isn't
updated, every operation that checks it fails in the sim.

These are deliberately not a DSL. A DSL was considered — declarative
`when: { order: { status: terminal } }, expect: "order_not_pending"`
tables. Rejected because:
- Simple operations (cancel) fit the table, but complex operations
  (complete_order with timeout + failure + inventory restore) can't
  be expressed without growing the DSL into a bad programming language.
- The code version is already short (12 lines per assert callback).
- The real win is the shared predicates, not the syntax.

## Complete example

```typescript
// tests/model.ts
// [sim:model]
export function model() {
  return {
    product: new Map(),
    order: new Map(),
    counters: { inventory_created: 0 },
  };
}
```

```typescript
// tests/predicates.ts
export const terminal = (s) =>
  s === "confirmed" || s === "failed" || s === "cancelled";
export const pending = (s) => s === "pending";
```

```typescript
// handlers/create_product.ts (sim section only)
// [sim:attempt] .create_product
export function attempt(random) {
  return {
    name: random.word(),
    price_cents: random.range(100, 10000),
    inventory: random.range(0, 200),
  };
}

// [sim:assert] .create_product
export function assert(model, req, status) {
  if (model.product.has(req.id)) {
    assert(status === "version_conflict");
    return;
  }
  assert(status === "ok");
  model.product.set(req.id, { ...req.body, version: 1, active: true });
  model.counters.inventory_created += req.body.inventory;
}
```

```typescript
// handlers/cancel_order.ts (sim section only)
import { pending } from "../tests/predicates";

// [sim:attempt] .cancel_order
export function attempt(random, model) {
  const id = random.pick(model.order.keys());
  if (!id) return null;
  return { id };
}

// [sim:assert] .cancel_order
export function assert(model, req, status) {
  const order = model.order.get(req.id);
  if (!order) { assert(status === "not_found"); return; }
  if (!pending(order.status)) { assert(status === "order_not_pending"); return; }
  assert(status === "ok");
  order.status = "cancelled";
  for (const item of order.items) {
    model.product.get(item.product_id).inventory += item.quantity;
  }
}
```

```typescript
// handlers/complete_order.ts (sim section only)
import { pending } from "../tests/predicates";

// [sim:attempt] .complete_order
export function attempt(random, model) {
  const id = random.pick(model.order.keys());
  if (!id) return null;
  return { id, result: random.pick(["confirmed", "failed"]) };
}

// [sim:assert] .complete_order
export function assert(model, req, status) {
  const order = model.order.get(req.id);
  if (!order) { assert(status === "not_found"); return; }
  if (!pending(order.status)) { assert(status === "order_not_pending"); return; }
  if (model.now >= order.timeout_at) {
    assert(status === "order_expired");
    order.status = "failed";
    for (const item of order.items) {
      model.product.get(item.product_id).inventory += item.quantity;
    }
    return;
  }
  assert(status === "ok");
  order.status = req.body.result === "confirmed" ? "confirmed" : "failed";
  if (order.status === "failed") {
    for (const item of order.items) {
      model.product.get(item.product_id).inventory += item.quantity;
    }
  }
}
```

```typescript
// handlers/create_order.ts (sim section only)
// [sim:attempt] .create_order
export function attempt(random, model) {
  const ids = [...model.product.keys()];
  if (ids.length === 0) return null;
  return {
    items: random.sample(ids, random.range(1, 3)).map(id => ({
      product_id: id, quantity: random.range(1, 10),
    })),
  };
}

// [sim:assert] .create_order
export function assert(model, req, status) {
  for (const item of req.body.items) {
    const p = model.product.get(item.product_id);
    if (!p || !p.active) { assert(status === "not_found"); return; }
    if (p.inventory < item.quantity) { assert(status === "insufficient_inventory"); return; }
  }
  assert(status === "ok");
  model.order.set(req.id, { status: "pending", items: req.body.items });
  for (const item of req.body.items) {
    model.product.get(item.product_id).inventory -= item.quantity;
  }
}
```

```typescript
// tests/invariant/inventory.ts
import { pending } from "../predicates";

// [sim:invariant]
export function invariant(model) {
  let shelf = 0, reserved = 0;
  for (const p of model.product.values()) shelf += p.inventory;
  for (const o of model.order.values()) {
    if (pending(o.status)) {
      for (const item of o.items) reserved += item.quantity;
    }
  }
  assert(shelf + reserved === model.counters.inventory_created);
}
```

```typescript
// tests/invariant/terminal.ts
import { terminal } from "../predicates";

// [sim:invariant]
export function invariant(model) {
  for (const o of model.order.values()) {
    if (terminal(o.status)) {
      assert(o.status === "confirmed" || o.status === "failed" || o.status === "cancelled");
    }
  }
}
```

## Assert patterns

Every assert callback follows the same shape: check model state
top-to-bottom, assert the expected status at each branch, update the
model only on success.

### Entity not found

Every operation that targets an entity by ID must handle missing. The
sim generates random IDs sometimes. The model knows whether the entity
exists.

```typescript
const order = model.order.get(req.id);
if (!order) { assert(status === "not_found"); return; }
```

### State transition guards

Operations that require a specific state must reject others. Both
cancel_order and complete_order share the `pending` predicate. The
transition rule lives in one place.

```typescript
if (!pending(order.status)) { assert(status === "order_not_pending"); return; }
assert(status === "ok");
order.status = "cancelled";
```

### Version conflicts

Operations with optimistic concurrency accept both outcomes but only
update the model on success.

```typescript
assert(status === "ok" || status === "version_conflict");
if (status !== "ok") return;
p.version += 1;
```

### Cross-entity validation

Walk the same validation path the handler walks. Check each entity
exists, check each precondition. Mirror the handler's early returns.

```typescript
for (const item of req.body.items) {
  const p = model.product.get(item.product_id);
  if (!p || !p.active) { assert(status === "not_found"); return; }
  if (p.inventory < item.quantity) { assert(status === "insufficient_inventory"); return; }
}
assert(status === "ok");
```

### Side effects on failure

Some failures trigger writes. order_expired marks the order failed and
restores inventory. The model must mirror this.

```typescript
if (model.now >= order.timeout_at) {
  assert(status === "order_expired");
  order.status = "failed";
  for (const item of order.items) {
    model.product.get(item.product_id).inventory += item.quantity;
  }
  return;
}
```

### Duplicate creates

The sim sometimes generates IDs that already exist. The model knows.

```typescript
if (model.product.has(req.id)) { assert(status === "version_conflict"); return; }
assert(status === "ok");
```

### Read-only operations

No model update needed. The framework auto-verifies field values. The
assert just checks the status decision.

```typescript
const p = model.product.get(req.id);
if (!p || !p.active) { assert(status === "not_found"); return; }
assert(status === "ok");
```

### What NOT to put in assert

- Don't reimplement the handler's logic. Assert outcomes, don't
  compute them.
- Don't check field values the framework auto-verifies.
- Don't add error handling. Assert runs inside the sim — if it throws,
  the sim reports seed + event index for reproduction.
- Don't filter inputs in attempt for success. Generate inputs that
  might fail. Let the handler fail. Let assert verify the failure
  was correct.

## Common domain bugs and what catches them

### Inventory leaks

**Bug:** cancel_order forgets to restore reserved inventory.

**Caught by:** Conservation law in invariant. `shelf + reserved ===
inventory_created` fails the moment any handler creates, destroys, or
misroutes a single unit. Also caught by per-entity auto-verification —
model's `product.inventory` diverges from the DB.

### Double-spend / oversell

**Bug:** Two orders reserve the same inventory. Product has 10 units,
order A reserves 8, order B reserves 5.

**Caught by:** create_order assert checks `p.inventory < item.quantity`
against the model. The model tracks inventory accurately, so the second
order sees inventory=2 and asserts `insufficient_inventory`. Also caught
by conservation law.

### Soft delete visibility

**Bug:** Deleted product still appears in results or can be ordered.

**Caught by:** get_product assert asserts `not_found` when `!p.active`.
create_order assert asserts `not_found` when a referenced product is
inactive.

### Stale version writes

**Bug:** Handler overwrites stale data without checking version.

**Caught by:** update_product assert accepts both `ok` and
`version_conflict`. On `ok`, it increments version. If two updates
both return `ok`, the model's version diverges from DB —
auto-verification catches it.

### Orphaned references

**Bug:** Delete a product referenced by a pending order.

**Caught by:** Conservation law catches the inventory side. For
membership, add an invariant checking no member references a deleted
collection.

### Price / total arithmetic

**Bug:** Order total doesn't equal sum of line items.

**Caught by:** Invariant that recomputes totals from source data and
asserts agreement.

### State transition violations

**Bug:** Cancelled order gets cancelled again and returns ok.

**Caught by:** cancel_order and complete_order assert both check
`!pending(order.status)` and assert rejection. Terminal permanence
invariant catches it independently.

### Empty / zero edge cases

**Bug:** Zero-quantity transfer succeeds.

**Caught by:** `input_valid` rejects at the boundary. The sim's 10%
random message path produces these inputs. If `input_valid` has a gap,
the assert catches the unexpected status.

### Auth boundary leaks

**Bug:** Anonymous user accesses an authenticated operation.

**Caught by:** Model tracks `is_authenticated`. Auth-gated asserts
check `status === "unauthorized"` when not authenticated.

### Timeout races

**Bug:** Off-by-one in `now >= timeout_at` vs `now > timeout_at`.

**Caught by:** complete_order assert checks the same condition against
`model.now`. The sim advances time by random increments, naturally
generating requests at the boundary.

### Summary

| Bug class | assert | invariant | auto-verify |
|---|---|---|---|
| Inventory leak | — | conservation law | per-entity |
| Double-spend | status mismatch | conservation law | per-entity |
| Soft delete | status mismatch | — | — |
| Stale version | status mismatch | — | per-entity |
| Orphaned refs | — | membership check | — |
| Price math | — | total recompute | per-entity |
| State transition | status mismatch | terminal permanence | — |
| Empty / zero | status mismatch | — | — |
| Auth boundary | status mismatch | — | — |
| Timeout race | status mismatch | — | — |

Three independent catch mechanisms. Most bugs are caught by two or more.

## Cross-domain validation

The annotation system was tested against five domains beyond ecommerce:
SaaS subscription billing, ride-sharing, healthcare scheduling, content
moderation, and multi-warehouse inventory. Each domain was implemented
with the `sim:` annotations to verify the patterns scale.

### What scales across all domains

**Predicates.** Every domain has 3-5 predicates. They're always
one-liners. They're always shared between assert and invariant.
Examples: `terminal` (ecommerce orders, ride-sharing trips),
`billable` (subscription status), `active_appt` (healthcare),
`visible` (content moderation), `in_transit` (warehouse transfers).

**Conservation laws.** Every domain has at least one invariant that
sums quantities across entity types and asserts they balance:

| Domain | Conservation law |
|---|---|
| Ecommerce | shelf + reserved = inventory_created |
| Billing | invoiced - credited = revenue |
| Ride-sharing | driver_payouts + platform_fees = total_fares |
| Warehouse | stocked + in_transit = total_received |
| Moderation | (no quantity conservation, but reputation ceiling) |

The invariant is always the same shape: sum A + sum B = total C.

**Assert shape.** Top-to-bottom precondition checking, assert status
at each branch, update model on success. Works identically in all five
domains without modification. Cross-entity checks (driver→trip,
patient→authorization, warehouse→bin) follow the same pattern as
order→product.

**Sparsity.** In every domain, 4-8 of 15-30 operations are high-risk
and need sim annotations. The rest are reads or simple mutations. The
opt-in colocation model holds — most handler files have zero sim
annotations.

**Model size.** Every domain tested has 4-6 entity types and 1-3
counters. Model complexity is bounded by the domain, not by the
framework. A domain with 6 entity types produces the same shaped sim
code whether you use this annotation system or any other approach.

### What strains but holds

**Composite keys.** Multi-warehouse inventory tracks stock by
warehouse+product. A Map keyed by `"warehouse:product"` is less
elegant than a nested structure but keeps invariants flat and
iterable. The alternative (nested Maps) makes conservation laws
require nested loops — worse.

**Time-dependent logic.** Subscription proration and appointment
scheduling require time-aware predicates. The assert for
`upgrade_subscription` must verify proration math, which approaches
reimplementing the calculation. But it's the same boundary the
ecommerce price_math invariant already crosses — recomputing from
source data to verify agreement. The predicate gets more complex
(`overlaps(a, b)` is 4 comparisons for scheduling) but it's still a
pure function shared between assert and invariant. The alternative is
not checking it, which means billing bugs surface as customer
complaints.

**Multi-state lifecycles.** Warehouse transfers have 5 states,
ride-sharing trips have 5 states. More states means more predicates
and more assert branches, but each branch stays small. Collapsing
predicates (e.g. `non_terminal` covering 3 states) loses precision —
the assert can't distinguish "matched but not started" from "in
progress." More predicates is more precise. Each one is still a
one-liner. The alternative is fewer, coarser predicates that let
handler bugs slip through.

### What the sim doesn't cover

**Algorithm quality.** "Did we pick the *best* driver?" depends on a
scoring function that changes with business priorities. The sim checks
"the driver that was matched was actually available" (structural
correctness) but can't check optimality. This needs benchmarks and A/B
tests, not invariants.

**Subjective decisions.** "Should this content be flagged?" depends on
policy that changes weekly. The sim generates flags randomly and checks
that the system's *response* to a flag is structurally correct (state
machine transitions, reputation penalties). The judgment itself is
outside the sim's scope.

**Performance properties.** "Does this query scale?" depends on data
volume and access patterns. The sim runs 10,000 operations with small
entity pools — it catches correctness bugs, not performance
regressions. This needs benchmarks and profiling.

These are not failures of the sim design. They're fundamentally
different concerns that don't have a "right answer" a reference model
can assert. Putting them in the sim would mean the model reimplements
scoring functions and policy rules — the oracle anti-pattern the
design rejects.

### Scaling conclusion

The pattern's ceiling is model complexity, not syntax complexity. Model
complexity is bounded by the domain. The annotation system, predicates,
assert shape, and invariant pattern all transferred to five domains
without modification. The strains (composite keys, time logic,
multi-state lifecycles) are inherent domain complexity — any testing
approach faces them. The annotation system doesn't make them worse, and
the shared predicates make them easier to manage than ad-hoc tests.

## Framework responsibilities

What the framework handles automatically (no user code):

1. **Operation selection** — swarm-weighted random pick from all operations
2. **Route construction** — builds HTTP request from handler annotations
3. **Default request generation** — random fields for operations without attempt
4. **Execution** — runs request through the real pipeline
5. **Per-entity verification** — after each operation, compares model fields to DB
6. **Coverage reporting** — which operations fired, which statuses returned
7. **Column advisories** — warns about DB columns not tracked by the model
8. **Failure output** — seed, event index, operation sequence for reproduction
9. **Limits enforcement** — stops generating creates at capacity
10. **Invariant scheduling** — calls all invariants every N operations
11. **Sim coverage advisories** — warns when operations likely need sim annotations

## Scanner integration

The annotation scanner already processes handler files for
`[route]`, `[prefetch]`, `[handle]`, `[render]`. It extends to
recognize `sim:` prefixed annotations:

- `[sim:model]` — exactly one across all scanned files. Error if
  missing or duplicated.
- `[sim:attempt] .operation` — one per operation. The `.operation`
  must match a declared `[handle]`. Warning if missing (framework
  uses default generation).
- `[sim:assert] .operation` — one per operation. The `.operation`
  must match a declared `[handle]`. Warning if missing (only
  auto-verification, no status assertions).
- `[sim:invariant]` — any number, no operation binding. Error if
  none exist (a sim without invariants is incomplete).

The scanner produces a sim manifest alongside the handler manifest.
The sim runner reads both.

### Sim coverage advisories

The scanner already extracts enough from handler annotations to
identify operations that likely need sim coverage. No new annotations
— the scanner correlates existing data.

**Signal 1: decision branches with writes.** A `[handle]` with a body
(writes to DB) and more than one status has decision branches with
side effects. This is the class of operation where bugs hide.

| Handle has body | Status count | Sim advisory |
|---|---|---|
| no | 1 | none — read-only, auto-verify sufficient |
| yes | 1 | none — simple write, auto-verify likely sufficient |
| yes | 2+ | **recommend `[sim:assert]`** |
| no | 2+ | weak — conditional read, consider assert |

**Signal 2: cross-entity writes.** If a handle's SQL touches more than
one table (multiple UPDATE/INSERT targeting different tables), the
operation has cross-entity side effects. These are where conservation
laws break.

**Output format:** Advisories, not errors. Same treatment as column
warnings — the developer can ignore them for operations where
auto-verify is sufficient.

```
advisory: cancel_order has 3 statuses and writes — consider [sim:assert]
advisory: create_order has 3 statuses and writes — consider [sim:assert]
advisory: transfer_inventory writes to products twice — conservation invariant recommended
advisory: get_product has 2 statuses, no writes — auto-verify may suffice
```

The advisory fires when:
- `[handle]` has a body + 2 or more statuses + no `[sim:assert]` exists
- `[handle]` writes to 2+ tables + no `[sim:invariant]` references
  those entity types

This surfaces "this operation is complex enough to warrant sim
coverage" at build time. For operations added by AI code generation
or junior developers, the advisory catches missing test coverage
before it ships. The scanner already parses status sets and SQL
statements — the advisory is a correlation of existing data, not a
new analysis pass.

## Design exploration

### Attempt 1: central model class

Four methods: `request`, `apply`, `verify`, `atCapacity` on a single
class with switch statements per operation.

**Rejected.** ~150 lines of imperative switches. Every new operation
means updating three switch statements. The maintenance burden is the
same pattern that makes people stop writing tests.

### Attempt 2: TB-style reconcile

Split `apply` (which reimplemented handler logic) into accept-and-update
+ separate invariant checks. Dumber generators, smarter verification.

**Kept.** This insight shaped the assert/invariant split. Assert accepts
the system's answer and updates the model. Invariant checks global
consistency independently.

### Attempt 3: colocated annotations (no prefix)

Put `[sim]` and `[apply]` annotations in handler files.

**Rejected initially.** Test code in production files. Scanner would
need to strip it. Model shape implicit.

**Reversed.** The `sim:` prefix solves visibility. Annotations are
opt-in and sparse (4-8 handlers). They're inert in production. The
developer sees the complete story of a high-risk operation in one file.
Cross-cutting pieces (model, invariants) still live separately.

### Attempt 4: infer model from DB schema

Derive model from `SELECT` columns in handler annotations.

**Rejected.** Schema is storage format. Model is expected behavior.
They diverge for derived state (counters), relationships, and semantic
constraints. Column renames would break tests when behavior didn't
change.

### Attempt 5: explicit Model.declare + single test file

Declarative model schema. All sim/apply/verify in one test file.

**Partially kept.** The single-file approach works at 24 operations
but doesn't scale. At 60 operations, line 347 of a 600-line test file
is unmaintainable.

### Attempt 6: annotation-per-file, separate directories

`tests/attempt/cancel_order.ts`, `tests/assert/cancel_order.ts`, etc.

**Rejected.** Separates test code from the handler it tests. Developer
must open two files to see the full picture. The colocation benefit
outweighs the separation benefit for the 4-8 high-risk handlers that
have sim annotations.

### Attempt 7: sim: prefixed annotations, colocated

`[sim:attempt]`, `[sim:assert]` in handler files. `[sim:model]` and
`[sim:invariant]` in separate files.

**Accepted.** The `sim:` prefix provides visual separation. Per-operation
test code colocates with the handler. Cross-cutting test code lives
separately. The scanner validates wiring. Most handlers have zero sim
annotations — only high-risk operations get them.

### Attempt 8: Model.declare vs model function

`Model.declare({ product: { inventory: "number" } })` vs a plain
function returning the initial state.

**Model function accepted.** `Model.declare` is ceremony. The framework
doesn't need a schema — it discovers fields at runtime from the first
`.set()` call. TypeScript type inference provides autocomplete without
a declaration API. One less concept, one less import.

### DSL for assert callbacks

Declarative tables: `when: { order: { status: terminal } }, expect: "order_not_pending"`.

**Rejected.** Works for simple operations (cancel) but can't express
complex ones (complete_order with timeout + failure + inventory restore)
without growing into a bad programming language. The code version is
already short. The real win is shared predicates, not syntax.

### Naming: sim/apply/verify vs attempt/assert/invariant

Original names (`sim`, `apply`, `verify`) were implementation-focused.
Explored alternatives through several rounds:

- `request` → rejected, Rails/Laravel developers hear "HTTP request"
- `expect` → rejected, tied to specific test framework conventions
- `audit` → rejected, sounds business-y not technical

Final names describe what the user is doing, not how the framework
uses it:
- **attempt** — "try this operation with these inputs"
- **assert** — "was that the right answer?"
- **invariant** — "rules that must always remain true"

## Multiplicity rules

| Annotation | Per file | Per operation | Total |
|---|---|---|---|
| `[sim:model]` | 1 | n/a (global) | exactly 1 |
| `[sim:attempt] .op` | 1 | 1 | 0-1 per operation |
| `[sim:assert] .op` | 1 | 1 | 0-1 per operation |
| `[sim:invariant]` | 1 | n/a (global) | 1 or more |

- One attempt per operation. Multiple generators considered and rejected —
  swarm testing and the 10% random message path already vary the input
  distribution per seed. Multiple generators would manually partition
  what the PRNG does automatically.
- One assert per operation. Sharing asserts between operations considered
  and rejected — operations that look similar today (`get_product`,
  `get_collection`) diverge tomorrow. The duplication of 3-line callbacks
  is cheaper than an abstraction every new operation must fit into.
- Model and invariant are not shared between operations because they
  don't belong to operations. They're global by nature.

## Testing paradigm origins

These techniques are old ideas, rarely combined:

- **Decision tables** — 1960s IBM batch processing validation
- **State transition testing** — 1970s-80s telecom protocol conformance
- **Invariant predicates** — Hoare logic (1969), Eiffel Design by Contract (1986)
- **Property-based testing** — QuickCheck (2000)

Each is textbook individually. The combination — property tests +
reference model + deterministic replay + fault injection + coverage
tracking in one loop — is rare because it requires a deterministic
system, a reference model, controlled nondeterminism, and a simulation
layer. Most web frameworks provide none of these.

This plan makes the combination accessible to application developers.
The framework handles determinism, replay, fault injection, coverage.
The user writes the model, predicates, and assertions.

## Zig-native sim

The plan's examples are TypeScript (sidecar path). But the Zig
handlers are the primary implementation — the TS handlers are the
sidecar port. Testing the port without testing the original is
backwards.

The Zig fuzzer (`fuzz.zig`) already generates random operations, runs
them through prefetch/commit, and checks structural properties (status
is valid enum, create-then-get succeeds). But it has no auditor — it
never verifies domain correctness. `IdTracker.on_commit` tracks IDs
and checks allowed status sets but doesn't know what the *correct*
status should be.

The sim annotations apply to Zig handlers identically:

```zig
// handlers/cancel_order.zig

// [sim:assert] .cancel_order
pub fn sim_assert(model: *Model, req: Request, status: Status) void {
    const order = model.orders.get(req.id) orelse {
        assert(status == .not_found);
        return;
    };
    if (!pending(order.status)) {
        assert(status == .order_not_pending);
        return;
    }
    assert(status == .ok);
    order.status = .cancelled;
    for (order.items.slice()) |item| {
        model.products.getPtr(item.product_id).?.inventory += item.quantity;
    }
}
```

The scanner already processes `.zig` files. The Zig model is a struct
with hash maps instead of a function returning JS objects. The
predicates are inline functions. The invariants are functions that
receive `*const Model`. Same patterns, different syntax.

**Implementation order:** Zig-native sim first, TypeScript sidecar
sim second. The Zig fuzzer already has the loop, the PRNG, the fault
injection. It needs the model, assert dispatch, and invariant
scheduling bolted onto `fuzz.zig`. The sidecar sim needs a new loop
built from scratch. Zig first is less work and tests the real
implementation.

## DB-grounded invariants

The assert callback both verifies status and updates the model. If the
assert has a bug in its model update — forgets to increment a counter,
forgets to restore inventory — the invariant passes because it's
checking the model against itself. The model and the DB agree on the
wrong answer.

Per-entity auto-verification catches assert bugs that affect entity
fields (model says inventory=50, DB says inventory=45). But counter
bugs are invisible — if the assert forgets to update
`counters.inventory_created`, the conservation law checks garbage
against garbage.

**Fix:** At least one invariant per domain must query the DB directly
rather than reading `model.counters`. The framework passes a read-only
DB handle to invariants alongside the model:

```typescript
// [sim:invariant]
export function invariant(model, db) {
  // Recompute from DB — does not trust model.counters
  const db_inventory = db.query("SELECT SUM(inventory) FROM products").value;
  const db_reserved = db.query(
    "SELECT SUM(oi.quantity) FROM order_items oi " +
    "JOIN orders o ON o.id = oi.order_id WHERE o.status = 'pending'"
  ).value;
  const db_total = db_inventory + db_reserved;

  // Now check model agrees with DB
  let model_shelf = 0;
  for (const p of model.product.values()) model_shelf += p.inventory;
  assert(model_shelf === db_inventory);

  // And check the conservation law against DB source of truth
  assert(db_total === model.counters.inventory_created);
}
```

This is a three-way check: model ↔ DB ↔ counter. If the assert
forgot to update the model, auto-verification catches it (model ≠ DB).
If the assert forgot to update the counter, the DB-grounded invariant
catches it (DB total ≠ counter). If the handler has a bug, both catch
it. No single point of failure.

The `[sim:invariant]` signature changes: `invariant(model)` becomes
`invariant(model, db)`. Invariants that don't need DB access ignore
the second parameter. The framework always provides it.

Zig DB-grounded invariant receives `Storage.ReadView`:

```zig
// [sim:invariant]
pub fn inventory_conservation(model: *const Model, ro: anytype) void {
    // DB source of truth — does not trust model.counters
    const db_shelf = ro.query_scalar(u64,
        "SELECT COALESCE(SUM(inventory), 0) FROM products;", .{}) orelse 0;
    const db_reserved = ro.query_scalar(u64,
        "SELECT COALESCE(SUM(oi.quantity), 0) FROM order_items oi " ++
        "JOIN orders o ON o.id = oi.order_id WHERE o.status = 0;", .{}) orelse 0;

    // Model agrees with DB
    var model_shelf: u64 = 0;
    var iter = model.products.valueIterator();
    while (iter.next()) |p| model_shelf += p.inventory;
    assert(model_shelf == db_shelf);

    // Conservation law against DB source of truth
    assert(db_shelf + db_reserved == model.counters.inventory_created);
}
```

## Coverage gap with TigerBeetle

TB's VOPR exercises multi-client concurrency, storage faults, network
faults, crash/restart, clock faults, millions of events.

Our v1 has: single client, sequential operations, busy faults at
prefetch, configurable event counts (default 10K, CI runs 1M+).

10,000 events is a smoke test. A conservation law that passes at 10K
and fails at 500K because of slow integer overflow is a real class of
bug. Long-running stress is v1, not v2 — it's a configuration flag
(`--events-max`), not a new capability. CI runs the sim at 1M+ events
on every merge. Local development defaults to 10K for fast feedback.

### v2 targets (priority order)

1. **Multi-client interleaving** — the model tracks per-entity state
   not per-client, so this works without API changes
2. **Storage faults** — inject SQLite errors, assert clean failure
3. **Network faults (SimIO)** — partial sends, disconnects, timeouts
4. **Crash/restart** — WAL replay verification with domain data

## Implementation details

Resolved decisions that a new session needs to implement without
further design exploration.

### Auto-verification: which entity to check

After each operation, the framework queries the DB and compares to the
model. It needs to know which entity was affected. Resolution: the
operation tag determines the entity type. The framework maintains a
static mapping (comptime in Zig, manifest in TS):

```
create_product, update_product, delete_product → product(msg.id)
create_order → order(body.id)
cancel_order, complete_order → order(msg.id)
transfer_inventory → product(msg.id), product(body.target_id)
```

Operations that affect multiple entities (transfer, create_order)
verify all affected entities. The mapping is declared once in the sim
infrastructure, not per-handler.

For Zig: the mapping is a comptime switch in the sim loop. For TS:
the scanner derives it from the `[sim:assert]` annotations — any
entity `.set()` or field mutation in the assert body identifies the
affected entity type and key.

### Limits and capacity

The Zig fuzzer has `IdTracker.at_capacity` with per-entity caps
(896 products, 224 collections, 224 orders). The sim inherits this
mechanism. The model tracks entity counts. The sim loop skips create
operations when at capacity.

For Zig: reuse `IdTracker.at_capacity` or replace it with model-based
capacity checks.

For TS: limits are declared in the sim runner config:

```typescript
Simulation.run({
  limits: { product: 20, order: 50, collection: 20 },
  events: 10_000,
});
```

The framework stops picking create operations for entity types at
their limit. The limit applies to the model, not the DB — the model
is the source of truth for capacity decisions.

### Default generation for operations without attempt

Operations without a `[sim:attempt]` get default generation:
- ID-bearing operations: random ID from the model's entity pool
  (75% existing, 25% random — matches `pick_or_random_id`)
- Body-bearing operations: zeroed body struct (Zig) or empty object
  (TS). These will likely fail `input_valid` and be skipped.
- Bodyless operations: just the ID.

Operations with complex body requirements (create_order with items
array, create_product with name/price) effectively require an
`[sim:attempt]` — default generation produces invalid inputs that
`input_valid` rejects. The coverage tracker warns if an operation
never commits, which surfaces missing attempt annotations.

### Time injection

The sim loop tracks wall-clock time and advances it by random
increments each iteration (1-5 seconds, matching the existing fuzzer).
The model receives the current time:

For Zig: `model.now` is set by the sim loop before each operation,
same as `sm.now`. The assert reads `model.now` for timeout checks.

For TS: the model function returns `{ ..., now: 0 }`. The framework
updates `model.now` before each attempt/assert call. The assert for
complete_order reads `model.now` to check `model.now >= order.timeout_at`.

Time advances are deterministic (PRNG-driven), so timeout boundary
conditions are reproducible from the seed.

### Invariant scheduling frequency

Invariants run every N operations, not after every operation. Running
after every operation is correct but slow at 1M events.

Default: every 100 operations. Configurable per-run. At sim end, all
invariants run once regardless of the counter — no operation silently
violates an invariant in the final batch.

For Zig: the sim loop calls `run_invariants()` every N iterations and
once after the loop exits.

For TS: the framework handles scheduling internally. The user never
calls invariants manually.

## Delivery order

### Phase 1: Zig-native sim (bolt onto fuzz.zig)

1. Model struct — hash maps for entities, counters
2. Assert dispatch — switch on operation, call handler's `sim_assert`
3. Invariant scheduling — call all invariants every N operations
4. DB-grounded invariants — pass read-only storage to invariants
5. Per-entity auto-verification — model fields vs DB after each operation
6. Coverage tracking — assert all statuses reached, all operations fired
7. Long-running CI — `--events-max=1000000` on every merge

### Phase 2: Scanner integration

8. Scanner: recognize `sim:` prefixed annotations in .zig and .ts files
9. Sim manifest — list of attempt/assert/invariant with source locations
10. Exhaustiveness warnings — operations without assert, sim without invariants

### Phase 3: TypeScript sidecar sim

11. Sim loop — swarm weights, operation selection, HTTP execution
12. `[sim:model]` — call function, carry the object
13. `[sim:attempt]` dispatch — call user generators, default generation fallback
14. `[sim:assert]` dispatch — call user assert with model, req, status
15. `[sim:invariant]` dispatch — call invariants with model and DB handle
16. Column advisory warnings
17. Failure output — seed, event index, reproduction command
