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
| Pure futex | ~8μs | Blocks the event loop. The 8μs is the happy path — actual block is however long V8 takes (GC, JIT deopt). Server can't process timeouts, accepts, or metrics during the wait. TB never blocks the event loop. |
| eventfd | ~10μs | None. One code path, deterministic, bounded by epoll timeout. The async pipeline (message-bus Phase 1.5) needs epoll bridging — eventfd is the right primitive for "signal an epoll-driven event loop from another process." |
| io_uring futex | ~6μs | **Right primitive**: not using io_uring for anything else. **Safety**: 50K+ lines of kernel dependency surface. TB built their own IO ring for control. |

**Chose eventfd.** The async pipeline (`.pending` + callback) changed
the calculus. The original evaluation rejected eventfd because "we
don't need epoll bridging" — true when the exchange was blocking,
wrong now that every handler is async. eventfd is purpose-built for
this: one `write(efd, 1)` wakes the other process's epoll. No fd
leaks, no kernel buffers beyond one u64 counter, no abstraction
layers. Bounded by epoll timeout. Deterministic (same signal, same
wake). Fuzzable (SimIO models eventfd as an instant delivery with
PRNG-driven delay).

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

**Chose async (eventfd + epoll).** The message-bus Phase 1.5 pipeline
supports async handlers with `.pending` + callback. This eliminates
the original objections to async:

- ~~**Right primitive**: single-threaded, one thing at a time~~
  → The pipeline already handles `.pending`. The tick loop already
  continues while handlers await IO. Blocking is now the exception,
  not the primitive.
- ~~**Explicit**: exchange spans ticks~~
  → Every sidecar handler already spans ticks via the message bus
  plan. Same pattern: handler returns `.pending`, callback resumes
  `commit_dispatch`. The developer reasons about one interface.
- ~~**Safety**: new connection state, new transitions~~
  → The `.pending` handler state and `commit_dispatch` resume path
  already exist. No new states. The sidecar exchange uses the same
  mechanism as every other async handler.

The blocking argument (8μs is acceptable) was wrong for a deeper
reason: 8μs is the **happy path**. The actual block is however long
V8 takes — GC pause, JIT deopt, slow handler. `futex_wait` with a
timeout freezes the entire server for the full timeout before
recovery. TB never blocks the event loop. Their `commit_prefetch`
returns `.pending` and the tick continues.

**Flow:**
```
Handler writes request to shared memory
  → atomic store server_seq (release)
  → write 1 to eventfd (wakes sidecar's epoll/poll)
  → return .pending

Sidecar reads request, computes, writes response
  → atomic store sidecar_seq (release)
  → write 1 to server's eventfd (registered in server's epoll)

Server's epoll fires eventfd readable
  → eventfd callback: read eventfd, call commit_dispatch_resume
  → handler re-enters, reads response (acquire on sidecar_seq)
  → .complete → advance pipeline
```

Two eventfds: one for server→sidecar notification, one for
sidecar→server. Each registered in the respective process's epoll
set. eventfd is the right primitive for "signal an epoll-driven
event loop from another process" — it exists specifically for this.
The original rejection called it "an abstraction over futex for
epoll bridging we don't need." With the async pipeline, epoll
bridging IS what we need.

## Projected performance (revised with measured data)

Measured per-request cost is ~819µs (not ~77µs as originally
estimated). The original estimates underweighted V8 handler
execution time by ~10×. Revised projections use measured data.

**Committed plan (Phase 3 + Phase 1):**

| | Current (measured) | After Phase 3 (typed) | After Phase 1 (2 RT) |
|---|---|---|---|
| V8 handler execution | 738µs | ~734µs (-4µs typed) | ~440µs (-298µs route CALL) |
| QUERY round-trips | 81µs | 81µs | 81µs |
| Protocol overhead | ~350µs (4 RT) | ~350µs | ~50µs (2 RT) |
| **Total** | **~819µs** | **~815µs** | **~571µs** |
| **req/s (1 sidecar)** | **~1,200** | **~1,200** | **~1,750** |
| **vs Express** | **0.5×** | **0.5×** | **~1×** |

With concurrent pipeline (N sidecars), multiply by N:

| | 1 sidecar | 2 sidecars | 4 sidecars |
|---|---|---|---|
| Current | ~1,200 | ~2,400 | ~4,800 |
| After Phase 1 | ~1,750 | ~3,500 | ~7,000 |

**Future optimizations (measure-driven, deploy if data shows need):**

| Optimization | Saves | When to deploy |
|---|---|---|
| Request batching | ~40µs/req under load | Protocol overhead >10% of cost |
| QUERY batching | ~60-350µs/req | QUERY RTs >20% of cost (complex handlers) |
| Shared memory | ~20µs/req | Transport >10% of cost (unlikely) |

The concurrent pipeline (✅ DONE) is the multiplier. Phase 1 (RT
reduction) brings 1 sidecar to Express parity. Additional sidecars
scale beyond what a single Node.js process can deliver.

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

Layout is an `extern struct` with
`comptime { assert(@sizeOf(Header) == 64); }` — the layout is the
protocol, verified at compile time.

### Memory ordering

Sequence numbers are the synchronization points. Without explicit
ordering, the CPU can reorder stores: the server could see a new
`sidecar_seq` but read stale response payload bytes. TB is
meticulous about this — "be explicit" means specifying the memory
model, not hoping the compiler does the right thing.

**Write side (server publishes request):**
```zig
// 1. Write payload (ordinary stores — no ordering constraint between payload bytes).
@memcpy(region.request_slot[0..len], payload);
std.mem.writeInt(u32, &region.header.request_len, len, .big);
std.mem.writeInt(u32, &region.header.request_crc, crc, .big);

// 2. Release fence: all payload stores visible before seq update.
@atomicStore(u32, &region.header.server_seq, seq, .release);

// 3. Signal sidecar (eventfd write).
```

**Read side (sidecar consumes request):**
```zig
// 1. Acquire fence: seq load orders before all payload loads.
const seq = @atomicLoad(u32, &region.header.server_seq, .acquire);
if (seq == last_seen_seq) return; // no new request

// 2. Read payload (ordinary loads — guaranteed visible by acquire).
const len = std.mem.readInt(u32, &region.header.request_len, .big);
const crc = std.mem.readInt(u32, &region.header.request_crc, .big);
const payload = region.request_slot[0..len];
```

Same pattern reversed for sidecar→server (sidecar does release
store on `sidecar_seq`, server does acquire load).

**Why acquire/release, not SeqCst:** Two producers, two consumers,
no third-party observer. Acquire/release is sufficient — it
establishes a happens-before between the writer's stores and the
reader's loads. SeqCst adds a full barrier for total ordering
across all threads, which we don't need (only two participants).
TB uses release/acquire for their FIFO queues for the same reason.

**The eventfd is not the fence.** The eventfd write/read happen
AFTER the atomic store/load. They are notification, not
synchronization. A process could theoretically see the eventfd
signal before the acquire load sees the new seq — that's fine,
it just means the handler re-enters, sees old seq, returns
`.pending` again, and waits for the next signal. The atomic
seq IS the synchronization point. The eventfd is just the wake.

## Node.js native addon

Node.js can't mmap natively. Small addon required (~80 LOC C++):

- `shm_open(name)` → fd
- `mmap(fd, size)` → Buffer (backed by shared pages)
- `eventfd(0, EFD_NONBLOCK)` → fd (for epoll/poll registration)
- `eventfd_write(fd)` → signal the other process
- `eventfd_read(fd)` → consume signal

eventfd returns a regular fd — Node.js can `poll`/`select` on it
natively or register it in its event loop via `uv_poll_t`. No
blocking required on the sidecar side either.

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
- [ ] Header includes CRC fields: `request_crc`, `response_crc` (CRC-32 of len ++ payload)
- [ ] Server creates `/dev/shm/tiger-{pid}-{boot_id}`, mmaps region
- [ ] `shm_unlink` before `shm_open(O_CREAT|O_EXCL)` — no stale regions from crashes
- [ ] Replace `protocol.read_frame` / `protocol.write_frame` with direct shared memory read/write
- [ ] Signaling via eventfd (2 eventfds: server→sidecar, sidecar→server)
- [ ] Server registers sidecar→server eventfd in epoll set
- [ ] Handler writes to shm, `@atomicStore(.release)` on seq, writes eventfd, returns `.pending`
- [ ] eventfd callback: `@atomicLoad(.acquire)` on seq, validate CRC, resume `commit_dispatch`
- [ ] Sequence number validation (stale response detection)
- [ ] Crash recovery: server detects sidecar death via `waitpid`/`SIGCHLD`
- [ ] Crash recovery: server zeros region header, re-spawns sidecar
- [ ] Crash recovery: CRC mismatch on partial write → pipeline failure (not undefined behavior)
- [ ] Build Node.js native addon (mmap + eventfd, ~80 LOC C++)
- [ ] Update `dispatch.generated.ts` to use addon instead of socket
- [ ] Fuzz: 10K+ exchanges through shared memory transport
- [ ] Fuzz: torn writes (sidecar crash mid-response-write, CRC must catch)
- [ ] Fuzz: stale sequences (sidecar reads from previous exchange)
- [ ] Fuzz: server eventfd timeout during sidecar processing (recovery path)
- [ ] Fuzz: sidecar crash + restart + re-map (reconnection path)
- [ ] Fuzz: memory ordering — verify acquire/release prevents stale payload reads
- [ ] Measure: expect ~24K req/s

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
- Sequence numbers + acquire/release ordering prevent torn reads
  (see Memory ordering section)

The current socket transport has a risk shared memory eliminates: the
frame parser. Length-prefixed frames can read past buffer bounds on
malformed input. Shared memory has fixed-size slots at comptime-known
offsets. Nothing to parse, nothing to overflow.

### Checksums

The socket transport uses CRC-32 on every frame. Shared memory must
keep this — dropping checksums is a safety regression.

A sidecar bug that writes `response_len = 200000` but only 50 bytes
of valid data → the server reads 199,950 bytes of uninitialized
shared memory. A corrupted payload from a serializer bug produces
wrong HTML silently. TB checksums WAL entries, LSM blocks, and wire
messages — even data that "can't" be corrupted. The checksum catches
bugs in the OTHER process's code, not ours.

**Header gains CRC fields:**

```
Header (64 bytes, cache-line aligned):
  server_seq:    u32  — request sequence
  sidecar_seq:   u32  — response sequence
  request_len:   u32  — payload bytes written
  response_len:  u32  — payload bytes written
  request_crc:   u32  — CRC-32 of request_len bytes ++ request payload
  response_crc:  u32  — CRC-32 of response_len bytes ++ response payload
  padding to 64 bytes
```

CRC covers `len_bytes ++ payload_bytes` (same convention as the
message bus frame format — length is included so a corrupted length
produces a CRC mismatch). Validated on the read side after the
acquire load, before accessing the payload. CRC mismatch → treat
as sidecar error → pipeline failure → same recovery as disconnect.

Cost: CRC-32 of 256KB is ~30μs on a modern CPU. But typical
payloads are 1-10KB (~0.1-1μs). Negligible compared to the 8μs
transport overhead. TB: "safety > performance."

### Crash recovery

Socket disconnect is a clean kernel event — the fd becomes invalid,
epoll fires, the server handles it. Shared memory crashes are
different: the region persists in an unknown state with no automatic
notification. Each crash scenario needs explicit handling.

**Sidecar crashes mid-write:**
- Response slot contains partial/corrupt data
- `sidecar_seq` may or may not be updated
- If seq NOT updated: server never sees response → eventfd timeout
  → treat as sidecar error → pipeline failure. Clean.
- If seq IS updated (crash between atomic store and process exit):
  server reads response, CRC mismatch (partial payload) → treat as
  sidecar error. This is why checksums are mandatory, not optional.
- Server detects sidecar death via `waitpid`/`SIGCHLD` (server
  spawns sidecar). On sidecar death: cancel pending exchange,
  pipeline failure for in-flight request, zero the region header
  (all seqs = 0), re-spawn sidecar. New sidecar opens existing
  region (same shm path).

**Server crashes:**
- `/dev/shm/tiger-sidecar-{pid}` is orphaned
- PID may be reused by an unrelated process
- **Fix:** Use a unique name that cannot collide:
  `/dev/shm/tiger-{pid}-{boot_id}` where `boot_id` is read from
  `/proc/sys/kernel/random/boot_id` (changes on reboot, eliminates
  stale regions from previous boots). On startup, the server
  `shm_unlink`s its own name before `shm_open` with `O_CREAT|O_EXCL`
  — if the name already exists from a previous crash, unlink it
  first. The `O_EXCL` flag after unlink guarantees a fresh region.
- Server passes the shm name to the sidecar as a CLI argument.
  Sidecar opens read/write. No guessing.

**Sidecar restarts (intentional or crash recovery):**
- Server zeros region header (all seqs = 0) on sidecar death
- New sidecar opens the existing region, sees seq = 0
- Server's `sidecar_seq` tracking resets to 0
- First exchange starts at seq = 1. Clean slate.

**Region cleanup on normal shutdown:**
- Server `munmap`s + `shm_unlink`s in shutdown path
- Sidecar `munmap`s in its shutdown path (unlink is server's job)
- `shm_unlink` removes the `/dev/shm` entry; the region stays mapped
  until the last `munmap` (POSIX semantics). Safe for ordered shutdown.

**Invariants (asserted, not hoped):**
- `server_seq` is always `== sidecar_seq` or `== sidecar_seq + 1`
  (server is at most one request ahead)
- `request_len <= frame_max` and `response_len <= frame_max`
  (comptime-known bounds)
- CRC matches payload on every read (mandatory, not debug-only)
- Region size equals `comptime @sizeOf(ShmRegion)` — verified by
  both processes on mmap with `assert(stat.size == @sizeOf(ShmRegion))`

## Platform scope

All shared memory mechanisms are OS-specific. But the server already
requires Linux (epoll). Futex and `/dev/shm` don't narrow platform
support — it's already Linux-only. Cross-platform (macOS kqueue,
Windows IOCP) is a separate future gate; sidecar signaling slots into
that same platform layer (futex → os_unfair_lock → WaitOnAddress).

## Relationship to completed work

**Message bus (✅ DONE):** `ConnectionType(IO)` + `MessageBusType(IO)`
with async handlers, `.pending` + callback resume. The shared memory
transport replaces the IO layer, not raw socket calls.

**Concurrent pipeline (✅ DONE, Stage 3):** Per-slot handlers,
round-robin dispatch, handle_lock, per-slot tracer. SM is pure
framework services (auth, transactions). Handlers are per-slot on
the server. All connections active — no standby concept. Sim-tested
at 2x throughput with 2 slots.

**Recommended implementation order (revised after measurement):**
1. Phase 3: Typed schemas — correctness fix (safety > performance)
2. Phase 1: RT reduction — biggest single win (298µs saved, 36% faster)
3. Measure. Then decide: request batching or QUERY batching based
   on where the time goes for real handler workloads.

Shm (Phase 2) deferred — measured transport overhead is <10µs per
round-trip (~2% of request cost). Months of complexity for <2% gain.
Unix socket is the right primitive when transport isn't the bottleneck.

## What we're NOT doing

- **Collapse to 1 RT** — handlers like `complete_order` read post-write state from the database via `ReadView`. The prefetch cache is pre-write only. 1-RT forces handlers to duplicate DB logic. The database is the source of truth — read from it.
- **Compiled templates** — massive new dependency for ~4μs. TB: "avoiding dependencies acts as a forcing function."
- **Blocking futex** — blocks the event loop. 8μs is the happy path. V8 GC pause or slow handler → entire server frozen. TB never blocks the event loop. The async pipeline exists — use it.
- **Spin-wait** — burns a core. Violates "put a limit on everything."
  However, the IO parameterization makes this a future opt-in:
  `SharedMemoryIO(.{ .signaling = .spin })`. One comptime line.
  The developer chooses knowingly. Worth it for compiled-language
  sidecars (Zig/Rust/C/Go) where handler compute is ~1-2μs and
  transport dominates:

  | Runtime | eventfd (safe) | Spin (burns core) | Gain |
  |---|---|---|---|
  | Zig/Rust/C/Go | ~34K | ~45K | +32% |
  | TypeScript (V8) | ~24K | ~27K | +12% |
  | Python | ~5K | ~5K | ~0% |

  Gain is large when handler is fast (transport dominates). Small
  when handler is slow (runtime dominates). Not worth it for
  interpreted languages. Dangerous but valuable for latency-
  sensitive compiled handlers. Default remains futex.
- **Spin-then-futex** — two code paths for 3μs. Violates "zero technical debt."
- **Pure futex (blocking)** — see "blocking futex" above.
- **Embedded V8** — massive dependency (Bun is 300K+ lines), single-language.
- **Multiple sidecar workers** — ✅ DONE (Stage 3 concurrent pipeline).
  Server dispatches to N sidecar processes via N MessageBus connections.
  Per-slot handlers, round-robin dispatch, handle_lock serializes writes.
  Sim-tested: 2x throughput with 2 slots. Linear scaling to SQLite ceiling.

  | Runtime | 1 process | 2 processes | 4 processes |
  |---|---|---|---|
  | Python | ~5K | ~10K | ~20K |
  | TypeScript (V8) | ~25K | ~50K | ~100K |
  | Rust/Go | ~34K | ~68K | ~136K |

## Measured timing (2026-04-03)

Real sidecar instrumentation (unix socket, V8 warm after 5 requests).
After eliminating per-request allocations in the TS runtime (2.8x
speedup from pre-allocated buffers, reused db/ctx objects).

| CALL | Total | V8 compute | QUERY round-trips | Queries |
|---|---|---|---|---|
| route | 298µs | 298µs | 0µs | 0 |
| prefetch | 344µs | 263µs | 81µs | 1 |
| handle | 62µs | 62µs | 0µs | 0 |
| render | 115µs | 115µs | 0µs | 0 |
| **Total** | **819µs** | **738µs** | **81µs** | **1** |

**Cost breakdown:**
- V8 handler execution: 738µs (90%)
- QUERY round-trips: 81µs (10%)
- Transport overhead: <10µs per RT (<2%)

**The bottleneck is V8 handler execution, not transport or queries.**
This changes the optimization priority: RT reduction saves 298µs
(one fewer V8 invocation), not ~35µs (one fewer socket round-trip).

**Comparison with Express (same handler logic + SQLite):**

| Work | Express | Our sidecar (now) | After RT reduction |
|---|---|---|---|
| HTTP parse | ~15µs (Node) | ~1µs (Zig) | ~1µs |
| Body parse | ~10µs (middleware) | 0µs (Zig) | 0µs |
| Handler JS | ~200µs | ~200µs | ~200µs |
| SQLite query | ~80µs (better-sqlite3) | ~88µs (QUERY RT) | ~88µs |
| Template render | ~100µs | ~100µs | ~100µs |
| Session/cookie | ~20µs (middleware) | ~1µs (Zig HMAC) | ~1µs |
| HTTP encode | ~10µs (Node) | ~1µs (Zig) | ~1µs |
| Protocol overhead | 0µs | ~350µs (4 RT) | ~50µs (2 RT) |
| **Total** | **~440µs** | **~819µs** | **~441µs** |
| **vs Express** | **1x** | **0.5x** | **~1x (parity)** |

After RT reduction alone, 1 sidecar reaches Express parity. Zig
handles HTTP, SQL, and session faster than Node — those savings
offset the remaining 2-RT protocol cost.

## Future optimizations (measure-driven)

Deploy after Phase 1 + Phase 3 and re-measure. Each optimization
targets a different bottleneck. The instrumentation (`--log-trace`)
shows exactly where time goes — implement whichever the data says
is the next bottleneck.

### Request batching

Batch N ready connections into one CALL, get N results in one RESULT.
Amortizes protocol overhead across N requests. Free at batch=1
(low load), multiplicative at batch=N (high load).

**When to implement:** after RT reduction, if protocol overhead
(~50µs at 2 RT) is still a significant fraction of request cost
under high load. If V8 handler execution dominates (as measured),
batching saves less than expected.

**Design:**
```
process_inbox:
  collect all .ready connections (up to batch_max)
  pack into one CALL frame: [request_count: u16][request1][request2]...
  assign batch to next free slot
  dispatch

sidecar:
  for each request in batch:
    route → prefetch → handle → render
  pack results: [response_count: u16][response1][response2]...
  send one RESULT frame
```

No waiting to fill the batch. Send what's ready NOW, every tick.

**Composes with existing work:** PipelineSlot holds a batch,
handle_lock serializes batch transactions, round-robin distributes
batches across sidecars. Handler API unchanged — framework calls
handler per request inside the sidecar.

### QUERY batching

Batch N queries within a single handler into one exchange instead
of N round-trips.

**When to implement:** after RT reduction + request batching, if
QUERY round-trips are >20% of remaining request cost. Measured
today: 10% for simple handlers (1 query), up to 37% for complex
handlers (5 queries).

**Design:** sidecar sends all QUERYs upfront, server executes all
and returns all QUERY_RESULTs in one batch. Complementary to
request batching — they operate at different levels (request-level
vs query-level).

### Shared memory transport

Replace unix socket with mmap + eventfd. Eliminates kernel buffer
copies and socket syscalls.

**When to implement:** if measured transport overhead exceeds 10%
of request cost. Currently <2%. The unix socket is the right
primitive when transport isn't the bottleneck. Months of
implementation (mmap, eventfd, native addon, crash recovery,
memory ordering, CRC validation, fuzz coverage) for <2% gain
is not justified.

The full shm design (layout, memory ordering, crash recovery,
safety model) is documented above in case transport becomes the
bottleneck for a specific workload or sidecar language.
