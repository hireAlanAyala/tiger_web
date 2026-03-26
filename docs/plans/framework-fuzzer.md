# Plan: Framework-provided fuzzer — `tiger-web fuzz`

## Context

The CFO found 8 bugs on its first 5-minute run. But the fuzzer that
found them (`fuzz.zig`) is hand-written with domain knowledge — it
knows how to generate products, orders, collections. A framework user
can't use it for their app without writing their own fuzzer.

No web framework provides automatic fuzzing. The user writes handlers,
the framework should fuzz them — zero test code required.

## What the framework knows

The annotation scanner already extracts everything needed to generate
valid requests:

- **Operations**: every `// [route]` with `// match METHOD /pattern`
- **Query params**: every `// query <name>`
- **Statuses**: every status returned by `// [handle]`
- **Dependencies**: which operations create entities (POST), which
  reference them (GET/PUT/DELETE with `:id` params)
- **Body shape**: the handler's `route()` function parses specific
  JSON fields — the scanner could extract field names from the body

## What the fuzzer does

`tiger-web fuzz` starts the sidecar + server and sends random requests:

### Level 1: Crash detection (no domain knowledge)
- Generate random valid-shaped HTTP requests from annotations
- Random method + matching pattern from route table
- Random 32-char hex IDs for `:id` params
- Random JSON bodies with fields the handler expects
- Assert: no sidecar crash, status is a known enum value, server stays alive
- This catches: null pointer errors, unhandled statuses, SQL errors,
  type mismatches, protocol bugs

### Level 2: State machine fuzzing (inferred dependencies)
- Track created entity IDs (POST → remember ID, GET/DELETE → use known ID)
- Infer dependencies from route patterns:
  - POST /products → creates, remember ID
  - GET /products/:id → references, use a known product ID
  - POST /orders → needs products to exist first
- Guarantee prerequisites: if an operation needs entities, ensure
  creates run first (same fix we just made in fuzz.zig)
- Assert: create → get returns ok, delete → get returns not_found

### Level 3: Auditor (domain-aware validation)
- After each mutation, query the entity and verify fields match
- Create product {name: "X", price: 100} → GET product → name is "X"
- This catches: silent data corruption, write-then-read inconsistencies
- Requires understanding the body schema (which fields to compare)

## How it works

### The user's experience

```bash
cd examples/ecommerce-ts
tiger-web fuzz                    # random seed, runs until stopped
tiger-web fuzz --seed=12345       # reproduce a specific failure
tiger-web fuzz --events=10000     # limited run (CI smoke)
```

Zero configuration. The framework reads annotations, generates requests,
exercises the handlers. The user sees: `10000 events, 0 failures` or
a panic with a seed number.

### Under the hood

1. Scanner generates a **fuzz manifest** — operations with their
   method, pattern, body schema, dependencies, statuses
2. Fuzz runner starts sidecar + server with `:memory:` database
3. PRNG generates operations (weighted, with swarm testing)
4. For each operation: build HTTP request from manifest, send via
   fetch(), check response
5. Track entity IDs for referential integrity
6. Assert invariants after each request

### Integration with CFO

The CFO already runs `tiger-web fuzz` equivalents:
```
./zig/zig build fuzz -- state_machine <seed>
```

The framework fuzzer would be an additional target:
```
./zig/zig build fuzz -- sidecar_e2e <seed>
```

This fuzzes through the sidecar pipeline (TypeScript handlers), not
the Zig native pipeline. Different code paths, different bugs.

The CFO runs both: native Zig fuzzers + sidecar e2e fuzzer.

## What makes this different from existing tools

**Property-based testing (QuickCheck, fast-check):**
Tests one function with random inputs. The user writes the property.
Our fuzzer tests the entire pipeline with zero user input.

**HTTP fuzzers (AFL, libFuzzer for HTTP):**
Fuzz the HTTP parser with random bytes. Our fuzzer generates
semantically valid requests — it knows the routes, the methods,
the body shape. It finds logic bugs, not parser bugs.

**API testing (Dredd, Schemathesis):**
Generate requests from OpenAPI specs. Require an OpenAPI spec.
Our annotations ARE the spec — no separate schema to maintain.

## Implementation phases

### Phase 1: Crash detection
- Generate random requests from annotations
- Start sidecar + server in-process
- Assert no crashes
- Report failing seed
- ~200 lines TypeScript (runs in the sidecar language)

### Phase 2: Entity tracking
- Track created IDs
- Use known IDs for GET/PUT/DELETE
- Dependency ordering
- Assert referential integrity
- ~300 additional lines

### Phase 3: Auditor
- Read-your-writes verification
- Field comparison after mutations
- Requires body schema extraction from handlers
- ~400 additional lines

### Phase 4: CFO integration
- Add `sidecar_e2e` fuzzer to CFO's fuzzer enum
- Weighted alongside native fuzzers
- Seeds pushed to devhubdb
- Same reproduction workflow

## The moat

No web framework provides this. A user creates a CRUD app with
annotated handlers and gets:
- Continuous fuzzing that finds bugs they'd never write tests for
- Deterministic reproduction with a seed number
- 24/7 background fuzzing via the CFO
- Zero test code required

This is a fraction of TigerBeetle's correctness, delivered to web
developers who would otherwise have no fuzzing at all.
