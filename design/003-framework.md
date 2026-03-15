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
be declared separately.

## User space

The user declares entities, operations, types, and templates. The framework
derives everything else.

```zig
const app = tiger.App{
    .entities = .{
        .product = tiger.Entity(Product){
            .operations = .{
                .create = .{ .method = .post, .path = "/products" },
                .update = .{ .method = .put, .path = "/products/:id", .optimistic_lock = .version },
                .get    = .{ .method = .get, .path = "/products/:id" },
                .delete = .{ .method = .delete, .path = "/products/:id" },
                .list   = .{ .method = .get, .path = "/products" },
            },
            .card = render_product_card,
            .detail = render_product_detail,
        },
    },
};
```

From this the framework generates at comptime:

- Operation enum
- EventType / ResultType mappings
- Codec routing (method + path -> operation)
- Prefetch plans (get/update/delete -> fetch by ID, list -> fetch with params)
- Commit handlers for standard CRUD (create writes, update merges + version check, delete removes)
- SSE selectors (entity name -> `#product-list`)
- Follow-up wiring (POST/PUT/DELETE are mutations, GET is a read)
- Buffer sizing (worst-case from entity struct sizes + list_max)

## Custom logic hatch

When an operation needs real business logic, the user provides a Zig function:

```zig
.order = tiger.Entity(Order){
    .operations = .{
        .create = .{
            .method = .post,
            .path = "/orders",
            .commit = create_order,
            .prefetch = prefetch_order,
        },
    },
},
```

The custom handler is plain Zig with the same types and the same constrained
signature as generated handlers. No different language, no different debugger.
Replace the generated handler, keep everything else.

## Mechanical enforcement

The framework turns conventions into structure. Things that are currently
"the programmer must remember" become "the compiler won't let you forget."

### Commit never calls storage

Today the invariant "commit only reads from cache, never from storage" is a
convention. Nothing stops a commit handler from calling `storage.get()`.

The framework enforces it by type signature. Commit receives `*const Cache`
(read-only, no storage handle). Custom handlers get the same constrained
signature — they literally cannot call storage because it's not in scope.

### Exhaustiveness at the entity level

Today, adding a new entity means adding arms to exhaustive switches across 6
files: Operation variants, EventType, ResultType, codec routes, prefetch, commit,
render, error selectors. Miss one and you get a compile error, but it's scattered.

With the schema, adding an entity is one declaration. The framework generates all
the arms. You can't forget the codec route because you didn't write it. The only
user-provided piece is the template function, enforced by comptime assertion.

### Follow-ups are automatic

Today, if you add a mutation and forget to update `is_mutation`, the dashboard
shows stale data after the mutation. Silent bug.

The framework derives mutation status from the HTTP method. POST/PUT/DELETE are
mutations. GET is a read. Follow-up wiring, two-cycle scheduling, SSE fragment
rendering — all derived, not hand-written.

### Buffer sizing covers all entities

Today, buffer sizing is a comptime computation over manually listed types. If a
new entity's worst-case output exceeds the buffer, it's a runtime panic.

The framework iterates all entity types at comptime and computes the worst case
automatically. Adding an entity with larger fields updates the buffer size
without touching the sizing code.

## What the user never touches

- `io.zig` — epoll, TCP, partial sends
- `connection.zig` — state machine, recv/send buffers
- `http.zig` — request parsing
- HTTP headers, Content-Length backfill, always-200
- SSE framing (event/data lines, selectors)
- The tick loop, follow-up scheduling, flush, close
- Keep-alive vs Connection: close
- Buffer allocation and lifecycle

## What the user defines

- Entity types (Zig structs with fixed-size fields)
- Operations (declared on entities with method + path)
- Template functions (HtmlWriter + entity -> HTML)
- Custom commit/prefetch handlers for non-CRUD operations
- Status variants for custom error conditions

## 90/10

In tiger_web today: 13 operations are standard CRUD, 3 have custom logic. The
framework handles the 13 from declarations. The 3 are plain Zig functions with
constrained signatures. The schema and the hatch are the same language, the same
types, the same compiler. There's no boundary to cross.
