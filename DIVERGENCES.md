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

## HTTP Instead of Binary Protocol

TigerBeetle uses a fixed-size binary message protocol with checksums, operation codes, and header/body separation designed for zero-copy processing.

We parse HTTP/1.1 text — variable-length headers, Content-Length framing, URL-decoded keys. The HTTP parser (`http.zig`) is a pure function with no allocations, which keeps it close to TigerBeetle's style, but the format itself is fundamentally different.

## Allocator at Init

TigerBeetle's state machine uses fixed-capacity data structures sized at comptime. No allocator touches the hot path.

Our `StateMachine` takes an allocator at `init` to allocate the hash map backing storage, then never allocates again. This is a pragmatic choice — Zig's `HashMap` needs an allocator for its backing array. The hot path (get/put/delete) is still allocation-free.

## Single-Threaded, No IO Batching

TigerBeetle batches IO submissions and completions through io_uring, processing multiple operations per syscall. The IO layer is designed for high-throughput concurrent replication traffic.

We use epoll with one-at-a-time completions. Each connection has at most one pending recv or send. This is sufficient for an HTTP server where each connection processes one request at a time. No batching needed.
