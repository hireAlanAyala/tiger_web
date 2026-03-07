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

Our `StateMachine` takes an allocator at `init` to allocate the hash map backing storage, then never allocates again. This is a pragmatic choice — Zig's `HashMap` needs an allocator for its backing array. The hot path (get/put/delete) is still allocation-free.

## No Graceful Shutdown

TigerBeetle intentionally installs no signal handlers. The replica runs `while (true) { tick(); io.run_for_ns(); }` and lets the OS kill the process. This is safe because the consensus protocol recovers from peer replicas.

We follow the same pattern. Our store is in-memory — all state is lost on any exit regardless of how gracefully it happens. Draining in-flight responses on SIGTERM doesn't save data. The client sees a connection reset and retries, same as any network failure. No signal handlers, no drain logic, no shutdown timeout.

## Storage Parameterization

TigerBeetle's state machine operates directly on its LSM tree and forest structures. The storage layer is tightly integrated — the state machine prefetches from the grid/forest and executes deterministic logic on the cached data. The storage backend isn't swappable because TigerBeetle always uses the same on-disk format.

We parameterize `StateMachineType(comptime Storage: type)` so the same state machine works with `SqliteStorage` in production and `MemoryStorage` in simulation. This duck-typed comptime interface follows the same pattern as `ServerType(comptime IO)` — the compiler monomorphizes the code, zero runtime dispatch.

The prefetch/execute split mirrors TigerBeetle's two-phase approach: `prefetch()` fetches data from storage into fixed cache slots on the state machine, and `execute()` reads only from those cache slots. If storage returns `.busy` (SQLite's `SQLITE_BUSY`), the connection stays in `.ready` state and is retried on the next tick — no new connection states needed.

`MemoryStorage` supports PRNG-driven fault injection (`busy_fault_probability`, `err_fault_probability`) using the same `splitmix64` pattern as `SimIO`. This lets sim tests verify that busy faults cause retries and storage errors produce 503 responses.

## Single-Threaded, No IO Batching

TigerBeetle batches IO submissions and completions through io_uring, processing multiple operations per syscall. The IO layer is designed for high-throughput concurrent replication traffic.

We use epoll with one-at-a-time completions. Each connection has at most one pending recv or send. This is sufficient for an HTTP server where each connection processes one request at a time. No batching needed.
