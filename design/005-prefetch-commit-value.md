# Design 005: What Prefetch/Commit Gives Us

## What we get

### 1. Atomic domain modeling

The split makes it structurally impossible to interleave reads and writes within
an operation. This forces mutations like `create_order` to be modeled as atomic
units: read all N products upfront in prefetch, then validate all inventory
checks, then decrement all, then write all. If item 3 of 5 fails validation,
items 1 and 2 haven't been modified. There's no partial state to roll back.

Without the split, a developer naturally writes: read product, check inventory,
decrement, write, read next product, check, decrement, write. If the third
product fails, the first two are already decremented. Now you need explicit
rollback logic or transaction aborts to undo partial work.

The split eliminates that class of bug by construction.

### 2. Frozen snapshot for execute

Execute sees only the data that prefetch loaded. It never wonders whether it's
reading its own write, stale data, or data modified by a different operation
earlier in the tick. The inputs are fixed at the top of execute. The function
is close to pure — given these cached entities and this event, what happens?

### 3. Single point for back-pressure

Prefetch is the only place that handles `busy` (storage unavailable). Execute
never checks for it. If you collapse reads into execute, every storage call
inside business logic needs error handling for busy. With the split, one place
handles it — not twenty.

### 4. Single hook point for production replay

`commit()` is the single entry point for all state changes. Logging the
`Message` at that point captures the complete input to the state transition.
No other information is needed to reproduce it — execute never reads storage,
so the message alone is sufficient. This makes production replay (design/004)
straightforward: one hook, not scattered across every handler.

### 5. Discipline against a common habit

Interleaving reads and writes inside business logic is the default in most web
frameworks. Rails controllers, Express handlers, Django views — they all
encourage fetch-mutate-fetch-mutate inline. The prefetch/commit split makes
that structurally impossible. Developers who default to interleaving are forced
into a saner pattern.

### 6. Clean sidecar boundary for runtime-agnostic framework

The split is exactly where the framework ends and user code begins. Prefetch is
the framework's job — storage, caching, busy signals, back-pressure. The sidecar
never sees any of that. It receives already-fetched data and returns a decision.

Without the split, the sidecar would need to call back into the framework to
read storage mid-handler. That means a protocol for "send me entity X," waiting
for the response, then continuing — async RPC inside business logic, storage
fault handling in user code, and the framework unable to know upfront what data
the handler needs.

With the split, the contract is one round trip: the framework sends all the data
the operation needs in one message over a unix socket, the sidecar sends back
the mutation result in one message. No callbacks, no storage access from user
code, no shared state. The sidecar can be Python, TypeScript, Go — anything that
reads a struct and writes one back.

Read-only operations don't need a sidecar handler at all. If no handler is
registered, the framework prefetches and returns the data directly. The sidecar
only exists for mutations — the 20% that has real logic.

### 7. Cheap for reads, enforced for writes

9 of 20 operations are read-only. Their execute handlers are one-line cache
unwraps — trivial ceremony. The framework can auto-generate these entirely
(if an operation has no commit handler, return the prefetched data). The
overhead exists so that the 11 mutation operations — where the risk lives —
can't be written wrong. The easy 80% pays a small tax so the hard 20% stays
flat in complexity as the app grows.

## What we don't get (and why we don't need it)

### Async I/O batching

TigerBeetle's prefetch enqueues all keys, then issues one batched async disk
read through io_uring. The kernel fetches all LSM tree pages in parallel. The
callback fires when they're all in cache.

We use SQLite in WAL mode with a single thread and single connection. Our reads
are synchronous `sqlite3_step()` calls hitting SQLite's page cache — effectively
memcpys from RAM. There's no disk I/O latency to batch away and nothing to
parallelize against on one thread. SQLite's internal locking would serialize
parallel reads anyway — it wasn't designed for scatter-gather I/O.

### Batch amortization across items

A single TigerBeetle message contains up to 8,190 accounts or transfers.
Prefetch enqueues all their IDs in one pass, then issues one batched disk read.
Commit processes each item against the cache.

Each of our messages is one operation — one product, one order. There's no batch
of thousands of items to amortize I/O across. `prefetch_multi` reads N products
in a loop of individual `storage.get()` calls. The split doesn't buy batching
because there's nothing to batch.

### Linked chain rollback

TigerBeetle supports linked events — a chain of operations that either all
succeed or all roll back via `scope_open`/`scope_close`. The split guarantees
all data is cached before the chain starts, so rollback never triggers new reads.

We have no linked event chains. Each operation is independent. Our atomicity
comes from the tick-level `begin_batch`/`commit_batch` transaction — if the
server crashes mid-tick, no responses have been sent yet, so clients see a
disconnect and retry. We don't need per-operation rollback because we don't
have multi-operation chains.

### Deterministic replay across replicas

TigerBeetle is a replicated state machine. Multiple replicas process the same
operations in the same order. Prefetch pins a snapshot at a specific `op` number
so every replica sees identical data for the same operation. Without this,
subtle differences in LSM compaction state could cause replicas to diverge.

We're a single server with no replication. There's one copy of the state. The
determinism question doesn't arise — there's no second replica to diverge from.
If we ever need production replay (design/004), it's against the same storage
engine, not a separate replica.
