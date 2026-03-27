# Design 003: Framework

## Observation

Tiger_web's user-space logic is small and pure. Of 16 operations, 13 follow
identical CRUD patterns: fetch by ID, maybe check version, write, return. The
remaining 3 have real business logic (multi-entity validation, state transitions).

The pipeline that executes this logic — epoll, connections, HTTP parsing, buffer
management, SSE framing, Content-Length backfill, keep-alive, follow-ups, the
tick loop — is domain-independent. It's the same for any HOWL app that serves
HTML over HTTP with Datastar SSE.

The framework is the recognition that these two things are different and should
live in different places — possibly different languages.

## Two processes, one contract

The Zig framework owns everything that's hard and mechanical: IO, connections,
HTTP, SSE, storage, buffer lifecycle, deterministic ordering. The sidecar owns
everything that's easy and domain-specific: business logic over typed data.

```
                    unix socket
  ┌──────────────┐ ──────────── ┌──────────────┐
  │ Zig framework│              │   Sidecar    │
  │              │  request:    │  (any lang)  │
  │  epoll       │  operation   │              │
  │  connections │  sequence    │  entity defs │
  │  HTTP parse  │  event       │  handlers    │
  │  SSE framing │  cache snapshot  templates  │
  │  storage     │              │  packages    │
  │  ordering    │  response:   │              │
  │  rendering   │  sequence    │              │
  │  auth        │  status      │              │
  │  follow-ups  │  writes      │              │
  └──────────────┘ ──────────── └──────────────┘
```

The contract between them is one message type in each direction:

```
// Framework sends:
{
  operation: "create_order",
  sequence: 42,
  event: { product_id: 7, customer_id: 12, quantity: 3 },
  cache: {
    product: { 7: { id: 7, name: "Widget", price_cents: 999, inventory: 50 } },
    customer: { 12: { id: 12, name: "Alice", status: "active" } }
  }
}

// Sidecar returns:
{
  sequence: 42,
  status: "ok",
  writes: {
    create: { order: { product_id: 7, customer_id: 12, quantity: 3, total_cents: 2997 } },
    update: { product: { id: 7, inventory: 47 } }
  }
}
```

The sidecar never touches storage. It receives a cache snapshot (read-only),
runs pure computation, returns a status and a set of writes. The framework
applies the writes to storage, renders the response, pushes SSE updates.

## Language-agnostic user space

The user defines entities and handlers in their language. The framework generates
typed bindings from the entity declarations — the sidecar gets real types, not
untyped JSON.

TypeScript:
```ts
const product = entity({
  fields: {
    name: "string",
    price_cents: "u32",
    active: "bool",
  },
  references: {},
  operations: {
    create: { method: "post", path: "/products" },
    update: { method: "put", path: "/products/:id", lock: "version" },
    get:    { method: "get", path: "/products/:id" },
    delete: { method: "delete", path: "/products/:id" },
    list:   { method: "get", path: "/products" },
  },
});
```

Python:
```python
product = entity(
    fields={"name": "string", "price_cents": "u32", "active": "bool"},
    references={},
    operations={
        "create": op("post", "/products"),
        "get":    op("get",  "/products/:id"),
        "list":   op("get",  "/products"),
    },
)
```

From the entity declarations the framework generates:

- Zig `extern struct` with `no_padding` validation and buffer sizing
- Operation enum, codec routing (method + path -> operation)
- Prefetch plans derived from references (foreign keys -> entities to load)
- Follow-up wiring (POST/PUT/DELETE are mutations, GET is a read)
- SSE selectors (entity name -> `#product-list`)
- Typed bindings in the sidecar's language (autocomplete, type checking)

Pure CRUD operations (no custom handler) are handled entirely by the framework.
The sidecar is only called for operations with custom logic.

## Per-operation handler mixing

Each operation is an independent sprint — prefetch, execute, commit, respond.
The framework dispatches per operation, so different operations can use
different handler modes. Three tiers, chosen per operation not per project:

- **Framework CRUD** — no custom logic. Fully generated from the entity
  declaration. Most operations live here.
- **Sidecar handler** — custom logic in the user's language. Probabilistic
  purity, full package ecosystem.
- **Zig handler** — custom logic that needs mechanical determinism guarantees.
  Same binary, same compiler, same fuzzer. A function call, not IPC.

```ts
// Sidecar: product is pure CRUD, order has custom logic
const product = entity({
  operations: {
    create: { method: "post", path: "/products" },        // framework CRUD
    get:    { method: "get", path: "/products/:id" },      // framework CRUD
    list:   { method: "get", path: "/products" },          // framework CRUD
  },
});

const order = entity({
  operations: {
    create: { method: "post", path: "/orders", commit: createOrder },  // sidecar
    get:    { method: "get", path: "/orders/:id" },                     // framework CRUD
  },
});
```

```zig
// Zig handler: payment needs mechanical guarantees
fn create_payment(cache: *const Cache, event: PaymentEvent) Result {
    // same binary, same assertions, same fuzzer as the framework
}
```

The product listing needs no custom logic — pure framework. The order creation
has business rules — sidecar in the user's language. The payment operation moves
money — Zig handler with mechanical determinism. Each operation gets exactly the
guarantee level it needs.

## Compile-time type checking of sidecar responses

The sidecar handler return type is small and fixed:

```
{ sequence: u32, status: enum, writes: { create/update/delete: { entity: fields } } }
```

The entities and their fields are already declared. The framework codegen
generates Zig types from those declarations. At build time the framework knows
every valid response shape and validates:

- Field types match (is `product_id` a `u32`?)
- Required fields are present (does the order create include `customer_id`?)
- Entity names are valid (does `product` exist in the schema?)
- Operation kind permits writes (is this a mutation?)

The sidecar language gets generated types that make it hard to return the wrong
shape — autocomplete, type checking, compiler errors in typed languages. The
Zig side gets generated validators that reject anything that doesn't match at
compile time.

For dynamically typed sidecar languages (plain JS, Python), the generated types
are optional — the developer can bypass them. The framework's boundary
validation catches malformed responses at runtime regardless.

## Cross-entity operations

Single-entity CRUD is fully generated. The interesting case is operations that
touch multiple entities — create an order that decrements product inventory.

The entity declaration captures relationships:

```ts
const order = entity({
  fields: {
    product_id: "u32",
    customer_id: "u32",
    quantity: "u32",
  },
  references: {
    product: "product_id",
    customer: "customer_id",
  },
  operations: {
    create: { method: "post", path: "/orders", commit: createOrder },
    get:    { method: "get", path: "/orders/:id" },
    list:   { method: "get", path: "/orders" },
  },
});
```

The framework sees `references` and auto-prefetches the product and customer
when `create_order` fires. The sidecar handler receives a cache snapshot with
all referenced entities already loaded:

```ts
function createOrder(cache, event) {
  const product = cache.get("product", event.product_id);
  if (product.inventory < event.quantity) return "insufficient_inventory";
  return {
    create: { order: { ...event, total_cents: product.price_cents * event.quantity } },
    update: { product: { id: product.id, inventory: product.inventory - event.quantity } },
  };
}
```

The handler is five lines of business logic. No loading, no storage calls, no
error handling boilerplate. The framework handles prefetch, applies the writes,
re-renders both the order list and the product list in the follow-up SSE.

The line: if it's structural, declare it. If it's a decision, write code.

## Templates

Templates are imperative code that builds HTML. The sidecar language has a
writer API that maps to the Zig HtmlWriter:

```ts
function productCard(h, product) {
  h.open("div", { class: "card" });
  h.text(product.name);
  h.open("span", { class: "price" });
  h.text(formatCents(product.price_cents));
  h.close("span");
  h.close("div");
}
```

The framework codegen turns this into a Zig render function at build time. The
field references (`product.name`) resolve to the Zig memory representation
(`p.name[0..p.name_len]`). The user writes `product.name`, not byte slices.

## Deterministic ordering

The framework assigns a monotonic sequence number to each operation. The sidecar
returns the sequence number with its result. The framework applies results in
sequence order, regardless of the order the sidecar returns them.

```
Framework sends:    seq=1 create_product, seq=2 update_order, seq=3 delete_product
Sidecar returns:    seq=3 result, seq=1 result, seq=2 result
Framework applies:  seq=1 apply, seq=2 apply, seq=3 apply
```

The sidecar can process requests concurrently, in parallel, in any order. The
determinism lives in the framework's applier, not the sidecar's compute. This
is the same pattern as TigerBeetle's client protocol.

## Error handling split

Errors are split across three layers: framework, handle, and render.

**Framework handles infrastructure errors.** If storage returns `busy` (transient),
the framework retries next tick — the handler never runs. If storage returns `err`
(permanent), the framework skips the handler and sends `storage_error` status
directly to the render function. The user's `[handle]` function only runs when
prefetch succeeded and the data is in the cache.

**Handle decides domain errors.** The handler checks business logic and returns a
status: `ok`, `not_found`, `insufficient_inventory`, `version_conflict`, etc. It
never sees infrastructure errors.

**Render presents all errors.** The `[render]` function receives the status —
whether it came from the framework (`storage_error`) or the handler
(`insufficient_inventory`) — and returns HTML. In practice, render functions use
a single catch-all for all non-ok statuses:

```ts
// [render] .create_product
function renderCreateProduct(status, ctx) {
  if (status !== "ok") return `<div class="error">${esc(status)}</div>`;
  return `<div class="product">Created</div>`;
}
```

`storage_error` gets the same treatment as every other error — no special case
needed. The framework doesn't force the user to handle it explicitly because
the catch-all pattern already covers it. This holds for local SQLite (where
storage errors are rare) and for third-party databases (where network errors
are common) — the user's render function handles both without knowing the
difference.

## Sidecar failure

The sidecar is a separate process. It can crash, hang, or return garbage.

- **Timeout**: framework sets a deadline per request. If the sidecar doesn't
  respond, the in-flight request fails with a timeout status. The connection
  gets an error response. Other requests are unaffected.
- **Crash**: framework detects the closed socket, restarts the sidecar, fails
  in-flight requests. The Zig process never goes down.
- **Bad response**: framework validates the response (sequence exists, status is
  a known variant, writes reference valid entities). Invalid responses are
  treated as errors.

The framework is the supervisor. The sidecar is the worker.

## Latency budget

- Unix socket round-trip: ~5-10us
- Sidecar compute (pure logic over in-memory data): ~1-50us
- SQLite write (WAL mode): ~50-100us
- Network to client: ~1-50ms

The sidecar hop is noise. At 50us per call the framework handles 20,000
operations/second through the sidecar. A busy ecommerce site does 50-100 orders
per minute. Three orders of magnitude of headroom.

The bottleneck in a real deployment is SQLite write throughput or client network
latency, never the sidecar.

## What the user never touches

- `io.zig` — epoll, TCP, partial sends
- `connection.zig` — state machine, recv/send buffers
- `http.zig` — request parsing
- HTTP headers, Content-Length backfill, always-200
- SSE framing (event/data lines, selectors)
- The tick loop, follow-up scheduling, flush, close
- Keep-alive vs Connection: close
- Buffer allocation and lifecycle
- Storage reads/writes
- Deterministic ordering

## What the user defines

- Entity declarations (fields, references, operations) in their language
- Templates (HtmlWriter API) in their language
- Custom commit handlers for non-CRUD operations in their language
- Their packages, their ecosystem, their toolchain

## Correctness and the TigerBeetle tradeoff

TigerBeetle guarantees determinism by construction: control every byte, no
external calls, no runtime, no escape hatches. Tiger makes a different tradeoff
for a different goal.

Tiger's goal is domain logic correctness — the user's data is right. Not crash
safety, not Byzantine fault tolerance, not financial auditability. A CRUD
framework that occasionally shows a stale value before the next SSE update
corrects it is acceptable. A database that loses a transaction is not.

### What the framework guarantees mechanically

These hold regardless of what the sidecar does:

- **Deterministic ordering** — sequence numbers assigned by the framework,
  results applied in order. The sidecar cannot affect this.
- **Single writer** — only the framework writes to storage. The sidecar returns
  write intents. It has no storage handle.
- **Storage invariants** — the framework validates writes before applying them.
  Entity exists, version matches, foreign keys reference real entities, field
  sizes within bounds.
- **Connection/buffer lifecycle** — entirely in the framework. The sidecar
  cannot leak connections, corrupt buffers, or break SSE framing.
- **Boundary validation** — every sidecar response is validated. Known sequence,
  known status variant, writes reference valid entities. Malformed responses are
  rejected.
- **Timeout and supervision** — the sidecar gets a deadline. If it hangs, the
  request fails. If it crashes, the framework restarts it.

### Fuzz testing the full stack

The sidecar is fuzz-testable. The PRNG drives random operations through the
full stack — framework, sidecar, storage — and an auditor asserts correctness
after every operation. This is the same pattern as TigerBeetle's deterministic
simulation testing.

Determinism of the sidecar itself is verified by replay: run the same seed
twice, compare every response byte-for-byte. If they diverge, the sidecar is
non-deterministic and CI catches it.

The coverage is probabilistic, not proven. If the sidecar calls `Date.now()`
only when `order.quantity > 1000` and the fuzzer never generates a quantity
above 1000, every seed replays perfectly. The non-determinism exists but is
never triggered. This is the same limitation TigerBeetle's fuzzer has — it can
only find bugs on code paths it exercises. TB compensates by running millions
of seeds continuously and designing the PRNG to explore edge cases (weighted
enums, boundary values). Tiger does the same: more seeds, better weights,
longer sequences, run continuously.

### Purity by API design

The sidecar contract is a pure function: cache snapshot in, status and writes
out. The framework provides everything a handler might reach for
non-deterministically — IDs, timestamps, sequence numbers — in the request.
The handler has no reason to call `Date.now()`, `Math.random()`, or read from
the filesystem.

The realistic handler is arithmetic and comparisons over cached data:

```ts
function createOrder(cache, event) {
  const product = cache.get("product", event.product_id);
  if (product.inventory < event.quantity) return "insufficient_inventory";
  return {
    create: { order: { total_cents: product.price_cents * event.quantity } },
    update: { product: { inventory: product.inventory - event.quantity } },
  };
}
```

The residual risk is a transitive dependency doing something non-deterministic
that the developer doesn't know about — a library that logs to a file, a
validator that caches with a timestamp TTL. Replay testing catches this. It's
not provable, but it's sufficient for the goal.

### What's mechanical, what's probabilistic

Everything the framework controls is a mechanical guarantee — enforced by
construction, not by testing:

- Deterministic ordering
- Single writer
- Storage invariants
- Boundary validation
- Connection/buffer lifecycle
- Timeout and supervision

One thing is probabilistic: **whether the sidecar handler is a pure function.**
This is the only guarantee verified by replay testing instead of enforced by
construction. And it's only probabilistic if the user imports something that
introduces non-determinism on an untested code path. If the handler is
arithmetic over cache data — which it almost always is — replay passes on every
seed because there's nothing non-deterministic to find.

### Two modes

- **Zig handlers** — mechanical guarantee. Handlers are Zig functions in the
  same binary. Same compiler, same fuzzer, same assertions as the framework.
  No sidecar, no IPC, no serialization. A function call. The user who cares
  enough about mechanical determinism to choose it over probabilistic is
  already thinking like a systems programmer — they'll prefer Zig because it
  gives them the same control over their handler that the framework has over
  everything else.
- **Native sidecar** — probabilistic guarantee, any language, full ecosystem.
  Best DX, full package access, replay testing catches violations in CI.
  The user is building a CRUD app and wants to ship.

The framework supports both. The docs say which is which.

### The tradeoff

TigerBeetle chooses construction: control every byte, prove correctness
mechanically. Tiger chooses convention with testing: trust the sidecar contract,
verify with replay, catch violations in CI. The guarantee is weaker. The
adoption surface is every language. That's the trade.

## Worker determinism

In deterministic systems, users are responsible for providing a deterministic
replacement for their non-deterministic dependencies. For workers, users must
provide a mock for each external API call.

Example: login code generation uses the built-in `self.prng` to generate codes
deterministically. If a library with non-deterministic behavior is absolutely
needed, put it inside a worker — the system stays deterministic for free because
workers run outside the state machine boundary.

## What this gives you

A compiled, zero-alloc, single-threaded Zig server with all the performance and
deployment properties of tiger_web — but the user writes TypeScript, Python, Go,
Ruby, or whatever they want. The framework is the engine. The sidecar is where
the user lives.
