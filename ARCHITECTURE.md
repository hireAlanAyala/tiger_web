# Architecture

## Request Pipeline

A request flows through four layers. Each layer has one job, trusts the layer before it, and passes typed data to the next.

```
         HTTP wire
            │
            ▼
┌──────────────────────┐
│  http.zig            │  Parse HTTP method/path/body, encode HTTP responses.
│  (wire format)       │  Knows nothing about products or operations.
└──────────┬───────────┘
           │  Method, path string, body bytes
           ▼
┌──────────────────────┐
│  schema.zig          │  Translate (method, path, body) → typed Message.
│  (boundary)          │  Translate MessageResponse → (HTTP status, JSON body).
└──────────┬───────────┘
           │  Message / MessageResponse
           ▼
┌──────────────────────┐
│  state_machine.zig   │  Prefetch: read from storage into cache.
│  (logic)             │  Execute: decide from cache, write to storage.
└──────────┬───────────┘
           │  StorageResult
           ▼
┌──────────────────────┐
│  storage             │  MemoryStorage (sim/test) or SqliteStorage (prod).
│  (persistence)       │  Fixed arrays or SQLite. No business logic.
└──────────────────────┘
```

Types live in `message.zig` — shared vocabulary across all layers.

## Two Result Types

There are two enums that look similar but serve different layers.

### StorageResult

```zig
pub const StorageResult = enum { ok, not_found, err, busy, corruption };
```

Storage-layer concern. Returned by `MemoryStorage` and `SqliteStorage` methods. Meaning:

| Variant | Meaning | Who handles it |
|---|---|---|
| `.ok` | Operation succeeded | — |
| `.not_found` | Entity doesn't exist | State machine maps to `Status.not_found` |
| `.err` | Storage-level failure (capacity full, constraint violation) | `commit_write` maps to `Status.storage_error` |
| `.busy` | Storage temporarily unavailable | Prefetch returns false, connection retries next tick |
| `.corruption` | Data integrity violation | `@panic` — unrecoverable |

`.err` here means the *storage layer* couldn't fulfill the request — disk full, array full, SQLite constraint. The state machine doesn't interpret why; it just reports 503 to the client.

### Status

```zig
pub const Status = enum(u8) {
    ok = 1,
    not_found = 2,
    storage_error = 4,
    insufficient_inventory = 10,
};
```

Client-facing concern. Carried by `MessageResponse`, translated by schema.zig into HTTP status codes and JSON error bodies. Each variant is a named result — no generic error bucket.

| Variant | HTTP | JSON body | Produced by |
|---|---|---|---|
| `.ok` | 200 | (operation-specific payload) | All successful operations |
| `.not_found` | 404 | `{"error":"not found"}` | Get/delete/update when entity missing |
| `.storage_error` | 503 | `{"error":"service unavailable"}` | `commit_write` on capacity full |
| `.insufficient_inventory` | 409 | `{"error":"insufficient_inventory"}` | `execute_transfer_inventory` |

New business logic failures get new variants here. The state machine says *what* went wrong; schema.zig decides *how* to tell the client.

### The Seam

The state machine sits between these two enums. It consumes `StorageResult` from storage and produces `Status` for the client. The mapping is not 1:1 — it's a decision:

```
StorageResult.ok         →  (proceed with execute logic)
StorageResult.not_found  →  Status.not_found  (or proceed, depends on operation)
StorageResult.err        →  Status.storage_error  (via commit_write)
StorageResult.busy       →  (retry next tick, no Status produced)
StorageResult.corruption →  @panic

Execute logic            →  Status.ok  (success)
                         →  Status.insufficient_inventory  (business rule violated)
                         →  Status.not_found  (entity disappeared between prefetch phases)
```

Storage failures are generic (the state machine doesn't know *why* storage failed). Business logic failures are specific (the state machine knows exactly what rule was violated). This separation is intentional — storage is infrastructure, business rules are the application.

## Prefetch / Execute Split

Every operation runs in two phases:

**Prefetch** — read-only. Fetches everything the operation might need from storage into fixed cache slots on the state machine. Can fail with `.busy` (retry next tick) or `.err` (report 503). Never writes to storage.

**Execute** — write-only. Reads from cache slots (never from storage), makes business logic decisions, writes mutations to storage. Writes are infallible — prefetch proved the entities exist, and the write is a memcpy into an occupied slot. If a write somehow fails, it's an invariant violation (`assert`).

```
prefetch can fail    →  retry (busy) or report error (err)
execute cannot fail  →  assert on write, specific Status on business logic
```

This mirrors TigerBeetle's two-phase commit: prefetch populates the page cache, execute operates on cached data and writes to the infallible memtable.

## Prefetch Cache

Flat struct with named slots, reset between operations:

```zig
prefetch_product: ?Product                     // one product
prefetch_product_list: ProductList              // up to 50 products
prefetch_collection: ?ProductCollection         // one collection
prefetch_collection_list: CollectionList        // up to 50 collections
prefetch_result: ?StorageResult                 // outcome of the prefetch phase
```

Simple operations use singular slots. Multi-entity operations use list slots — `transfer_inventory` reads source into `items[0]` and target into `items[1]`. `get_collection` fills both `prefetch_collection` and `prefetch_product_list`.

## Fault Injection

Two independent fault injection systems, both PRNG-driven:

**SimIO** — injects network faults (partial sends, recv failures, accept failures). Exercises connection state machine recovery.

**MemoryStorage** — injects storage read faults (`busy_fault_probability`, `err_fault_probability`). Only on reads (get, list). Writes have no fault injection — they're infallible by design. Exercises the prefetch retry and error reporting paths.

Both use `splitmix64` with deterministic seeds for reproducible test runs.

## Connection Lifecycle

```
accepting → receiving → ready → sending → receiving (keep-alive)
                                       → free (close)
```

Driven by `server.zig`'s tick loop. The server iterates connections each tick: submits recvs for receiving connections, runs prefetch+execute for ready connections, submits sends for sending connections. IO callbacks only update connection state — they never call into the application.

## Operation Dispatch

`message.Operation` is a flat enum. Each variant encodes entity type and action:

```
create_product, get_product, update_product, delete_product,
get_product_inventory, transfer_inventory,
create_collection, get_collection, delete_collection, list_collections,
add_collection_member, remove_collection_member
```

`Operation.EventType()` resolves the typed event for each operation at comptime. `execute()` uses `inline` switch so each handler receives a comptime-known operation, enabling type-safe dispatch with dead branch elimination.
