# Simulation testing — user-space API

## Problem

The framework runs user-written handlers. The framework can test its own
pipeline (prefetch/commit ordering, fault injection, HTTP framing) but it
cannot test the user's domain logic. A cancel_order handler that forgets
to restore inventory is invisible to the framework — it's a domain bug,
not a pipeline bug.

Today this class of bug is caught (or not) by hand-written scenario tests.
The interleaved writes debugging session exposed the cost: a test that
checked the wrong property (HTTP status code instead of body content)
passed for months and misdirected debugging toward phantom infrastructure
issues. Hand-written tests also only cover the scenarios the developer
thinks of — they don't explore the state space.

TigerBeetle solves this internally with a reference model pattern: a
workload generator produces random operations, executes them against the
real system, and reconciles each response against an independent model.
But TB owns both the state machine and the tests. We own the framework;
the user owns the domain logic.

The goal: give users the same testing power TB has internally, with an
API that's small enough to actually use.

## Design exploration

### Attempt 1: central model class

Four methods: `request`, `apply`, `verify`, `atCapacity`.

```typescript
class EcommerceModel {
  products = new Map<string, { ... }>();
  orders = new Map<string, { ... }>();

  request(operation, random) { switch (operation) { ... } }
  apply(operation, req, status) { switch (operation) { ... } }
  verify(db) { ... }
  atCapacity(operation) { switch (operation) { ... } }
}

SimTest.run({ handlers, model: new EcommerceModel(), events: 10_000 });
```

**Outcome:** Correct but heavy. ~150 lines of imperative switch statements.
The `request` method manually constructs HTTP requests that duplicate the
route patterns the user already declared in their handlers. Every new
operation means updating three switch statements. The maintenance burden
is the same pattern that makes people stop writing tests.

### Attempt 2: TB-style critique of the model

TigerBeetle's reconcile doesn't predict what the system should return —
it accepts the system's answer and updates the model to match. Then
separately, query-based invariant checks verify the model against the DB.

This split the original `apply` (which reimplemented handler logic to
predict outcomes) into:
- `apply` — accept the result, update the model
- `verify` — query the DB, assert agreement

The `request` method was also too selective — only generating inputs that
should succeed. TB generates inputs that might fail and lets reconcile
handle both outcomes. Dumber generators, smarter verification.

### Attempt 3: colocated annotations

Put `[sim]` and `[apply]` annotations in handler files next to the code
they test:

```typescript
// handlers/cancel_order.ts
// [sim] .cancel_order
export function sim(random, model) { ... }
// [apply] .cancel_order
export function apply(model, req) { ... }
```

**Outcome:** Good colocation — developer sees the complete story of an
operation in one file. But test code in production files crosses a
boundary most developers expect to be separate. The scanner would need
to strip it from production builds. And the model shape is implicit —
`model.products` appears in apply functions but nobody declared it.
The annotation syntax doesn't give the framework any information it
couldn't get from plain imports.

**Decision:** Rejected. Colocation isn't worth mixing test and production
code. The annotation pattern works for route/prefetch/handle/render
because those ARE the implementation. sim/apply are test infrastructure.

### Attempt 4: infer model from DB schema

The framework already knows the SQL from handler annotations. The model
shape could be inferred from `SELECT id, name, inventory... FROM products`.

**Decision:** Rejected. The schema is the storage format. The model is
expected behavior. They overlap for simple fields but diverge for:
- Derived state (e.g., `inventory_created` — no column for this)
- Relationships (order items reference product IDs)
- Semantic constraints (valid status transitions)

The schema also has things the model doesn't care about (`payment_ref`).
Coupling tests to storage layout means column renames break tests even
when behavior didn't change. TB's model is a plain struct that tracks
what the test cares about, not what the DB stores.

### Attempt 5: explicit model + single test file

Separate the model declaration from the test logic. The model is a small
schema the user writes once. The test file contains `sim`, `apply`, and
`verify` — all domain logic, no boilerplate.

The framework knows the handlers from the build (scanner). No need to
pass them in. `limits` is declarative data instead of a method.

**Decision:** Accepted. This is the final API.

## Final API

### Model declaration

```typescript
// tests/sim.model.ts
import { Model } from "tiger-web/testing";

export default Model.declare({
  product: {
    name: "string",
    price_cents: "number",
    inventory: "number",
    version: "number",
    active: "boolean",
  },
  order: {
    status: "string",
    items: [{ product_id: "string", quantity: "number" }],
  },
  counters: {
    inventory_created: 0,
  },
});
```

### Test file

```typescript
// tests/sim.test.ts
import { Simulation } from "tiger-web/testing";
import model from "./sim.model";

Simulation.run({
  model,
  events: 10_000,
  limits: { product: 20, order: 50 },

  sim: {
    create_product: (random) => ({
      name: random.word(),
      price_cents: random.range(100, 10000),
      inventory: random.range(0, 200),
    }),
    create_order: (random, model) => {
      const ids = [...model.product.keys()];
      if (ids.length === 0) return null;
      return {
        items: random.sample(ids, random.range(1, 3)).map(id => ({
          product_id: id, quantity: random.range(1, 10),
        })),
      };
    },
    complete_order: (random, model) => {
      const id = random.pick(model.order.keys());
      if (!id) return null;
      return { id, result: random.pick(["confirmed", "failed"]) };
    },
    cancel_order: (random, model) => {
      const id = random.pick(model.order.keys());
      if (!id) return null;
      return { id };
    },
  },

  apply: {
    create_product: (model, req, status) => {
      if (status !== "ok") return;
      model.product.set(req.id, { ...req.body, version: 1, active: true });
      model.counters.inventory_created += req.body.inventory;
    },
    update_product: (model, req, status) => {
      if (status !== "ok") return;
      const p = model.product.get(req.id);
      p.name = req.body.name;
      p.version += 1;
    },
    delete_product: (model, req, status) => {
      if (status !== "ok") return;
      model.product.get(req.id).active = false;
    },
    create_order: (model, req, status) => {
      if (status !== "ok") return;
      model.order.set(req.id, { status: "pending", items: req.body.items });
      for (const item of req.body.items) {
        model.product.get(item.product_id).inventory -= item.quantity;
      }
    },
    complete_order: (model, req, status) => {
      if (status !== "ok") return;
      const order = model.order.get(req.id);
      order.status = req.body.result === "confirmed" ? "confirmed" : "failed";
      if (order.status === "failed") {
        for (const item of order.items) {
          model.product.get(item.product_id).inventory += item.quantity;
        }
      }
    },
    cancel_order: (model, req, status) => {
      if (status !== "ok") return;
      const order = model.order.get(req.id);
      order.status = "cancelled";
      for (const item of order.items) {
        model.product.get(item.product_id).inventory += item.quantity;
      }
    },
  },

  verify(model) {
    let shelf = 0, reserved = 0;
    for (const p of model.product.values()) shelf += p.inventory;
    for (const o of model.order.values()) {
      if (o.status === "pending") {
        for (const item of o.items) reserved += item.quantity;
      }
    }
    assert(shelf + reserved === model.counters.inventory_created);
  },
});
```

## API contract

### `sim` (per-operation request generators)

`sim[operation](random, model) => body | null`

Generates a random request body for the operation. The framework handles
HTTP construction — it knows the route pattern and method from handler
annotations. The user only provides the body shape.

Return `null` to skip (no valid target entity exists yet). Operations
without a `sim` entry get default generation: random IDs from the model's
entity pools, random values for each field type.

Generators should produce inputs that might fail — don't filter for
success. Let the system return errors and let `apply` handle both outcomes.

### `apply` (per-operation model updates)

`apply[operation](model, req, status) => void`

Called after each operation executes through the real pipeline. Receives
the handler's status. Updates the model to reflect what happened.

For operations where only success matters: `if (status !== "ok") return`.
For operations where error validation matters: assert specific statuses
based on model state.

Operations without an `apply` entry are assumed to have no cross-entity
side effects. The framework handles basic per-entity tracking from the DB.

### `verify` (cross-entity invariants)

`verify(model) => void`

Called periodically (every N operations). Assert invariants that span
entities — conservation laws, relationship integrity, global constraints.

Per-entity field verification (model.product.inventory === db.inventory)
is automatic — the framework checks every field in the model against the
DB after each operation. The user only writes invariants the framework
can't infer.

### `limits` (entity capacity)

`limits: { entity_name: max_count }`

Caps entity creation. Once the model has `max_count` entities of a type,
the framework stops picking create operations for that type. Keeps the
state space focused on mutations and the model small enough for fast
verification.

### `model` (world state declaration)

`Model.declare({ entity: { field: type }, counters: { name: initial } })`

Declares the shape of the reference model. Entity fields are typed for
autocomplete and verification. Counters are user-defined derived state
that doesn't exist in any table but invariants need.

## Framework responsibilities

What the framework handles automatically (no user code):

1. **Operation selection** — swarm-weighted random pick from all operations
2. **Route construction** — builds HTTP request from handler annotations
3. **Default request generation** — random fields for operations without `sim`
4. **Execution** — runs request through the real pipeline (route, prefetch, handle, render)
5. **Per-entity verification** — after each operation, checks every model field against the DB
6. **Coverage reporting** — which operations fired, which statuses returned
7. **Column advisories** — warns about DB columns not tracked by the model
8. **Failure output** — seed, event index, operation sequence for reproduction
9. **Limits enforcement** — stops generating creates at capacity

## TigerBeetle critique and responses

### 1. Per-entity verification should be automatic

**Concern:** The user shouldn't write `assert(row.inventory === expected.inventory)`
for every field. They declared the model shape — the framework should check
agreement automatically.

**Response:** Accepted. The framework verifies every entity field against the
DB after each operation. The user's `verify` only contains cross-entity
invariants the framework can't infer (conservation laws, relationships).

### 2. `apply` should receive the status

**Concern:** If apply only runs on success, the model never validates that
errors were expected. A handler that starts returning `ok` for something
that should fail goes undetected.

**Response:** Accepted. `apply` receives `status` as third parameter. The user
can validate error paths or ignore them with `if (status !== "ok") return`.
This is the only change to the user-facing API from the critique.

### 3. Coverage reporting

**Concern:** If `cancel_order` never returned `order_not_pending` across
10,000 events, the user should know their simulation isn't reaching that path.

**Response:** Accepted. The framework tracks and reports coverage after the run:
which operations fired, which statuses were returned, which `apply` branches
were taken. Framework-internal — no user API change.

### 4. Advisory warnings for untracked columns

**Concern:** If the user adds a column to their SQL and forgets to add it to
the model, the model silently ignores it.

**Response:** Accepted. The framework warns about DB columns not tracked by
the model after the verify pass. Advisory only — not an error, since the
model is intentionally a subset of the DB. Framework-internal — no user
API change.

### 5. Multi-client interleaving

**Concern:** Single-threaded simulation can't explore race conditions between
concurrent clients. The interleaved writes bug was exactly this class.

**Response:** Deferred to v2. The API is designed so that a future version can
run multiple simulated clients against the same server tick loop. The model
and apply functions don't assume single-client execution. The framework
would need to manage per-client state and operation interleaving internally.

## What this catches

The cancel-inventory bug from the debugging session: on event ~200,
`create_order` reserves 5 units of inventory. On event ~350, `cancel_order`
succeeds. The handler forgets to restore inventory. The model's apply adds
it back. The framework's automatic per-entity verification queries the DB:
`product.inventory` is 45, model says 50. Failure reported with seed and
event index. The conservation invariant in `verify` catches it independently:
`45 + 0 !== 50`.

Two independent checks, neither reimplements the handler, both catch the
bug within the first few hundred events of any seed.

## Coverage gap with TigerBeetle

TB's VOPR runs for minutes or hours with millions of ticks across
replicas. Their simulation exercises:

- **Multi-client concurrency** — multiple clients issuing operations
  simultaneously, interleaved by the tick loop
- **Storage faults** — read/write IO errors, corruption, latency
- **Network faults** — partitions, packet loss, reordering, replays
- **Process lifecycle** — crash, restart, state recovery
- **Clock faults** — skew, drift
- **Long-running stress** — millions of events, not thousands

Our v1 simulation has:

- Single client, sequential operations
- Busy faults at prefetch (skip and retry)
- No storage faults, no network faults, no crash/restart
- 10,000 events default

This is sufficient to catch domain logic bugs (the cancel-inventory
bug, the interleaved writes test bug) but not concurrency bugs or
recovery bugs. The coverage gap is deliberate for v1 — the reference
model and verification framework are the foundation. Fault injection
layers on top.

### v2 coverage targets (in priority order)

1. **Multi-client interleaving** — multiple simulated clients against
   the same server tick loop. The model tracks per-entity state, not
   per-client state, so this works without API changes. The framework
   manages operation interleaving internally. Catches race conditions
   like the interleaved writes bug.

2. **Storage faults** — inject SQLite errors at the storage boundary.
   Prefetch returns null, execute fails. The simulation asserts the
   system handles faults without corrupting state — operations either
   succeed fully or fail cleanly.

3. **Long-running stress** — configurable event counts up to millions.
   Run for minutes in CI. The model stays small (entity limits), but
   the operation count grows. Catches slow state drift and resource
   leaks.

4. **Network faults (SimIO)** — partial sends, disconnects, timeouts
   through the full HTTP stack. Already partially implemented in
   SimIO's fault probabilities. Needs integration with the simulation
   loop so the model can account for retries.

5. **Crash/restart** — kill the server mid-operation, recover from WAL,
   verify the model and DB agree after recovery. Tests the WAL replay
   path with real domain data.

## Delivery order

1. `Simulation.run` loop — swarm weights, operation selection, execution
2. `Model.declare` — entity maps, counters, typed accessors
3. `sim` dispatch — call user generators, fall back to default generation
4. `apply` dispatch — call user apply with status, basic entity tracking
5. Per-entity automatic verification — model fields vs DB after each op
6. `verify` scheduling — call user invariants every N operations
7. Coverage tracking and reporting
8. Column advisory warnings
9. Failure output — seed, event index, reproduction command
10. Documentation and ecommerce example
