# Sidecar: shared memory transport

Close the sidecar performance gap from 25% of native to ~49%.

## Problem

The sidecar is 3.9x slower than native Zig (13K vs 53K req/s). The
cost is 3 Unix socket round trips per request, not the TypeScript
runtime. Per-request socket overhead is ~58μs (77μs total minus 19μs
native work), split across 6 syscalls (3× send + 3× recv).

Measured data (i7-14700K, 128 connections, 100K requests):
- Native Zig: 53,048 req/s, p50=2ms, p99=2ms
- Sidecar (TypeScript, Unix socket): 13,642 req/s, p50=7ms, p99=22ms

## Decision framework

Every option was evaluated against TigerBeetle's stated design
principles, in their priority order: Safety > Performance > DX.

| Principle | TB's words |
|---|---|
| **Safety** | "It is far better to stop operating than to continue operating in an incorrect state." |
| **Determinism** | "Same input, same output, same physical path. Supercharges randomized testing." |
| **Boundedness** | "Put a limit on everything. All loops, all queues must have fixed upper bounds." |
| **Fuzzable** | "Assertions are a force multiplier for discovering bugs by fuzzing." |
| **Right primitive** | "Zero technical debt. Simplicity is the hardest revision." |
| **Explicit** | "Be explicit. Minimize dependence on the compiler to do the right thing for you." |

## Options explored

### Transport signaling

The spread between signaling mechanisms is ~6μs — negligible on a
40μs request. The real decision is socket → shared memory (~50μs
saved), not which signal to use. Every option was evaluated against
all six TB principles.

| Mechanism | Overhead (2 RTs) | TB violations |
|---|---|---|
| Spin-wait | ~2μs | **Boundedness**: burns a full core, no upper bound on CPU if sidecar is slow. **Determinism**: timing-dependent by construction. |
| Spin-then-futex | ~3μs | **Right primitive**: two code paths for 3μs — "zero technical debt" means don't add complexity you don't need. Sim CAN test both paths (determinism concern was overstated), but the complexity is real. |
| Pure futex | ~8μs | None. One code path, deterministic, bounded by timeout, fuzzable, is the primitive (eventfd and spin are built on top). |
| eventfd | ~10μs | **Right primitive**: abstraction over futex + counter + fd, designed for epoll bridging. We don't need epoll integration (blocking exchange). Using it is using the wrong tool. |
| io_uring futex | ~6μs | **Right primitive**: not using io_uring for anything else. **Safety**: 50K+ lines of kernel dependency surface. TB built their own IO ring for control. |

**Chose futex.** Only option that passes all six columns. It IS the
primitive — atomic compare-and-wait on a u32. One code path.
Deterministic. Bounded by timeout. No fds, no kernel buffers, no
abstraction layers. Every language can call it.

### Transport mechanism

| | Unix socket (current) | Shared memory + futex |
|---|---|---|
| **Safety** | Frame parser reads length-prefixed data — malformed length can read past buffer bounds (WAL aliasing bug was this class). | Fixed-size slots at comptime-known offsets. No parser, nothing to overflow. |
| **Determinism** | Kernel socket buffer scheduling is non-deterministic. send() may partial-send. recv() may return partial frames. | Sequence numbers are deterministic. Same request → same bytes at same offset. |
| **Boundedness** | frame_max bounds payload, but socket buffer sizes are kernel-managed. Partial send/recv completion is kernel-controlled. | Region size is comptime constant. Slot sizes are comptime constants. `extern struct` with `comptime { assert(@sizeOf == 64) }`. |
| **Fuzzable** | Well-fuzzed (10K exchanges, 7 paths). But the surface area IS the frame parser. | New failure modes (torn writes, stale sequences) but all reachable by PRNG. Fixed layout means fewer format variations. |
| **Right primitive** | Socket is for untrusted network communication. Kernel isolation is redundant for cooperating local processes writing to fixed slots. | mmap + futex IS how two processes share data without copying. |
| **Explicit** | Wire format requires frame headers (4-byte length + tag). Format exists to survive transport fragmentation that can't happen with shared memory. | Layout is an `extern struct`. `@offsetOf(Header, "server_seq")` is the documentation. The memory IS the format. |

**Chose shared memory.** Socket fails right primitive (network
abstraction for local exchange), explicit (wire format for problems
that don't exist), and boundedness (kernel buffer management outside
our control).

### Protocol changes

**Drop RT1 (manifest routing) — accepted.** Passes all six columns.
The manifest already has routing + prefetch SQL. Sending a network
request to retrieve data you already have violates right primitive.
Removing it is pure deletion — less code, fewer failure modes, fewer
states to fuzz. The server routes explicitly from its own data.

**Collapse to 1 RT — rejected.** The native Zig render phase reads
post-write state via a fresh `ReadView` of storage, not from the
prefetch cache. Handlers like `complete_order` query the database
AFTER their writes to show the new order status. The prefetch cache
is pre-write and never updated.

This means 1-RT collapse splits handlers into two classes:

| Handler type | Example | Works with 1 RT? |
|---|---|---|
| Render from prefetch + status | `create_product` | Yes |
| Render from post-write state | `complete_order` | No — must see writes |

Violates **safety** (handlers duplicate DB logic instead of reading
post-write source of truth), **right primitive** (the database answers
"what does the data look like now?" — handlers shouldn't guess), and
**explicit** (2-RT makes the data flow visible: writes then post-write
reads).

**Compiled templates — rejected.** Massive new dependency (build-time
template compiler). TB: "avoiding dependencies acts as a forcing
function for keeping the code simple." Saves ~4μs for Node.js.

### Typed schemas — accepted (re-evaluated)

Initially rejected as "compensating for V8 parse speed." Re-audit
found this was wrong. The performance gain is free — it falls out of
doing the correct thing.

**TigerBeetle uses typed layouts, not self-describing formats.**
TB's wire protocol uses `extern struct` with comptime-known field
offsets. Their message headers, LSM blocks, and client protocol do
not self-describe — the schema IS the struct definition, verified at
compile time. Self-describing formats are for unknown clients. Our
sidecar is a known client — we generate the dispatch code, we know
every query's columns and types at build time.

Sending column headers on every request is redundant work.
TigerBeetle doesn't do redundant work. The schema is known — encode
it in the struct. That's the TB position.

**The current state violates "be explicit."** Handlers receive
`Record<string, unknown>` — untyped objects with dynamic property
access. Developers manually cast: `ctx.prefetched.products as unknown[]`.
No compile-time check that fields exist, that types are correct, or
that column names match. A typo like `.actve` instead of `.active`
ships to production. TB: "be explicit. Minimize dependence on the
compiler to do the right thing." We're not even giving the compiler
a chance — the types are `any`.

**Typed schemas fix the correctness problem. The ~4μs performance
gain comes free.** Removing column headers from the wire and
generating typed deserializers is a consequence of encoding the
known schema, not a goal. The goal is type safety:

1. **Type safety** — TypeScript catches field typos, wrong types,
   missing fields at build time, not production
2. **Autocomplete** — IDE knows what fields exist on prefetched data
3. **Documentation** — generated types ARE the schema docs
4. **Performance** — ~4μs savings is a side effect of not parsing
   data you already know the shape of

**Why the initial rejection was wrong:**

| Principle | Original claim | Honest assessment |
|---|---|---|
| Safety | "Generated code can drift" | Overstated. `dispatch.generated.ts` is also generated — we already accept this. `npm run build` regenerates both. Drift risk is identical to existing codegen. |
| Determinism | "Build-dependent" | Wrong. Same source → same manifest → same output. Forgetting to rebuild is operator error, not non-determinism. |
| Right primitive | "Self-describing is the primitive" | **Wrong. Actually backwards.** TB uses fixed-layout structs. The schema IS the type. Self-describing is what you do when you DON'T know the client. We know the client — we generate it. |
| Explicit | "Self-describing carries schema explicitly" | A generated typed deserializer declares `id: integer, title: text` — you can read the code and see what it expects. The generic parser discovers columns at runtime — you can't know from reading it what the data will be. Typed schemas are more explicit, not less. |

The annotation scanner already reads SQL and validates it against
the database. Extending it to read column types is natural:

```
Annotation SQL → scanner → SQLite PRAGMA / prepare → column names + types → generate TypeScript interfaces
```

This is database-agnostic. Every database can describe its own
schema (SQLite `PRAGMA table_info`, Postgres `information_schema`,
MySQL `DESCRIBE`). The type generation sits in the adapter layer:

```
Adapter interface:
  validate_sql(sql) → ok | error
  describe_columns(sql) → [(name, type)]   ← new method
```

Each adapter maps database types to TypeScript types. SQLite INTEGER
→ `bigint`, TEXT → `string`, etc. The codegen consumes
`(name, type)` pairs regardless of which database produced them.

Handler code doesn't change. Annotations don't change. But:

```typescript
// before: untyped, bugs ship to runtime
export function handle(ctx: HandleContext): string {
  const products = ctx.prefetched.products as unknown[];
  if (!ctx.prefetched.product.actve) return "not_found"; // typo, no error
  return "ok";
}

// after: typed, bugs caught at build time
export function handle(ctx: HandleContext<GetProductPrefetch>): string {
  if (!ctx.prefetched.product.actve) return "not_found"; // ← compile error
  return "ok";
}
```

TB would say: "you're parsing known data into `Record<string, unknown>`
and letting developers cast to `any`. That's the opposite of 'be
explicit.' The schema is known. Encode it."

### Blocking vs async sidecar exchange

Currently `sidecar_commit_and_encode` blocks the tick for ~58μs
(3 socket RTs). With shared memory + futex, the block drops to ~8μs
(2 futex RTs).

Async (eventfd in epoll set, split across ticks, new connection state
`waiting_sidecar`) violates:
- **Right primitive**: the server is single-threaded, one thing at a
  time IS the primitive. The sidecar exchange isn't independent — the
  connection needs the result before it can respond.
- **Explicit**: exchange spans ticks, developer must reason about what
  happened between send and receive. With blocking: nothing.
- **Safety**: new connection state, new transitions, new invariants.
  Also: other connections may commit writes between ticks, so the
  sidecar's render reads may see unexpected data.

**Originally chose blocking.** 128 connections × 8μs = 1ms per tick.

**UPDATE (post message-bus Phase 1.5):** The server pipeline now
supports async handlers with `.pending` + callback. The blocking
vs async decision needs revisiting:

- **Blocking futex in handler:** Simpler. Blocks the event loop for
  ~4μs per futex_wait. Server can't process timeouts, accepts, or
  metrics during the wait. Acceptable if wait is short.
- **eventfd + epoll:** Handler writes to shared memory, does
  futex_wake, returns `.pending`. Sidecar writes response to shared
  memory, writes to eventfd. Epoll fires callback, handler resumes.
  One syscall per signal. Fits the IO model. But was rejected as
  "wrong primitive" (eventfd is an abstraction over futex for epoll
  bridging). With the async pipeline in place, epoll bridging IS
  what we need — eventfd becomes the right primitive.
- **Poll in tick loop:** Check shared memory flag every tick. Adds
  one tick latency (~10ms). Too slow.

**Recommendation:** Revisit eventfd. The async pipeline changes the
calculus — the "wrong primitive" argument was based on blocking
exchange where epoll bridging was unnecessary. With `.pending`
handlers, epoll bridging is exactly what we need. eventfd is the
right primitive for "signal an epoll-driven event loop from another
process via shared memory."

## Projected performance

Per-request cost breakdown:

| Component | Current | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|---|
| Zig-side (SQLite + framing) | 19μs | 19μs | 19μs | 19μs |
| Transport | 58μs (3 RT socket) | 38μs (2 RT socket) | 8μs (2 RT futex) | 8μs |
| V8 compute | ~15μs | ~15μs | ~15μs | ~11μs |
| **Total** | **77μs** | **57μs** | **40μs** | **36μs** |
| **req/s** | **13K** | **17K** | **25K** | **~26K** |
| **% of native** | **25%** | **32%** | **47%** | **~49%** |

~49% of native is the TB-aligned ceiling for Node.js. The remaining
gap is V8 computation (handler logic, HTML string concatenation) —
irreducible without violating TB principles. If a user needs more,
write those handlers in Zig (100%) or Rust (~90%).

Options that could close the remaining gap and their TB violations:

| Option | Gain | TB violation |
|---|---|---|
| 2 RT → 1 RT | +4μs | Safety — handlers duplicate DB logic instead of reading post-write source of truth |
| Futex → spin-wait | +6μs | Boundedness — burns a core, "put a limit on everything" |
| Futex → spin-then-futex | +3μs | Right primitive — two code paths for 3μs, "zero technical debt" |
| Compiled templates | +4μs | Right primitive — massive new dependency, "avoiding dependencies is a forcing function" |

Sidecar language comparison after all three phases:

| Runtime | Compute overhead | Est. req/s | % of native |
|---|---|---|---|
| Rust | ~1μs | 48K | ~90% |
| Java (JIT warm) | ~4μs | 39K | ~74% |
| Go | ~6μs | 34K | ~64% |
| Node.js (V8) | ~11μs | 26K | ~49% |
| Bun (JSC) | ~7μs | 31K | ~58% |
| Python (CPython) | ~50μs | 13K | ~25% |

Transport optimizations are equally valuable for every language.
Typed schemas benefit interpreted languages most. A Rust sidecar
reaches 90% of native with the same transport work.

## Shared memory layout

Single-threaded server, one exchange at a time. No ring buffer needed.

```
Shared region layout (comptime-sized, ~512 KB):

┌─────────────────────────────────────────┐
│ Header (64 bytes, cache-line aligned)   │
│   server_seq: u32    — request sequence │
│   sidecar_seq: u32   — response sequence│
│   request_len: u32   — bytes written    │
│   response_len: u32  — bytes written    │
│   padding to 64 bytes                   │
├─────────────────────────────────────────┤
│ Request slot (frame_max = 256 KB)       │
│   Server writes, sidecar reads          │
├─────────────────────────────────────────┤
│ Response slot (frame_max = 256 KB)      │
│   Sidecar writes, server reads          │
└─────────────────────────────────────────┘
```

Server writes request, atomic store `server_seq`, `futex_wake`.
Sidecar reads, processes, writes response, atomic store `sidecar_seq`,
`futex_wake`. Sequence numbers detect stale data and missed exchanges.

Layout is an `extern struct` with
`comptime { assert(@sizeOf(Header) == 64); }` — the layout is the
protocol, verified at compile time.

## Node.js native addon

Node.js can't mmap or futex natively. Small addon required (~80 LOC C++):

- `shm_open(name)` → fd
- `mmap(fd, size)` → Buffer (backed by shared pages)
- `futex_wait(buffer, offset, expected)` → blocks until woken
- `futex_wake(buffer, offset)` → wakes waiter

Stable POSIX/Linux syscalls, no maintenance burden. Same addon works
for any Node.js sidecar. Go/Rust/Java/Python can call these natively.

## Implementation

### Phase 1: Eliminate RT1 — manifest-driven routing

The annotation scanner already puts prefetch SQL into the manifest at
build time. The server has all the information to route and prefetch
without asking the sidecar. RT1 is unnecessary.

Current 3-RT protocol:
```
RT1: server sends path+body       → sidecar returns operation + prefetch SQL
RT2: server sends prefetch results → sidecar returns status + writes + render SQL
RT3: server sends render results   → sidecar returns HTML
```

New 2-RT protocol:
```
RT1: server sends operation + prefetch results + body → sidecar returns status + writes + render SQL
RT2: server sends render results                     → sidecar returns HTML
```

- [ ] Server reads prefetch SQL from manifest at startup
- [ ] Server routes requests (path+method → operation) from manifest
- [ ] New message tag: `commit_request` (replaces `route_request`)
- [ ] Drop `route_request` / `route_prefetch_response` tags from protocol
- [ ] Update `sidecar.zig`: `translate()` becomes local lookup, first exchange sends operation + prefetch results
- [ ] Update `dispatch.generated.ts`: remove route handler, expect operation + prefetch data on first message
- [ ] Update `app.zig`: `sidecar_commit_and_encode` calls local translate, then 2-RT exchange
- [ ] Adapt sidecar fuzz tests
- [ ] Measure: expect ~17K req/s

This phase works on the existing Unix socket. No transport change.
The protocol gets simpler (fewer message types, fewer code paths).
Risk is negative — less code, fewer branches.

### Phase 2: Shared memory + futex transport

Replace Unix socket with mmap'd region + futex signaling.

Do not ship until fuzz coverage matches the current socket transport
(10K exchanges, 7 paths) plus new targets for shared memory failure
modes. The socket protocol is battle-tested. The replacement must be
equally proven before it replaces anything.

- [ ] Define shared region layout as `extern struct` with comptime size assertions
- [ ] Server creates `/dev/shm/tiger-sidecar-{pid}`, mmaps region
- [ ] Replace `protocol.read_frame` / `protocol.write_frame` with direct shared memory read/write
- [ ] Replace socket send/recv with futex_wake/futex_wait
- [ ] Crash recovery: server zeros region on sidecar timeout, sidecar re-maps on restart (same recovery path as socket disconnect)
- [ ] Sequence number validation (stale response detection)
- [ ] Build Node.js native addon (mmap + futex, ~80 LOC C++)
- [ ] Update `dispatch.generated.ts` to use addon instead of socket
- [ ] Fuzz: 10K+ exchanges through shared memory transport
- [ ] Fuzz: torn writes (sidecar crash mid-response-write)
- [ ] Fuzz: stale sequences (sidecar reads from previous exchange)
- [ ] Fuzz: server timeout during sidecar processing (recovery path)
- [ ] Fuzz: sidecar crash + restart + re-map (reconnection path)
- [ ] Measure: expect ~25K req/s

### Phase 3: Typed schemas — adapter-driven type generation

The scanner already validates SQL against the database at build time.
Extend the adapter interface with `describe_columns(sql)` to read
column types from the database schema. Generate per-handler TypeScript
interfaces and typed deserializers.

This is database-agnostic. Each adapter implements `describe_columns`
using its database's schema introspection:

| Database | Method |
|---|---|
| SQLite | `PRAGMA table_info` or `sqlite3_column_decltype` on prepared stmt |
| PostgreSQL | `information_schema.columns` or `pg_catalog.pg_attribute` |
| MySQL | `information_schema.columns` or `DESCRIBE table` |

- [ ] Add `describe_columns(sql) → [(name, type)]` to adapter interface
- [ ] SQLite adapter: implement via PRAGMA / prepared statement introspection
- [ ] Type mapper: SQLite types → TypeScript types (INTEGER→bigint, TEXT→string, REAL→number, BLOB→Uint8Array)
- [ ] Codegen: emit per-handler prefetch interface (e.g., `GetProductPrefetch { product: Product | null }`)
- [ ] Codegen: emit per-query typed deserializer (skip column headers, read at known offsets)
- [ ] Codegen: emit `HandleContext<GetProductPrefetch>` generic parameter per handler
- [ ] Server: write row data without column headers when typed schema available
- [ ] Update `dispatch.generated.ts`: use typed readers instead of generic `readRowSet`
- [ ] Verify: existing handler code compiles without changes (types are additive)
- [ ] Verify: typos and wrong field access produce TypeScript compile errors
- [ ] Adapt sidecar fuzz tests for typed wire format
- [ ] Measure: expect ~26K req/s

## Safety model

Shared memory doesn't introduce physical risk:

- The server owns the region, controls the layout, creates it
- The sidecar writes to a response slot at a fixed offset with a
  fixed max size (comptime-known, asserted)
- A sidecar writing garbage into its slot is the same failure mode as
  a sidecar sending garbage over a socket — bad data in, bad response
  out, not memory corruption
- The mmap region is the boundary, same as the kernel buffer was
- Torn reads (reading mid-write) produce wrong data, not corruption —
  same as partial socket reads. Sequence numbers detect this.

Futex cannot corrupt anything. It's an atomic compare-and-wait on a
32-bit integer. Deadlock = timeout = same recovery as socket disconnect.

The current socket transport has a risk shared memory eliminates: the
frame parser. Length-prefixed frames can read past buffer bounds on
malformed input. Shared memory has fixed-size slots at comptime-known
offsets. Nothing to parse, nothing to overflow.

## Platform scope

All shared memory mechanisms are OS-specific. But the server already
requires Linux (epoll). Futex and `/dev/shm` don't narrow platform
support — it's already Linux-only. Cross-platform (macOS kqueue,
Windows IOCP) is a separate future gate; sidecar signaling slots into
that same platform layer (futex → os_unfair_lock → WaitOnAddress).

## Relationship to message bus plan

This plan was written before the message bus work (`message-bus.md`).
The message bus replaces raw `protocol.read_frame`/`write_frame` with
`ConnectionType(IO)` + `MessageBusType(IO)` — parameterized on IO.

The shared memory transport is cleaner with the bus in place:
- Replace the IO layer, not raw socket calls. `ConnectionType` calls
  `self.io.recv/send/send_now`. A shared memory IO implementation
  provides the same interface — `recv` reads from mmap, `send` writes
  to mmap, `send_now` writes + futex_wake. The Connection, MessageBus,
  SidecarClient, and handlers don't change.
- The MessagePool provides buffer ownership. Shared memory slots can
  be pool messages directly — the mmap region IS the pool's buffer
  backing. Zero-copy from shared memory to handler.
- `SidecarHandlersType` (comptime handler selection from message-bus.md)
  implements the handler interface using the sidecar protocol. The
  transport (unix socket vs shared memory) is behind the IO parameter.
  Swapping transport is a one-line IO type change, not a protocol change.

Dependency: message-bus.md Phase 1.5 (consolidated pipeline with
async handlers) should complete before this plan starts. The async
handler interface means the server pipeline doesn't change when the
transport changes — only the IO layer and handler implementation.

## What we're NOT doing

- **Collapse to 1 RT** — handlers like `complete_order` read post-write state from the database via `ReadView`. The prefetch cache is pre-write only. 1-RT forces handlers to duplicate DB logic. The database is the source of truth — read from it.
- **Compiled templates** — massive new dependency for ~4μs. TB: "avoiding dependencies acts as a forcing function."
- **Async sidecar exchange** — blocking window is 8μs. Async adds connection states, cross-tick temporal coupling, and risk of unexpected data visibility between ticks.
- **Spin-wait** — burns a core. Violates "put a limit on everything."
  However, the IO parameterization makes this a future opt-in:
  `SharedMemoryIO(.{ .signaling = .spin })`. One comptime line.
  The developer chooses knowingly. Worth it for compiled-language
  sidecars (Zig/Rust/C/Go) where handler compute is ~1-2μs and
  transport dominates:

  | Runtime | Futex (safe) | Spin (burns core) | Gain |
  |---|---|---|---|
  | Zig/Rust/C/Go | ~34K | ~45K | +32% |
  | TypeScript (V8) | ~25K | ~27K | +8% |
  | Python | ~5K | ~5K | ~0% |

  Gain is large when handler is fast (transport dominates). Small
  when handler is slow (runtime dominates). Not worth it for
  interpreted languages. Dangerous but valuable for latency-
  sensitive compiled handlers. Default remains futex.
- **Spin-then-futex** — two code paths for 3μs. Violates "zero technical debt."
- **eventfd** — abstraction over futex for epoll integration we don't need.
- **Embedded V8** — massive dependency (Bun is 300K+ lines), single-language.
- **Multiple sidecar workers** — server is single-threaded, one
  exchange at a time. However, this is a future scaling path when
  the runtime is the bottleneck. The server dispatches CALLs to N
  sidecar processes via N MessageBus connections. While sidecar A
  computes, the next request goes to sidecar B. The sidecars run
  in parallel on separate cores. The server round-robins.

  | Runtime | 1 process | 2 processes | 4 processes |
  |---|---|---|---|
  | Python | ~5K | ~10K | ~20K |
  | TypeScript (V8) | ~25K | ~50K | ~100K |
  | Rust/Go | ~34K | ~68K | ~136K |

  This uses the connection pool extension point from message-bus.md.
  The handler interface is unchanged — the dispatcher picks which
  bus. Requires the concurrent pipeline (multiple `commit_stage`
  slots) from network-storage.md so the server can have multiple
  requests in-flight. Without concurrent pipeline, the server
  blocks on each sidecar response.

  Not doing this now — single-process sidecar is sufficient.
  Build when a user needs more throughput than one runtime process
  can deliver.
