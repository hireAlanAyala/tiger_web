# Divergences from TigerBeetle

This project follows TigerBeetle conventions closely. This document records where we intentionally diverge and why — the differences are driven by being a single-node HTTP server rather than a replicated consensus system.

## No Idempotency / Reply Cache

TigerBeetle gives every request a unique checksum and caches replies per client session. If a response is lost, the client retries the exact same request and the replica returns the cached reply without re-executing.

We don't need this. HTTP clients (browsers, frontend code) already handle retries — if a connection drops mid-request, the client retries. PUT is naturally idempotent (same key+value → same result regardless of how many times it's applied). There's no replication log where the same operation could be committed twice by different replicas. A single-node KV store has no ambiguity about whether a write executed — the client just reconnects and retries.

**Consequence for testing:** Our fault injection fuzzer can't use an oracle to verify per-operation correctness under faults, because we can't distinguish "executed but response lost" from "never executed." TigerBeetle's StateChecker can, because it watches the commit log directly. Our fault tests verify liveness and structural integrity instead.

## No Client Sessions

TigerBeetle tracks client sessions with eviction and maps each client to exactly one inflight request. This enables duplicate detection and linearizable semantics across retries.

Our connections are stateless HTTP. Each request is independent. Connection keep-alive is a transport optimization, not a session guarantee. No client tracking beyond the TCP connection lifetime.

## No Replication / Consensus

TigerBeetle's IO layer, tick loop, and message pipeline are all designed around multi-replica consensus (VSR). The server is a "replica" that participates in a cluster.

We have one process, one state machine. The tick loop drives a single accept → recv → execute → send pipeline. No prepare/commit distinction, no view changes, no repair protocol.

## HTTP/JSON Instead of Binary Protocol

TigerBeetle uses a custom binary protocol where the struct layout *is* the wire format. Clients are compiled-language libraries (Go, Rust, C, Java) that share the same struct layout as the server — an `Account` struct in Go is byte-identical to the Zig `Account` struct. No serialization on either side. The client passes `unsafe.Pointer(&accounts[0])` directly into the packet, and the server reinterprets the bytes as typed structs. Replies work the same way: the state machine writes result structs into an `output_buffer`, and the client casts the bytes back.

This only works because TigerBeetle controls the client libraries and targets languages with deterministic struct layout. Our clients are browsers. JavaScript has no fixed-layout structs — even with `ArrayBuffer` and `DataView`, constructing and parsing binary structs is manual serialization with extra steps. Every browser API (fetch, WebSocket, WebTransport) has the same limitation: the JS side must encode/decode regardless of the transport.

This is why we have `schema.zig` — a layer that doesn't exist in TigerBeetle. It translates between HTTP/JSON at the edge and typed structs internally:

- **Inbound:** `schema.translate()` parses HTTP method + path + JSON body into a typed `Message`
- **Outbound:** `schema.encode_response_json()` serializes a `MessageResponse` back to JSON

The state machine never sees HTTP or JSON, same as TigerBeetle's never sees wire bytes. The boundary separation is identical — we just have an extra translation step at the edges that TigerBeetle avoids by controlling both sides of the protocol.

## Allocator at Init

TigerBeetle's state machine uses fixed-capacity data structures sized at comptime. No allocator touches the hot path.

Our `MemoryStorage` takes an allocator at `init` to allocate fixed-size backing arrays, then never allocates again. The hot path (get/put/delete) is allocation-free.

## No Graceful Shutdown

TigerBeetle intentionally installs no signal handlers. The replica runs `while (true) { tick(); io.run_for_ns(); }` and lets the OS kill the process. This is safe because the consensus protocol recovers from peer replicas.

We follow the same pattern. Our store is in-memory — all state is lost on any exit regardless of how gracefully it happens. Draining in-flight responses on SIGTERM doesn't save data. The client sees a connection reset and retries, same as any network failure. No signal handlers, no drain logic, no shutdown timeout.

## Storage Parameterization

TigerBeetle's state machine operates directly on its LSM tree and forest structures. The storage layer is tightly integrated — the state machine prefetches from the grid/forest and executes deterministic logic on the cached data. The storage backend isn't swappable because TigerBeetle always uses the same on-disk format.

We parameterize `StateMachineType(comptime Storage: type)` so the same state machine works with `SqliteStorage` in production and `MemoryStorage` in simulation. This duck-typed comptime interface follows the same pattern as `ServerType(comptime IO)` — the compiler monomorphizes the code, zero runtime dispatch.

The prefetch/execute split mirrors TigerBeetle's two-phase approach: `prefetch()` fetches data from storage into fixed cache slots on the state machine, and `execute()` reads only from those cache slots. If storage returns `.busy` (SQLite's `SQLITE_BUSY`), the connection stays in `.ready` state and is retried on the next tick — no new connection states needed.

`MemoryStorage` supports PRNG-driven fault injection (`busy_fault_probability`, `err_fault_probability`) using the same `splitmix64` pattern as `SimIO`. See "Infallible Execute Writes" below for why faults only apply to reads.

## Infallible Execute Writes (Aligned with TigerBeetle)

TigerBeetle's `create_transfer` (state_machine.zig:3634) has the comment `// After this point, the transfer must succeed.` followed by three writes — insert transfer, update debit account, update credit account. All three write to the LSM tree's in-memory memtable via `grooves.transfers.insert()` and `grooves.accounts.update()`. These functions return `void` — they literally cannot fail. The memtable is pre-allocated at comptime to hold a full batch. Persistence happens later through compaction and the WAL, managed by the replication layer, not the state machine.

We follow the same model: **prefetch can fail, execute cannot.** Read operations (get, list) in `MemoryStorage` call `fault()` which rolls the PRNG against `busy_fault_probability` and `err_fault_probability`. Write operations (put, update, delete, add_to_collection, remove_from_collection) do not call `fault()`. The actual write is a memcpy into a pre-allocated array slot that prefetch already proved exists — it's inherently infallible.

This means `execute_transfer_inventory` can do two sequential writes and assert both succeed:

```zig
// After this point, the transfer must succeed.
assert(self.storage.update(source.id, &source) == .ok);
assert(self.storage.update(target.id, &target) == .ok);
```

No partial-write concern, no rollback logic, no transaction wrapper.

**Why not simulate write failures?** For `MemoryStorage`, there's nothing to simulate — the write is an array overwrite with no I/O. For `SqliteStorage` on a monolith VPS, write failures (SQLITE_FULL, SQLITE_IOERR) mean the machine is dying — disk full or hardware failure. The correct response is crash-with-a-message (`@panic`), not graceful error handling, because the server can't serve requests without its storage. This matches TigerBeetle's approach to storage corruption.

**One exception:** `put()` can return `.err` for capacity full (all array slots occupied). This is a real resource limit, not a storage failure — it's handled via `commit_write` returning 503 to the client. If this ever needs to be an assert, the fix is to check capacity in prefetch.

## Flat Prefetch Cache (Divergence from TigerBeetle)

TigerBeetle's prefetch uses a forest of grooves (LSM trees), each backed by a page cache. An operation calls `grooves.accounts.prefetch_enqueue(id)` for each account it needs, then `grooves.accounts.prefetch(callback)`. The groove ensures those pages are in memory when the callback fires. Any number of entities of any type can be prefetched — the cache is the page cache itself.

We use a flat struct with named slots:

```
prefetch_product: ?Product                    — one product
prefetch_product_list: ProductList             — up to 50 products
prefetch_collection: ?ProductCollection        — one collection
prefetch_collection_list: CollectionList       — up to 50 collections
```

Each operation clears the cache and fills the slots it needs. Simple operations use the singular slots (get_product fills `prefetch_product`). Multi-entity operations use the list slots — `transfer_inventory` reads both source and target products into `prefetch_product_list` items 0 and 1. `get_collection` fills both `prefetch_collection` (the collection entity) and `prefetch_product_list` (its member products).

This is simpler than a groove/page-cache system and works well for our operation set. The limitation is that operations needing two entities of the same type (two products, two collections) must use the list slots rather than dedicated singular slots. This is an acceptable trade — the list slots hold up to 50 entries, which accommodates any foreseeable multi-entity operation. If the flat cache becomes restrictive (e.g., an operation needing both a product list and specific products), a migration path exists toward a prefetch set keyed by (entity_type, id).

## Flat Operation Enum (Aligned with TigerBeetle)

TigerBeetle uses a flat `Operation` enum where each variant encodes both entity type and action (`create_accounts`, `create_transfers`, etc.). Comptime functions `EventType()` and `ResultType()` on the enum resolve the input and output types for each operation at compile time.

We follow the same pattern: `create_product`, `get_collection`, `add_collection_member`, etc. `EventType()` on `Operation` drives the inline dispatch in `execute()` — it resolves the typed event parameter for each handler at compile time. We don't have `ResultType()` because our results flow through a tagged `Result` union rather than raw byte buffers; the result variant is selected per-operation inside each handler.

`execute()` uses `inline` switch to group operations by shared control flow pattern (get, list, create, delete), following TigerBeetle's `commit()` pattern. Each handler takes `comptime op: Operation` and uses comptime switches internally — dead branches are pruned by the compiler, so `storage.put(&event)` with the wrong event type never compiles.

`event_tag()` on `Operation` derives the expected `Event` tag from `EventType()` via `inline else` — the type→tag mapping exists in one place. `prefetch()` uses this as a pair assertion: `assert(msg.event == msg.operation.event_tag())`. schema.zig constructs messages, state_machine.zig consumes them — the assertion at the consumption boundary catches any mismatch. This is a runtime check, not a compile-time guarantee (the old nested union made invalid pairings unrepresentable), but it surfaces bugs immediately in tests.

## Synchronous Prefetch (Divergence from TigerBeetle)

TigerBeetle's prefetch is async with callback chains — it enqueues reads, submits to IO, and chains callbacks when multi-entity prefetches are needed (e.g., prefetch transfers → callback → prefetch accounts → callback → done). This is necessary because TigerBeetle's storage is an LSM tree with disk IO.

Our prefetch is synchronous — both `MemoryStorage` and `SqliteStorage` return immediately. `prefetch_collection_with_products()` does two sequential reads in one call. If either returns `.busy`, the whole prefetch returns false and retries next tick. This is a valid simplification for a single-node HTTP server where storage access doesn't require async IO.

## Error Response on Unmapped Requests

TigerBeetle silently drops malformed messages. This makes sense for a binary protocol where clients are generated SDKs — a malformed message means a bug in the SDK, not a user mistake. There's no human to inform.

Our clients are browsers and developers with curl. When `translate()` fails (unknown route, bad JSON, invalid UUID), the request parsed as valid HTTP — we just can't route it. Closing the connection silently gives the developer `curl: (52) Empty reply from server` with no indication of what went wrong.

We send a short `200 OK` with `"invalid request"` body before closing. Same always-200 convention as every other response — errors go in the body. The departure from TB's silent-drop is justified by the client type: humans deserve feedback, generated SDKs don't need it.

Invalid HTTP (can't parse the frame at all) still closes silently — if we can't parse the request, we can't reliably frame a response.

## Single Writer — Consequences of External DB Writes

The framework assumes it is the sole writer to the database. External writes are unsupported — the framework is designed around single-writer semantics and we don't provide tooling or guarantees for multi-writer scenarios. That said, if a user bypasses the framework and writes directly to SQLite:

- **Server** — keeps running, serves correct responses for whatever data is in the DB
- **WAL** — incomplete, replay can't reproduce current state (debugging degraded, not broken)
- **Auditor** — unaffected, only runs in fuzz tests against its own model
- **Fuzz suite** — unaffected, drives operations through the framework API
- **Race conditions** — yes, same as any concurrent writer, not framework-specific
- **Assertions** — won't fire, they validate the state machine's own writes, not external ones

The single-writer principle protects your debugging tools (replay), not the running server. If external writes are needed, route them through the framework's HTTP API — the worker pattern does this — so the WAL logs them and the state machine sees them.

### Third-party databases

Also not recommended, but the framework could run against a remote database (Postgres, Turso, etc.) instead of local SQLite. The `Storage` interface is comptime duck-typed — any backend that implements `get`, `put`, `update`, `delete`, `list`, `begin`, `commit` works. `begin`/`commit` are already optional by convention (`MemoryStorage` no-ops them).

What degrades:
- **Replay** — WAL still logs locally, but `tiger-replay diff` would compare against a remote DB instead of a local file
- **Prefetch latency** — synchronous prefetch over the network blocks the tick loop. At 5ms per round-trip, throughput drops from ~20,000 ops/sec to ~200. For a remote DB, prefetch would need to become async (the TigerBeetle pattern we intentionally skipped — see `plans/patterns-to-revisit.md`)
- **Transactions** — depends on what the remote DB supports. No multi-statement transactions means no per-tick atomicity

What works fine: single-writer semantics, the auditor, fuzz testing, the sidecar, all framework guarantees. The storage backend is behind a comptime interface — the framework doesn't know or care what's on the other side.

With multiple writers against a shared remote DB, the stale-read risk is the same as any other application — Rails, Django, Express all need optimistic locking or transactions for the same reason. The framework isn't worse here, it's just not special. The determinism guarantee weakens from "provable" to "best effort within our boundary," but the architecture still does more work for you than anything else in the space.

## Single-Threaded, No IO Batching

TigerBeetle batches IO submissions and completions through io_uring, processing multiple operations per syscall. The IO layer is designed for high-throughput concurrent replication traffic.

We use epoll with one-at-a-time completions. Each connection has at most one pending recv or send. This is sufficient for an HTTP server where each connection processes one request at a time. No batching needed.
