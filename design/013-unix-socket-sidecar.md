# Unix Socket Sidecar

## Prerequisite

Pure execute (Ticket 8): done. Execute handlers return
`{response, writes[]}`, dispatch loop applies writes. Handlers
never call storage directly.

## Overview

The sidecar handles all user-space logic: translate (routing),
execute (business logic), and render (HTML). The framework owns
everything else: HTTP parsing, connections, IO, storage, WAL, auth
cookies, SSE framing.

Default is Zig-native. Sidecar is opt-in:
`--sidecar /tmp/tiger-web.sock`

The sidecar code mirrors the Zig app 1:1 — same files, same
functions, same explicit switches. No DSL, no magic. See design/012
for why.

## Pipeline: two round trips

Storage (SQLite) lives in Zig. Prefetch must happen in Zig. This
creates a natural two-phase protocol per request:

```
                    Zig (framework)              Sidecar
                    ───────────────              ───────
HTTP arrives    →   parse HTTP
                    send {method, path, body} →  translate()
                    ← {operation, id, body}      (or null = unmapped)

                    prefetch from storage

                    send {op, id, body, cache} → execute() + render()
                    ← {status, writes[], html}

                    validate response
                    apply_writes to storage
                    wrap HTML with HTTP headers
                    set cookie, WAL append
                    send to client
```

Two round trips: ~40-100μs total. SQLite write is ~50-100μs.
The sidecar hop is noise — storage is the bottleneck.

## Protocol

Fixed-size binary. No JSON, no framing. Synchronous — one request,
one response. Single connection (server is single-threaded).

### Round trip 1: translate

**Request (Zig → sidecar):**
```
tag:    u8 = 0x01 (translate)
method: u8 (GET=1, POST=2, PUT=3, DELETE=4)
path:   [path_max]u8
path_len: u16
body:   [body_max]u8
body_len: u16
```

**Response (sidecar → Zig):**
```
found:     u8 (0 = unmapped, 1 = mapped)
operation: u8
id:        u128
body:      [body_max]u8
```

If `found == 0`, the framework closes the connection (unmapped
request). Same as `codec.translate` returning null today.

### Round trip 2: execute + render

**Request (Zig → sidecar):**
```
tag:        u8 = 0x02 (execute_render)
operation:  u8
id:         u128
body:       [body_max]u8
cache:      [cache_max]u8 (prefetch cache, serialized)
is_sse:     u8 (0 = full page, 1 = SSE fragment)
```

The prefetch cache is flattened into a fixed buffer. Each optional
field has a 1-byte presence flag (0 = null, 1 = present) followed
by the value bytes if present. Lists have a length prefix (u16)
followed by N items. Layout is deterministic — derived from the
cache struct definition at comptime.

**Response (sidecar → Zig):**
```
status:     u8
result:     [result_max]u8
writes_len: u8
writes:     [writes_max * write_size]u8 (Write union, serialized)
html_len:   u32
html:       [html_max]u8
```

The framework reads `html[0..html_len]` and wraps it with HTTP
headers (Content-Type, Content-Length, Connection, Set-Cookie).
The sidecar produces the HTML body; the framework owns HTTP framing.

### SSE followup

The server detects `resp.followup != null` on the execute response.
Next tick, it sends a second execute_render for the refresh operation
(page_load_dashboard). The sidecar renders the dashboard HTML +
mutation status fragment. Same protocol, same round trip.

The followup state (operation, status, user_id, kind, session_action,
is_new_visitor) is sent as part of the execute_render request so the
sidecar can render error fragments targeting the right panel.

## Comptime-generated validation

The Zig compiler knows the exact byte layout of every type at
comptime via `@typeInfo`. The validator is generated from the same
type definitions the Zig handlers use:

- Status byte must be a valid enum value
- Each write must target a valid table index
- Each write key must be non-zero
- writes_len must be <= writes_max
- html_len must be <= html_max
- Field offsets match the extern struct layout

Change a field in Zig, the validator changes automatically. No
manual protocol versioning. A structurally correct TypeScript
object with wrong serialization offsets is caught at the framework
boundary with an exact error message.

## Zig side implementation

### Socket client (`sidecar.zig`)

New file in the app (not framework — the protocol is domain-specific).
Provides the same interface as the direct Zig modules:

```
pub fn translate(method, path, body) ?Message
pub fn execute_render(op, id, body, cache, is_sse) SidecarResponse
```

Internally: connect to unix socket at startup. send/recv per call.
Reconnect with backoff on failure.

### App binding (`app.zig`)

The App binding switches between Zig-native and sidecar based on
a comptime or init-time flag:

```
// Zig-native (current)
pub fn translate(...) ?Message { return codec.translate(...); }

// Sidecar
pub fn translate(...) ?Message { return sidecar.translate(...); }
```

The framework never changes. The App implementation decides.

### No fallback

The sidecar is either the execute path or it isn't. No mixing.
If the sidecar is down, requests fail with storage_error until
it's back. Mixing Zig-native and sidecar would break determinism —
different code paths for the same input.

### Spot-check

Every N commits, run both Zig-native execute AND sidecar execute
on the same inputs. Compare response + writes byte-for-byte.
Log divergence as an error. Catches non-determinism from GC,
HashMap ordering, runtime version changes.

## TypeScript sidecar implementation

### Socket server (`sidecar.ts`)

Node.js `net.createServer` on the unix socket path. Single
connection. Reads binary requests, dispatches to user handlers,
writes binary responses.

Generated — the user doesn't write this. `zig build codegen`
produces it from the protocol definition.

**Startup:** `node sidecar.js --socket /tmp/tiger-web.sock`

### User code

The developer writes three files that mirror the Zig app 1:1:

**`codec.ts`** — translate function with explicit routing:
```typescript
export function translate(method: string, path: string, body: string): Message | null {
  // same explicit routing as codec.zig
}
```

**`handlers.ts`** — execute functions with explicit switches:
```typescript
// [execute] .create_product
export function createProduct(cache: PrefetchCache, body: Product): ExecuteResult {
  // same logic as state_machine.zig
}
```

**`render.ts`** — HTML rendering with explicit dispatch:
```typescript
export function encodeResponse(op: Operation, status: Status, result: any, isSse: boolean): string {
  // same switch as render.zig
}
```

Annotation-based binding (// [execute] .operation) connects
functions to operations. The build step enforces exhaustiveness —
missing operation → build error. See design/012 for details.

### Generated files (`zig build codegen`)

Reads Zig types at comptime, emits TypeScript:

- **`types.generated.ts`** — domain structs as TS interfaces
  (Product, Order, Collection, etc.)
- **`protocol.generated.ts`** — Operation and Status as string
  unions, PrefetchCache interface, Write union, ExecuteResult type
- **`serde.generated.ts`** — binary ↔ TypeScript serialization
  (field offsets derived from Zig extern struct layout)
- **`sidecar.generated.ts`** — socket server, request dispatch,
  calls user-annotated handlers

The developer never writes serialization code. The generated serde
functions handle binary ↔ TypeScript object conversion. The
generated sidecar server handles the socket protocol. The developer
writes business logic and HTML.

## Dynamic language support

The unix socket doesn't care what's on the other end. Python, Ruby,
Lua — anything that reads and writes the binary protocol works.
Without generated types: no compile-time checking, no IDE
autocomplete. The framework's runtime validation catches everything
regardless.

| Sidecar language | Wrong return type caught by       |
|------------------|-----------------------------------|
| Zig (native)     | Zig compiler, build time          |
| TypeScript       | TS compiler via generated types   |
| Python/Ruby/Lua  | Framework validation, first call  |

## Implementation plan

### Step 1: Type generation (`zig build codegen`)

Build a comptime tool (like `graph_comptime.zig`) that walks the
app's domain types and emits TypeScript files. Test by generating
types and compiling them with `tsc`.

Independently useful — generated types serve as documentation and
enable external tooling even without the sidecar.

### Step 2: Serde generation

Extend codegen to emit binary ↔ TypeScript serialization functions.
For each extern struct: read/write functions that map field offsets
to object properties. Test with round-trip: TS object → binary →
TS object, assert equality.

### Step 2b: Serde round-trip fuzzer

PRNG-driven fuzzer that validates the serde boundary. For each
extern struct: generate a random Zig value → serialize to wire
bytes → deserialize in TypeScript → re-serialize → compare bytes.
Agreement proves the TS serde matches the Zig layout.

Runs both directions:
- **Zig → TS:** random struct → Zig serializes → TS deserializes
  → TS re-serializes → byte-compare against original
- **TS → Zig:** random TS object → TS serializes → Zig deserializes
  → Zig re-serializes → byte-compare against original

Covers:
- Field offset mismatches (wrong `@offsetOf` in codegen)
- `_len` companion semantics (string truncation, array length)
- Enum value round-trip (numeric → string literal → numeric)
- Packed flags (boolean → bit → boolean)
- `u128` hex encoding (string ↔ 16-byte little-endian)
- Reserved/padding bytes (must be zero-filled)
- Edge cases: empty strings, max-length strings, zero values,
  max integer values, all flags set, all flags clear

Structure: single Zig binary that spawns a Node child process.
Zig generates random structs via PRNG, pipes them to Node over
stdin, Node deserializes + re-serializes, pipes back over stdout,
Zig compares. Deterministic seed for reproducibility. Follows the
existing `fuzz_tests.zig` dispatcher pattern.

```bash
./zig/zig build fuzz -- serde              # random seed
./zig/zig build fuzz -- serde 12345        # specific seed
```

**Current status:** Implemented as codegen-generated TS test with
Zig-constructed test vectors (both directions) + PRNG random
round-trips. Run: `npx tsx generated/serde_test.generated.ts [seed]`

The cross-process pipe fuzzer (Zig spawns Node, reads TS-written
bytes) is deferred to Step 5. When the sidecar is wired up, the
Zig framework's response validator becomes the test oracle — it
validates every byte the sidecar produces at runtime, making the
cross-process fuzzer redundant for correctness. The pipe fuzzer
remains valuable for regression detection with deterministic seeds.

### Step 3: Protocol wire format

Define exact byte layouts for the two round trips. Implement in
Zig (send/recv helpers) and TypeScript (generated serde). Test with
a mock: Zig sends a translate request, TypeScript echoes it back,
Zig validates.

### Step 4: Sidecar socket server (generated)

Generate `sidecar.generated.ts` — the Node.js socket server that
reads requests, dispatches to user-annotated handlers, writes
responses. The user never touches this file.

### Step 5: Zig socket client (`sidecar.zig`)

Connect to unix socket. Send translate requests. Send execute_render
requests. Receive and validate responses. Handle connection failures
(return storage_error). Test with the TypeScript sidecar from step 4.

### Step 6: App binding switch

Wire `app.zig` to use sidecar.zig when `--sidecar` flag is set.
Run the full test suite through the sidecar path. All existing
tests must pass — the sidecar produces the same results as
Zig-native.

### Step 7: Annotation scanner — DONE

Annotation scanner validates handler exhaustiveness at build time.
Accepts `[route]`, `[handle]`, `[render]` annotations. Outputs a
JSON manifest for language-specific adapters. Clickable file:line
error messages. Implemented in `annotation_scanner.zig`.

### Step 8: Adapter system — DONE

Language-specific adapters read the manifest and generate the
dispatch file. The TypeScript adapter (`adapters/typescript.ts`)
extracts function names and generates `dispatch.generated.ts`
with imports, dispatch tables, and socket server.

The developer's workflow:
```
npm run build    # codegen + scan + adapter
npm run dev      # sidecar + server
```

## Zig validation vs TypeScript validation

The Zig framework validates sidecar responses at the byte level using
comptime-derived knowledge. This catches things TypeScript cannot:

**Byte layout correctness.** TypeScript checks structural shape (`obj.price_cents`
is a number). Zig checks the byte at offset 48 is a valid u32 encoding.
A TypeScript object can be structurally correct but serialize to wrong
byte offsets — Zig catches this, TypeScript cannot.

**Enum value ranges.** TypeScript union types (`"ok" | "not_found"`) are
erased at runtime — `JSON.stringify` doesn't check. Zig validates the
status byte against the comptime-known enum values. An invalid status
byte (e.g., 0 or 255) is caught immediately with the exact value.

**Fixed-size buffer overflow.** Zig knows `html_max`, `writes_max`,
`body_max` at comptime. If `html_len` exceeds `html_max`, the
validator rejects before reading. TypeScript has no concept of fixed
buffer sizes — it allocates dynamically and hopes for the best.

**Write command integrity.** Each write targets a table, a key, and
a value. Zig validates: table index is in range (comptime-known table
count), key is non-zero (assertion), value bytes match the table's
row type layout (comptime `@sizeOf`). TypeScript can check field
names but not byte-level layout of the serialized value.

**Padding and alignment.** Extern structs have no_padding — every byte
is accounted for. The validator checks that optional fields have valid
presence flags (0 or 1, nothing else). Uninitialized or garbage bytes
in padding positions are impossible in the Zig type system but easy to
produce from TypeScript serialization bugs.

**Cross-field invariants.** `writes_len` must match the number of
populated write slots. `name_len` must be <= `name_max`. The items
in an order write must have non-zero `product_id` and `quantity`.
These are comptime-derivable from the type definitions and checked
in the validator. TypeScript relies on the developer to check these
manually.

**What TypeScript catches that Zig doesn't at this boundary:**
structural type errors in the developer's handler code (wrong field
name, wrong argument type). These are caught before the bytes reach
the socket. The two systems are complementary — TypeScript catches
errors at write time, Zig catches errors at the protocol boundary.

## Cache serialization design (Step 3b)

The prefetch cache has 11 slots. Not every operation uses every
slot — `get_product` needs one Product, `page_load_dashboard`
needs three lists. The question is how to serialize this for the
execute_render protocol message.

### Cache slots

| Slot | Type | Max size | Used by |
|------|------|----------|---------|
| `product` | `?Product` | 672 | get/create/update/delete product, add_collection_member |
| `product_list` | `ProductList` | 33,604 | list_products, get_collection, search, dashboard |
| `products` | `[20]?Product` | 13,460 | transfer_inventory, create/complete/cancel order |
| `collection` | `?ProductCollection` | 160 | get/create/delete collection, add/remove member |
| `collection_list` | `CollectionList` | 8,004 | list_collections, dashboard |
| `order` | `?OrderResult` | 3,632 | get/complete/cancel order |
| `order_list` | `OrderSummaryList` | 5,604 | list_orders, dashboard |
| `login_code` | `?LoginCodeEntry` | ~144 | request_login_code, verify_login_code |
| `user_by_email` | `?u128` | 16 | verify_login_code |
| `result` | `?StorageResult` | 1 | all mutating operations |
| `identity` | `?PrefetchIdentity` | ~34 | all operations (auth context) |

Total if all populated: ~65KB.

### Options considered

**A. Flat — serialize all slots every time.**
Fixed-size ~65KB buffer. Presence flags for nullable slots. Every
message is the same size regardless of operation.

Pro: no per-operation logic, protocol is operation-agnostic, one
struct in codegen. Con: 65KB per message even for get_product
which needs 673 bytes.

**B. Per-operation cache structs.**
Define a separate extern struct for each operation's cache needs.
`GetProductCache`, `DashboardCache`, etc.

Pro: minimal wire size. Con: ~20 structs, operation-specific
protocol, more codegen surface, protocol changes when operation
cache needs change.

**C. Tagged slot sequence.**
Variable-length: `[slot_tag][slot_data][slot_tag][slot_data]...`
Only populated slots are sent.

Pro: minimal wire size. Con: variable-length framing (violates
"no framing" design principle), parsing complexity.

### Decision: Option A (flat)

For a unix socket on the same machine, 65KB is noise:
- `memcpy` of 65KB: ~5μs
- SQLite write: ~50-100μs
- Kernel unix socket buffer: configurable, defaults to 128KB+
- No network, no serialization overhead, no GC pressure

The alternative designs save bandwidth at the cost of protocol
complexity. Every byte saved is a byte that never leaves the
machine anyway. The flat approach is:
- One PrefetchCache extern struct, known at comptime
- One read function, one write function (from codegen)
- Zero per-operation protocol logic
- Operation-agnostic — adding a new cache slot is one field

Presence encoding for nullable slots:
- `?Product` → `[1]u8` (0/1) + `[672]u8` (data, zeroed if absent)
- `[20]?Product` → `[20]u8` (per-item presence) + `[20]Product`
- Lists → always present, `len` field indicates populated count

### Write union serialization

The execute_render response carries up to 21 Write commands.
Each Write is a tagged union — the largest variant is OrderResult
(3,632 bytes).

Fixed-size approach: each write slot is `[tag: u8][pad: 15 bytes][data: 3,632 bytes]` = 3,648 bytes.
21 slots × 3,648 = 76,608 bytes.

This is large but the max case (21 × OrderResult) never occurs.
The real max is 1 × OrderResult + 20 × Product (1 × 3,632 + 20
× 672 = 17,072). But fixed-size means we allocate for the worst
case.

Alternative: variable-length writes with `[tag: u8][len: u16][data]`.
This breaks the fixed-size principle but saves 50KB+ in the
common case. Since the response also carries variable-length HTML
(`html_len` + `html[0..html_len]`), the message is already
effectively variable-length.

**Decision: tagged fixed-size write slots.** Each slot is padded
to the max variant size. Consistent with the flat principle.
The 76KB is the same order as the HTML buffer (98KB). Both are
allocated once at startup, not per-request.

### Execute+render message sizes

Request: tag(1) + operation(1) + id(16) + body(672) + identity(~50)
+ result(2) + cache(~65,000) + is_sse(1) + reserved ≈ **66KB**

Response: status(1) + writes_len(1) + writes(76,608) + result(~47,248)
+ html_len(4) + html(98,304) + reserved ≈ **222KB**

Both allocated as fixed-size buffers at startup. The unix socket
sends/receives the full buffer each time. For synchronous
request/response at 100 ops/sec, this is ~30MB/sec total
throughput — well within unix socket capacity.

### Open: Result union serialization

The Result tagged union (10 variants, largest ~47KB
PageLoadDashboardResult) contains non-extern structs (ProductList,
CollectionWithProducts) that can't be @bitCast-ed. Needs the same
treatment as the Write union: tag byte + fixed-size data region
padded to the max variant. Define the wire layout before
implementing Step 3b.

### Memory budget assertion

The sidecar uses one pair of fixed-size buffers (single connection,
single-threaded server). Assert the total at comptime:
```
comptime {
    assert(@sizeOf(ExecuteRenderRequest) + @sizeOf(ExecuteRenderResponse) < 300 * 1024);
}
```
If someone adds a cache slot or grows a list, the budget check
catches it before it ships. Explicit, not discovered at runtime.

## Two-path architecture (considered and settled)

The native Zig commit is the permanent storage authority. The sidecar
is the permanent rendering authority. This is not scaffolding — it's
the design.

**Native commit handles:** storage writes, auth (session cookies),
WAL (crash recovery), followup (SSE), prefetch reset. These are
framework lifecycle concerns that don't change regardless of who
writes the handlers.

**Sidecar handles:** translate (routing), execute (for rendering
decisions), render (HTML). The developer writes all three phases in
TypeScript. The HTML is served to the user.

**Correctness enforcement:**
- Type system: Status as a typed union catches wrong values at compile time
- Annotation scanner: missing handler → build error with clickable file:line
- Simulator: PRNG-driven operations exercise every handler path (test time)
- Unmapped request log: includes HTTP method + path for runtime diagnosis

**Why not sidecar write authority:** we implemented and reverted it.
Moving storage writes to the sidecar introduced three problems:
1. Partial write atomicity — sidecar writes applied one by one,
   partial commits on validation failure
2. Session management — native commit resolves auth from prefetch
   identity, skipping it broke login/logout
3. WAL inconsistency — WAL replays through native commit, sidecar
   writes diverge from replay

These are solvable but the solutions add complexity for a benefit
no user needs yet. The two-path architecture gives developers full
rendering control in TypeScript while the Zig handlers remain the
storage authority. Custom business logic that changes writes
requires updating the Zig handler — same as any backend change
in any framework.

**Sidecar failure renders natively.** If the sidecar socket call
fails, the native commit already ran. The framework renders from
the native result — consistent with the database state. This is
not a "fallback" (mixing execution paths) — it's rendering from
the authoritative commit that already happened.

## Not in scope

- WASM transport (future, for Rust sidecars)
- Auto-start sidecar from `zig build run`
- Hot reload of sidecar code
- Multiple concurrent sidecars
- Automatic fallback to Zig-native on sidecar failure

## Performance

Two round trips per request: ~40-100μs total.
SQLite write (WAL mode): ~50-100μs.
The sidecar hop is noise — storage is the bottleneck.

At 50μs per call, 20,000 ops/second through the sidecar.
A busy ecommerce site does 50-100 orders per minute.
Three orders of magnitude of headroom.
