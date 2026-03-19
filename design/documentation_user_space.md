# User-space code design

## Annotations over handler maps

The sidecar uses comment annotations to bind functions to operations:

```typescript
// [execute] .create_product
export function createProduct(cache: PrefetchCache, body: Product): ExecuteResult { ... }
```

The alternative was a typed handler map with `satisfies`:

```typescript
export default {
  create_product: createProduct,
} satisfies HandlerMap;
```

The handler map gives live IDE errors (red squiggly on a missing
key). The annotation scanner only reports at build time. We chose
annotations for three reasons:

**Language-agnostic.** The scanner reads comments. Every language
has comments. One scanner implementation in the codegen gives
exhaustiveness checking to TypeScript, Python, Ruby, Go — any
language the sidecar supports. The handler map only works for
languages with structural typing (TypeScript, maybe Rust). If
community contributors build a Python sidecar, they get
exhaustiveness for free with annotations. With handler maps,
someone would need to build a Python-specific mechanism.

**No wiring file.** The handler map requires a file that imports
every handler and assembles them into one object. This is
boilerplate — it exists only to satisfy the type checker. With
annotations, each function is self-describing. The scanner
discovers them. No assembly required.

**Build-time is sufficient.** The annotation scanner runs during
`zig build codegen`, which the developer runs before deployment.
A missing handler is caught before any code reaches production.
Live IDE feedback is nice but not necessary — the guarantee is
the same.

For TypeScript specifically, the codegen also emits a `HandlerMap`
type as optional polish. Developers who want live IDE errors can
use it. But the annotation scanner is the foundation.

## Pipeline phases don't call each other

In Express or Rails, the developer controls the call chain:

```typescript
app.post('/products', validate, authenticate, async (req, res) => {
  const product = await prisma.product.create({ data: req.body });
  res.json(product);
});
```

The handler calls the ORM, which calls the database, which returns
a result, which the handler formats and sends. Each step is a
function call the developer writes and can get wrong — wrong order,
missing middleware, uncaught exception, forgotten await.

In the sidecar, the developer writes isolated phases:

```typescript
// [translate] .create_product
export function translateCreateProduct(method, path, body) { ... }

// [execute] .create_product
export function executeCreateProduct(cache, body) { ... }

// [render] .create_product
export function renderCreateProduct(status, result) { ... }
```

No phase calls the next. The framework drives the pipeline:
translate → prefetch → execute → render, always in that order,
for every operation, no exceptions. The developer returns values.
The framework passes them forward.

This is good for three reasons:

**Impossible to miswire.** You can't forget to call prefetch
before execute. You can't accidentally render before the database
write commits. You can't skip authentication — the framework
resolves identity during prefetch for every request. The pipeline
is not a suggestion; it's the architecture.

**Each phase is a pure function.** Translate takes HTTP inputs,
returns an operation. Execute takes cache + body, returns status +
writes. Render takes a result, returns HTML. No side effects, no
shared mutable state, no async. Every phase is independently
testable — pass inputs, check outputs.

**The simulator can test the full pipeline.** Because phases don't
call each other, the simulator can inject faults between them —
storage errors during prefetch, cache corruption between prefetch
and execute. In Express, the only way to test the full pipeline is
an integration test with a real database. Here, the simulator
exercises every phase boundary with deterministic seeds.

The tradeoff: you can't add custom middleware between phases. No
"log every request before execute" hook. No "transform the result
after render" step. The pipeline is fixed. This is the constraint
that makes the guarantees possible — the same constraint TigerBeetle
applies to its own request pipeline.
