# Message Bus — Framed IO Transport

> **Principle:** Always implement the most architecturally correct
> solution. The IO layer is the seam between application and OS.
> All socket communication goes through the message bus. No raw
> syscalls.

## What this is

Two layers, matching TigerBeetle's architecture:

- **Connection** — the transport primitive. Recv loop, send queue,
  frame accumulation, checksum validation, backpressure, 3-phase
  termination. Operates on an fd it's given. Knows nothing about
  how the fd was obtained.
- **MessageBus** — the lifecycle manager. Listen, accept, tick.
  Owns one Connection. Hands the accepted fd to the Connection.

TB's `message_bus.zig` has the same split: Connection is the inner
struct, MessageBus is the outer struct that manages connections.
We separate them into two types so each is independently testable
and evolvable:

- Connection is fuzzed in isolation (hand it an fd, fuzz recv/send)
- MessageBus is fuzzed for accept + connection lifecycle
- Worker-v2 gets the same Connection with its own MessageBus
- Outbound `connect()` is a MessageBus method — no Connection changes
- Multi-runtime pool owns N MessageBus instances, not N copies of
  accept+connection merged together

Protocol logic (CALL/RESULT, QUERY) lives in the consumer, not
in the transport. Worker deferred to worker-v2.

## Research phase (done)

### What we extracted (the core pattern)

TB's `message_bus.zig` is 1,214 lines. Most is cluster topology
(multi-peer, replica identity, reconnection). The core transport
is the `Connection` inner struct:

**Recv path:**
```
io.recv(fd, buf) → recv_callback
  → accumulate bytes into recv_buf
  → advance: validate header checksum, then body checksum
  → if complete valid frame: on_frame(frame)
  → if incomplete: re-submit io.recv
  → if recv suspended (backpressure): don't re-submit
```

**Send path:**
```
send_now: try non-blocking send (fast path, no epoll)
  → if complete: done
  → if partial/EAGAIN: fall through to async
io.send(fd, remaining) → send_callback
  → if partial: re-submit remaining bytes
  → if complete: done
```

**Termination (3-phase, TB pattern):**
```
terminate(how)     → set state to .terminating, optionally shutdown(fd)
terminate_join()   → wait for recv_submitted/send_submitted to clear
terminate_close()  → set both submitted flags TRUE (prevent re-entry),
                     close fd, reset to initial state
```

Every callback checks `state == .terminating` before doing work.
This prevents use-after-close races when IO is in-flight.

**Backpressure:**
```
suspend_recv() — stop submitting io.recv
resume_recv() — re-submit io.recv, drain buffered data
```

### What we skip (cluster-specific) and why

Each item was pressure-tested against future requirements
including worker-v2, multiple sidecar runtimes, and horizontal
scaling. Items are skipped only when our domain (hub-and-spoke,
unix-socket-per-role) genuinely doesn't need them.

- **Process identity (replica vs client).** TB discovers peer
  type from the first message because replicas and clients share
  a port. We use unix-socket-per-role: each connection type gets
  its own socket path. Identity is structural (which socket),
  not discovered (which message). Multiple sidecar runtimes
  would each get their own socket, not share one.

- **Multiple peer connections + connection pool.** One connection
  per bus instance. Multiple connections (e.g., N sidecar runtimes,
  or N instances for throughput) means N bus instances managed by
  a pool/dispatcher *above* the bus. The bus stays single-connection;
  the pool is a server-level concern built alongside concurrent
  pipeline work. This matches TB's design: each Connection is
  self-contained within the MessageBus.

- **Reconnection with exponential backoff.** TB reconnects outbound
  to peers. Our bus only accepts inbound. On disconnect,
  `terminate_close` resets to `.closed`, and `tick_accept()`
  re-accepts on the next tick. If outbound connections are ever
  needed, `connect()` + `tick_connect()` is additive — no redesign.

- **Message pool / reference counting.** TB needs ref counting
  because messages flow through multiple subsystems (replica →
  forward → replica). Our consumer always copies what it needs
  via `copy_state()` during the `on_frame_fn` callback. Frame
  data is invalidated by compaction after the callback returns.
  **Contract:** `on_frame_fn` must copy any data it needs to
  retain. This is documented on the callback, enforced by the
  compaction invariant, and tested in the fuzzer.

- **Suspended connections queue.** TB has an intrusive linked list
  of backpressured connections. We have one connection per bus
  instance. `recv_suspended: bool` is sufficient. Even with N
  bus instances, each has its own boolean — no coordination.

- **Sector alignment.** TB needs sector-aligned buffers for
  O_DIRECT storage IO. Our bus buffers are for socket IO only —
  they never touch the storage layer.

### What we adopt (from TB's Connection)

These patterns are architecturally correct and our plan must
include them:

1. **Explicit connection state enum.** TB's Connection has
   `free/accepting/connecting/connected/terminating`. Our
   Connection has `closed/connected/terminating`. Accept state
   lives in the MessageBus (`accept_pending: bool`), not in the
   Connection — the Connection doesn't know about accept.
   Assertions check state; compiler enforces exhaustive switches.

2. **3-phase termination.** `terminate → terminate_join →
   terminate_close`. Callbacks detect `.terminating` and call
   `terminate_join()` instead of processing. `terminate_close`
   sets both `recv_submitted` and `send_submitted` to `true`
   before calling `close()` to prevent `terminate_join` re-entry
   during the close. Prevents close-while-IO-in-flight races.

3. **Frame checksums.** TB validates header + body checksums
   incrementally as bytes arrive (`advance_header`, `advance_body`).
   Our frame format uses a 4-byte length prefix — a corrupted
   length could parse garbage. Add a checksum to the frame header:
   `[len: u32 BE][checksum: u32][payload]`. Validate at the
   boundary, trust inside.

4. **`send_now` fast path.** Try synchronous non-blocking send
   before submitting async IO. Small frames (most CALL/RESULT
   messages) fit in the kernel buffer — skip the epoll round-trip.
   TB does this in `send_now()` before falling back to `send()`.
   Returns `?usize` — `null` on WouldBlock (fall back to async).

5. **Incremental validation with `advance()`.** Validate bytes
   eagerly as they arrive. Cache validation state (`advance_pos`)
   so re-calling advance is a no-op for already-validated bytes.
   Don't re-read the length prefix every time.

6. **Deferred compaction.** Only memmove when there's no complete
   frame available (in `try_drain_recv`), not on every frame parse.
   Avoids unnecessary copies when multiple frames arrive in one
   recv. TB does this in `next_header()`.

7. **`recv_submitted` / `send_submitted` guards.** Boolean flags
   with assertions preventing double-submit. Every submit asserts
   `!submitted`; every callback clears it immediately.

8. **Re-entrancy safety.** `on_frame_fn` is called from inside
   `try_drain_recv` (which is called from `recv_callback`). The
   consumer may call `send_frame()` from inside `on_frame_fn`
   (this is the QUERY sub-protocol pattern). This is safe because
   `recv_submitted` is already `false` (cleared at top of
   `recv_callback`) and `send_submitted` is independent. After
   `on_frame_fn` returns, check state — the callback may have
   called `terminate()`. Document with `maybe(state == .terminating)`.

9. **Orderly shutdown vs error.** `recv` returning 0 bytes means
   the peer gracefully closed (FIN). `recv` returning an error
   means network failure. Different termination modes:
   - 0 bytes → `terminate(.no_shutdown)` (peer already closed)
   - error → `terminate(.shutdown)` (signal peer via shutdown syscall)

10. **Socket flags.** `SOCK_CLOEXEC` on socket creation (prevent
    fd leaks to child processes). `MSG_NOSIGNAL` on every send
    (prevent SIGPIPE on broken connections). `SOCK_NONBLOCK` on
    accepted fd (bus uses async IO).

11. **Socket buffer sizing.** Set `SO_SNDBUF` to
    `send_queue_max × (frame_max + frame_header_size)` so the
    kernel buffer can hold the entire send queue. TB does exactly
    this: `tcp_sndbuf = connection_send_queue_max × message_size_max`.
    Without this, the system default may be too small for 256KB
    frames, causing unnecessary partial sends and async fallbacks.

12. **Idle timeout.** If no complete frame arrives within N
    seconds, terminate the connection. Prevents a crashed or
    malicious sidecar from holding the connection open forever
    with a partial frame. TB relies on TCP keepalive for this;
    we need it at the frame level because unix sockets don't
    have keepalive.

### Decisions

**Accept:** MessageBus owns the accept (TB pattern). `listen()`
sets up the unix socket. `tick_accept()` submits async
`io.accept()`. Callback initializes the connection and kicks off
the recv loop. No blocking `listen_and_accept()` at startup.

**Response generation (SimSidecar):** Run the real sidecar
pipeline. The sim doesn't mock responses — it executes actual
handlers, produces semantically valid RESULT frames. Network
faults (loss, delay, disconnect) are orthogonal to content.
TB runs the real state machine in simulation; we do the same.

**Fuzzing:** Two layers (TB pattern):
1. Dedicated `message_bus_fuzz.zig` — synthetic IO with priority-
   queue event scheduling, configurable per-operation failure
   ratios, synthetic connection pairing. Swarm testing: all
   probabilities randomized per seed. Exercises the bus in
   isolation (like TB's `message_bus_fuzz.zig`).
2. Keep existing `sidecar_fuzz.zig` for CALL/RESULT protocol
   content validation.

**Worker:** Deferred to worker-v2.

**IO layer difference:** TB uses io_uring (async close with
completion callback). We use epoll with synchronous syscalls in
`execute()`. Our `close()` is synchronous (`posix.close(fd)`),
so `terminate_close` doesn't need an async close callback. But
we still need the `recv_submitted`/`send_submitted` guards
because epoll completions fire on the next `run_for_ns`.

**Why epoll is correct for now:** Load testing at 128 connections
(docs/internal/load-findings.md) shows IO syscall overhead is
<1% of CPU at 55K req/s. The server is CPU-bound (SQLite,
HTML rendering, HTTP parsing), not IO-bound. Switching to
io_uring saves ~1-2μs per request on an ~18μs request — noise.
The throughput bottleneck is the sidecar gap (55K native vs
13.6K sidecar — 3.9x), not the IO layer. See network-storage.md
for when io_uring becomes relevant (network storage with 500μs+
query latency — even then, pipeline depth matters more).

## Phase 0: MessagePool + Connection rewrite

Port TB's `StackType` and `MessagePool` verbatim. Rewrite
`ConnectionType` to use `*Message` pointers instead of static
`SendEntry` buffers. This is the foundation — Phase 1 shipped
with static buffers as a first pass; Phase 0 corrects to TB's
architecture before Phase 2 builds on it.

### Port from TigerBeetle (copy, don't rewrite)

**`stack.zig`** → `framework/stdx/stack.zig` (120 lines)
- TB's `src/stack.zig` — intrusive LIFO linked list
- `StackType(T)` with `push`, `pop`, `peek`, `empty`, `count`
- Only dependency: `stdx` (already in our codebase)
- Copy verbatim. Change `constants` import to local verify flag.

**`message_pool.zig`** → `framework/message_pool.zig` (~100 lines)
- Stripped from TB's `src/message_pool.zig` (344 lines)
- Remove: VSR types (Header, Command, ProcessType), sector
  alignment, `CommandMessageType`, `Options` union, `body_used`,
  `build`, `into`, `into_any`
- Keep: `Message` struct (`buffer`, `references`, `link`),
  `init_capacity`, `get_message`, `ref`, `unref`, `deinit`,
  `FreeList` (StackType)
- Parameterize on `buf_max: u32` (our `frame_max + 8`)

**Resulting Message struct:**
```zig
pub const Message = struct {
    buffer: *[buf_max]u8,
    references: u32 = 0,
    link: FreeList.Link = .{},

    pub fn ref(message: *Message) *Message {
        assert(message.references > 0);
        assert(message.link.next == null);
        message.references += 1;
        return message;
    }
};
```

### Connection rewrite

**Send queue:** `RingBufferType(*Message, .{ .array = send_queue_max })`
- Holds `*Message` pointers, not embedded 256KB entries
- `send_frame` → get message from pool, build payload + CRC,
  queue pointer, kick send loop
- `begin_frame` → get message from pool, return writable slice
- `commit_frame` → write header + CRC, queue pointer
- `send_now` → reads from `message.buffer[send_pos..]` directly
- `send_callback` → `pool.unref` when fully sent
- `terminate_close` → `pool.unref` all queued messages

**Recv buffer:** `*Message` from pool (not embedded `[recv_buf_max]u8`)
- `init` → get message from pool for recv buffer
- `recv` → reads into `message.buffer[recv_pos..]`
- `on_frame_fn` → consumer can `ref` the message to keep data
  alive past callback (eliminates `copy_state`)
- `terminate_close` → `pool.unref` recv message

**Memory difference:**
- Old: 1MB+ per Connection (static recv_buf + 4 × send_bufs)
- New: Connection struct is ~200 bytes. Buffers live in the pool.
  Pool is shared — idle connections hold no buffers.

### Pool sizing

```zig
const messages_max = 1   // recv buffer
    + send_queue_max     // send queue (worst case: all slots full)
    + 1;                 // burst (get_message during on_frame_fn)
```

For sidecar (send_queue_max = 2): 4 messages = 4 × 256KB = 1MB pool.

### Checklist

- [ ] Copy `stack.zig` → `framework/stdx/stack.zig`.
- [ ] Build `MessagePool` in `framework/message_pool.zig` —
  stripped from TB, parameterized on `buf_max`.
- [ ] Rewrite `ConnectionType` send queue: `*Message` pointers.
- [ ] Add `begin_frame` / `commit_frame` (zero-copy write path).
- [ ] Keep `send_frame` as convenience wrapper.
- [ ] Rewrite `ConnectionType` recv buffer: `*Message` from pool.
- [ ] `on_frame_fn` delivers slice into recv message buffer.
- [ ] `terminate_close` unrefs all messages.
- [ ] `defer self.invariants()` on all entry points.
- [ ] Update MessageBusType to create pool + pass to Connection.
- [ ] Update all tests.
- [ ] All unit tests pass.
- [ ] All sim tests pass.

## Phase 1: Connection + MessageBus

~350 lines, two types in `message_bus.zig`.

Both types are parameterized at comptime. Every consumer states
its bounds explicitly — no hardcoded constants that silently
over- or under-allocate.

### Frame format

```
[payload_len: u32 BE][crc32: u32][payload bytes]
```

CRC-32 covers `len_bytes ++ payload_bytes` — not just the
payload (see implementation constraint #5 for algorithm choice,
#6 for why the length is included). Validated during `advance()`
before the frame is delivered to the consumer.

```zig
// Write (send_frame):
var crc = Crc32.init();
crc.update(buf[0..4]);     // length prefix
crc.update(buf[8..8+len]); // payload
write_u32(buf[4..8], crc.final());

// Read (advance):
var crc = Crc32.init();
crc.update(recv_buf[frame_start..frame_start + 4]);          // length prefix
crc.update(recv_buf[frame_start + 8 .. frame_start + total]); // payload
if (crc.final() != read_u32(recv_buf[frame_start + 4..])):
  terminate(.shutdown)
```

Two non-contiguous regions with the CRC field in between.
Zig's `Crc32` supports incremental `update()` — same bytes
hashed, no performance cost vs single-region CRC.

A corrupted length that exceeds `frame_max` → terminate before
CRC (cheap bounds check). A corrupted length ≤ `frame_max` →
CRC mismatch (length is included in checksum) → terminate. No
undetected truncation possible.

### ConnectionType — transport primitive

The Connection doesn't know how it got the fd. It doesn't listen,
accept, or connect. It operates on an fd it's given via `init()`.
This means it's testable in isolation — hand it a socketpair fd
and fuzz recv/send/terminate without any accept machinery.

Parameterized at comptime so each consumer states its bounds:

```zig
pub fn ConnectionType(comptime IO: type, comptime options: Options) type {
    pub const Options = struct {
        /// Max queued outgoing frames. Sidecar: 2 (serial).
        /// Worker: 4 (concurrent dispatch). Must be >= 2 for
        /// CALL + QUERY_RESULT to coexist.
        send_queue_max: u32 = 4,
        /// Max frame payload size. Matches protocol.frame_max.
        frame_max: u32 = protocol.frame_max,
    };

    return struct {
        const Self = @This();

        io: *IO,
        state: State,
        fd: IO.fd_t,

        // Recv: accumulation buffer for partial reads.
        recv_buf: [recv_buf_max]u8,
        recv_pos: u32,          // bytes received (end of data)
        advance_pos: u32,       // bytes validated (checksum-checked)
        process_pos: u32,       // bytes consumed by on_frame_fn
        recv_completion: IO.Completion,
        recv_submitted: bool,
        recv_suspended: bool,

        // Send: bounded queue of outgoing frames (TB pattern).
        // Pre-allocated static buffers, no dynamic alloc.
        send_bufs: [options.send_queue_max][send_buf_max]u8,
        send_queue: BoundedRing(options.send_queue_max),
        send_pos: u32,
        send_completion: IO.Completion,
        send_submitted: bool,

        // Consumer callback — called with complete frame data.
        // May call send_frame() re-entrantly (QUERY sub-protocol).
        // May call terminate() (protocol error).
        // Frame data is valid only during this callback — consumer
        // must copy via copy_state() if data is needed later.
        on_frame_fn: *const fn (context: *anyopaque, frame: []const u8) void,
        context: *anyopaque,

        const State = enum {
            /// Not initialized or closed after terminate.
            closed,
            /// Connected. Recv/send loops active.
            connected,
            /// Terminating. Waiting for in-flight IO to complete.
            terminating,
        };

        // Buffer sizing — derived from options at comptime.
        const frame_header_size = 8; // 4 len + 4 checksum
        const recv_buf_max = options.frame_max + frame_header_size;
        const send_buf_max = options.frame_max + frame_header_size;

        comptime {
            assert(options.frame_max == protocol.frame_max);
            assert(frame_header_size == 8);
            assert(recv_buf_max <= std.math.maxInt(u32));
            assert(options.send_queue_max >= 2);
        }

        // --- Public API ---

        /// Initialize with an fd. Zeros all state, kicks off recv loop.
        /// Called by MessageBus after accept, or directly in tests.
        pub fn init(self: *Self, io: *IO, fd: IO.fd_t, context: *anyopaque) void;
        pub fn send_frame(self: *Self, data: []const u8) void;
        pub fn suspend_recv(self: *Self) void;
        pub fn resume_recv(self: *Self) void;
        pub fn terminate(self: *Self, how: enum { shutdown, no_shutdown }) void;

        // --- Internal ---

        fn submit_recv(self: *Self) void;
        fn recv_callback(context: *anyopaque, result: i32) void;
        fn advance(self: *Self) void;
        fn try_drain_recv(self: *Self) void;
        fn send(self: *Self) void;
        fn send_now(self: *Self) void;
        fn submit_send(self: *Self) void;
        fn send_callback(context: *anyopaque, result: i32) void;
        fn terminate_join(self: *Self) void;
        fn terminate_close(self: *Self) void;

        fn invariants(self: *const Self) void;
    };
}
```

### MessageBusType — lifecycle manager

Owns one Connection. Handles listen, accept, reconnect-on-
disconnect. The Connection doesn't know it exists.

```zig
pub fn MessageBusType(comptime IO: type, comptime options: ConnectionType(IO, .{}).Options) type {
    const Connection = ConnectionType(IO, options);

    return struct {
        const Self = @This();

        io: *IO,
        connection: Connection,

        // Listen/accept — one connection only.
        listen_fd: IO.fd_t,
        accept_completion: IO.Completion,
        accept_pending: bool,

        // --- Public API ---

        pub fn listen(self: *Self, path: []const u8) void;
        pub fn tick_accept(self: *Self) void;

        // Delegate to connection.
        pub fn send_frame(self: *Self, data: []const u8) void {
            self.connection.send_frame(data);
        }
        pub fn suspend_recv(self: *Self) void {
            self.connection.suspend_recv();
        }
        pub fn resume_recv(self: *Self) void {
            self.connection.resume_recv();
        }

        // --- Internal ---

        fn accept_callback(context: *anyopaque, result: i32) void;
    };
}
```

**Why the delegation methods?** The consumer (SidecarClient) holds
a `*MessageBus`. It calls `bus.send_frame()`. The bus delegates to
`connection.send_frame()`. The consumer never touches the Connection
directly — the bus is the public interface. This means we can later
add a connection pool inside the bus without changing consumers.

### Comptime parameterization

Each consumer declares its bounds at the type level:

```zig
// Sidecar: serial protocol, small queue.
const SidecarBus = MessageBusType(IO, .{ .send_queue_max = 2 });

// Worker: concurrent dispatch, larger queue.
const WorkerBus = MessageBusType(IO, .{ .send_queue_max = 4 });

// Fuzz test: exercise edge cases.
const FuzzBus = MessageBusType(FuzzIO, .{ .send_queue_max = 4 });
```

Buffer sizes are derived at comptime. `SidecarBus` allocates
2 × 256KB send buffers. `WorkerBus` allocates 4 × 256KB. No
over-allocation, no under-allocation. The bound is in the type,
not a runtime constant.

### Accept (MessageBus)

```
listen(path):
  assert(connection.state == .closed)
  unlink stale socket
  socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC)
  bind(path), listen(fd, 1)
  listen_fd = fd

tick_accept:
  if connection.state != .closed: return  // connected or terminating
  if accept_pending: return               // accept in-flight
  accept_pending = true
  io.accept(listen_fd, &accept_completion, accept_callback)

accept_callback:
  accept_pending = false
  if result < 0: return          // try again next tick
  accepted_fd = result
  // Set CLOEXEC + NONBLOCK on accepted fd.
  // Set SO_SNDBUF to send_queue_max × send_buf_max.
  connection.init(io, accepted_fd, on_frame_fn)  // hand fd to Connection
```

### Connection.init

```
init(io, fd, context):
  assert(state == .closed)
  self.io = io
  self.fd = fd
  self.context = context
  // Zero all mutable state — Connection may be reused after
  // terminate_close. Don't assume fields are zero-initialized.
  self.recv_pos = 0
  self.advance_pos = 0
  self.process_pos = 0
  self.recv_submitted = false
  self.recv_suspended = false
  self.send_queue.clear()
  self.send_pos = 0
  self.send_submitted = false
  state = .connected
  submit_recv()                 // kick off recv loop
```

After `terminate_close`, the Connection resets to `.closed`.
The bus's `tick_accept()` sees `.closed` and re-accepts.
Reconnection is automatic — no special logic.

### Recv path with incremental validation

```
submit_recv:
  assert(state == .connected)
  assert(!recv_submitted)
  assert(!recv_suspended)
  recv_submitted = true
  io.recv(fd, recv_buf[recv_pos..], &recv_completion, recv_callback)

recv_callback:
  recv_submitted = false
  if state == .terminating: terminate_join(); return
  assert(state == .connected)
  if result < 0: terminate(.shutdown); return   // network error
  if result == 0: terminate(.no_shutdown); return // orderly peer close
  recv_pos += result
  // Buffer full with incomplete frame — peer is stuck or malicious.
  // (See implementation constraint #3.)
  if recv_pos == recv_buf_max and advance_pos < recv_pos:
    terminate(.shutdown); return
  advance()                     // validate newly received bytes
  if state != .connected: return // advance() may have terminated
  try_drain_recv()

advance:
  // Validate as many complete frames as possible beyond advance_pos.
  // Called after recv_callback (new bytes) and after try_drain_recv
  // consumes a frame (process_pos advanced, try next frame).
  //
  // Frame layout within recv_buf starting at frame_start:
  //   [0..4]            — payload length (u32 BE)
  //   [4..8]            — CRC-32 checksum
  //   [8..8+len]        — payload bytes
  //
  // advance_pos tracks validation progress relative to the current
  // frame_start. Two intermediate positions:
  //   frame_start + 4     — length prefix validated
  //   frame_start + 8+len — full frame validated (= next frame_start)
  //
  while true:
    frame_start = advance_pos
    // If advance_pos is mid-frame (between frame_start+4 and
    // frame_start+8+len), this is a re-entry after partial recv.
    // We check both stages each iteration.

    // Stage 1: need 4 bytes for length prefix.
    if recv_pos - frame_start < 4: return
    len = read_u32_be(recv_buf[frame_start..])
    if len > frame_max: terminate(.shutdown); return

    // Stage 2: need 4 checksum + len payload bytes.
    total = 8 + len  // frame_header_size + payload
    if recv_pos - frame_start < total: return
    // Validate checksum (covers len + payload, not just payload).
    assert(frame_start + total <= recv_buf_max)  // bounds proof
    stored_crc = read_u32(recv_buf[frame_start + 4..])
    var crc = Crc32.init()
    crc.update(recv_buf[frame_start .. frame_start + 4])       // len bytes
    crc.update(recv_buf[frame_start + 8 .. frame_start + total]) // payload
    if crc.final() != stored_crc:
      terminate(.shutdown); return
    advance_pos = frame_start + total  // frame validated
    // Loop to validate next frame if bytes are available.

try_drain_recv:
  // Deliver validated, unconsumed frames.
  while advance_pos > process_pos:
    len = read_u32_be(recv_buf[process_pos..])
    frame = recv_buf[process_pos + 8 .. process_pos + 8 + len]
    // Don't compact yet — just advance process_pos.
    process_pos += 8 + len
    on_frame_fn(context, frame)
    // on_frame_fn may have called terminate() or suspend_recv().
    maybe(state == .terminating)
    if state != .connected: return
    if recv_suspended: return

  // All frames consumed. Compact: move unvalidated tail to front.
  if process_pos > 0:
    remaining = recv_pos - process_pos
    memmove(recv_buf, recv_buf[process_pos..], remaining)
    recv_pos = remaining
    advance_pos = 0
    process_pos = 0

  if !recv_suspended and state == .connected:
    submit_recv()
```

Key details:
- `advance()` validates **all** complete frames in the buffer,
  not just one. If a single recv delivers bytes for three frames,
  advance validates all three. `try_drain_recv` delivers all three.
  Compaction runs once after all are consumed.
- `advance()` is idempotent — if called again with no new bytes
  (`recv_pos` unchanged), `recv_pos - frame_start < 4` exits
  immediately.
- After `on_frame_fn`, check state — the callback may have called
  `terminate()` or `suspend_recv()`. The `maybe()` documents that
  state may have changed (TB pattern from `recv_buffer_drain`).
- `on_frame_fn` may re-entrantly call `send_frame()` — this is
  safe because `recv_submitted` is already `false` and `send` uses
  separate completion/flag.

### Send path with queue and fast path

TB uses a ring buffer send queue (`connection.send_queue`) so
multiple frames can be queued while a send is in-flight. We
adopt this for two reasons:

1. **Worker-v2** dispatches concurrent CALLs — the server may
   queue multiple CALL frames in a single tick.
2. **Re-entrancy** — `on_frame_fn` may call `send_frame()` (QUERY
   sub-protocol) while the bus is inside `try_drain_recv`. If a
   previous send is still in-flight (async fallback), the queue
   absorbs the new frame.
3. **Future multi-runtime sidecars** — a dispatcher rapidly
   assigning requests benefits from queuing at the transport
   level rather than back-pressuring up to the inbox.

The queue is a bounded ring of static buffers. `send_queue_max`
is 4 (TB uses 2-4 per connection type). Each slot is a full
`send_buf_max` buffer. Pre-allocated, no dynamic allocation.

```
send_frame(data):
  assert(state == .connected)
  assert(data.len <= frame_max)
  assert(!send_queue.full())    // bounded: consumer must respect
  // Build framed data into next queue slot.
  slot = send_queue.push()
  buf = &send_bufs[slot]
  write_u32_be(buf[0..4], data.len)
  @memcpy(buf[8..8+data.len], data)
  // CRC covers len + payload (see frame format section).
  var crc = Crc32.init()
  crc.update(buf[0..4])              // len bytes
  crc.update(buf[8..8+data.len])     // payload
  write_u32(buf[4..8], crc.final())
  send_queue.set_len(slot, 8 + data.len)
  // Kick the send loop if not already running.
  if !send_submitted: send(self)

send:
  // TB pattern: try send_now fast path, then async fallback.
  assert(state == .connected)
  send_now()                    // drain as much as possible
  if state != .connected: return // send_now may have terminated
  head = send_queue.head() orelse return  // nothing left
  submit_send()                 // async for remainder

send_now:
  // Non-blocking send via IO layer — skip epoll if kernel buffer
  // has room. Goes through self.io.send_now() so SimIO/FuzzIO can
  // intercept it (see implementation constraint #2).
  while send_queue.head() is not null:
    buf = &send_bufs[send_queue.head_index()]
    len = send_queue.head_len()
    while send_pos < len:
      n = self.io.send_now(fd, buf[send_pos..len]) orelse return  // WouldBlock
      if n == 0: terminate(.no_shutdown); return
      send_pos += n
    // Frame fully sent. Pop and move to next.
    send_queue.pop()
    send_pos = 0

submit_send:
  assert(!send_submitted)
  send_submitted = true
  buf = &send_bufs[send_queue.head_index()]
  len = send_queue.head_len()
  io.send(fd, buf[send_pos..len], &send_completion, send_callback)

send_callback:
  send_submitted = false
  if state == .terminating: terminate_join(); return
  assert(state == .connected)
  if result <= 0: terminate(.no_shutdown); return
  send_pos += result
  len = send_queue.head_len()
  if send_pos == len:
    send_queue.pop()
    send_pos = 0
  send(self)                    // continue: next frame or re-submit
```

Key differences from the old single-buffer plan:
- `send_frame()` no longer asserts `!send_submitted` — it
  pushes to the queue. The queue may have room even while a
  send is in-flight.
- `send()` is the top-level loop (TB's `send` function). It
  calls `send_now()` then `submit_send()`.
- `send_now()` drains multiple frames synchronously if the
  kernel buffer has room. Each completed frame is popped.
- `send_callback` pops the completed frame and re-enters `send()`
  to drain the next one.
- Queue full → assert. The consumer must not exceed the queue
  depth. This is a compile-time-known bound, not a runtime
  surprise. TB does the same: `if (connection.send_queue.full())
  { log ... return; }`.

### Termination (3-phase, TB pattern)

```
terminate(how):
  // Phase 1: initiate. Optionally shutdown the socket.
  if state == .terminating: return  // already terminating
  assert(state != .closed)
  if how == .shutdown:
    posix.shutdown(fd, .both) catch {}
  state = .terminating
  terminate_join()

terminate_join:
  // Phase 2: wait for in-flight IO.
  assert(state == .terminating)
  if recv_submitted: return     // callback will re-call us
  if send_submitted: return     // callback will re-call us
  terminate_close()

terminate_close:
  // Phase 3: close fd, drain queue, reset all state.
  assert(state == .terminating)
  assert(!recv_submitted)
  assert(!send_submitted)
  // Set both submitted flags TRUE to prevent terminate_join
  // re-entry during close (TB pattern, line 1033-1034).
  recv_submitted = true
  send_submitted = true
  // Drain send queue (TB: while (connection.send_queue.pop())).
  send_queue.clear()
  io.close(fd)                  // synchronous (our IO is epoll)
  // Reset all state.
  fd = -1
  recv_pos = 0
  advance_pos = 0
  process_pos = 0
  recv_submitted = false
  send_submitted = false
  recv_suspended = false
  send_pos = 0
  state = .closed
  // MessageBus's tick_accept() sees .closed, re-accepts.
```

Why 3-phase matters: if we just called `close(fd)` while
`recv_submitted == true`, the kernel could complete the recv
on the closed fd (or a recycled fd). The `.terminating` state
ensures every callback drains before we touch the fd.

Why set submitted flags `true` before close: prevents
`terminate_join()` from being re-entered if another code path
somehow reaches it while close is executing. Belt and suspenders.

### Invariants

```
invariants:
  // Position chain (TB's suspend_size ≤ process_size ≤ advance_size ≤ receive_size).
  assert(process_pos <= advance_pos)
  assert(advance_pos <= recv_pos)
  assert(recv_pos <= recv_buf_max)
  // Send queue bounds.
  assert(send_queue.count() <= send_queue_max)
  if send_queue.count() > 0:
    assert(send_pos <= send_queue.head_len())
  else:
    assert(send_pos == 0)
  // Submitted guards.
  if recv_submitted: assert(state == .connected or state == .terminating)
  if send_submitted:
    assert(state == .connected or state == .terminating)
    assert(send_queue.count() > 0) // must have something to send
  // State consistency.
  if state == .closed:
    assert(fd == -1)
    assert(!recv_submitted)
    assert(!send_submitted)
    assert(recv_pos == 0)
    assert(advance_pos == 0)
    assert(process_pos == 0)
    assert(send_queue.count() == 0)
  if state == .connected: assert(fd != -1)
  if state == .terminating: assert(fd != -1)  // not closed yet
  // Suspension consistency.
  if recv_suspended: assert(!recv_submitted)
```

### IO interface contract

The `IO` type parameter must provide these methods. Real IO
(epoll), SimIO, and FuzzIO all implement this interface:

```zig
fn accept(io: *IO, listen_fd: fd_t, completion: *Completion,
          context: *anyopaque, callback: Callback) void;
fn recv(io: *IO, fd: fd_t, buffer: []u8, completion: *Completion,
        context: *anyopaque, callback: Callback) void;
fn send(io: *IO, fd: fd_t, buffer: []const u8, completion: *Completion,
        context: *anyopaque, callback: Callback) void;
fn send_now(io: *IO, fd: fd_t, buffer: []const u8) ?usize;
fn close(io: *IO, fd: fd_t) void;
fn shutdown(io: *IO, fd: fd_t, how: posix.ShutdownHow) void;
```

`send_now` is the only new addition to our existing IO layer.
Real IO calls `posix.send` with `MSG.DONTWAIT | MSG.NOSIGNAL`.
SimIO returns PRNG-driven partial or null. The `shutdown` method
is also new — wraps `posix.shutdown`, SimIO marks the connection.

### Checklist

**Port from TigerBeetle (copy, don't rewrite):**
- [ ] Copy TB's `src/stdx/ring_buffer.zig` → `framework/ring_buffer.zig`.
  292 lines of implementation + 220 lines of tests. Copy the file
  verbatim — do not rewrite, adapt, or simplify. This is
  production-tested code. The only change is the import path for
  `stdx.copy_disjoint` (already in `framework/stdx.zig`). Use
  `.array` variant (comptime capacity, no allocator).

**ConnectionType (transport primitive):**
- [ ] `ConnectionType(IO, Options)` with comptime parameterization.
- [ ] `Options`: `send_queue_max`, `frame_max` with defaults.
- [ ] Connection `State` enum: closed/connected/terminating.
- [ ] `init(io, fd, context)` — zero all state, set fd, kick off recv loop.
- [ ] `submit_recv` + `recv_callback` — recv loop.
- [ ] `advance()` — incremental checksum validation.
- [ ] `try_drain_recv` — frame delivery + deferred compaction.
- [ ] `maybe(state == .terminating)` after `on_frame_fn` calls.
- [ ] Re-entrancy: `send_frame` callable from `on_frame_fn`.
- [ ] Send queue: `BoundedRing(options.send_queue_max)` + static `send_bufs`.
- [ ] `send_frame` pushes to queue, kicks send loop if idle.
- [ ] `send` + `send_now` — drain queue via fast path.
- [ ] `send_now` returns on WouldBlock (optional return).
- [ ] `MSG_NOSIGNAL` on every send (sync and async).
- [ ] `submit_send` + `send_callback` — async send fallback.
- [ ] `send_callback` pops completed frame, re-enters `send()`.
- [ ] `suspend_recv` + `resume_recv` — backpressure.
- [ ] `terminate` — orderly (0 bytes) vs error (negative) dispatch.
- [ ] `terminate` + `terminate_join` + `terminate_close` — 3-phase.
- [ ] `terminate_close` sets submitted flags `true`, drains queue.
- [ ] `invariants()` — position chain + state + send queue bounds.
- [ ] Context pointer: `on_frame_fn(context, frame)`, not `(*Self, frame)`.
- [ ] Frame format: `[len: u32 BE][crc32: u32][payload]`, CRC covers len + payload.
- [ ] Comptime assertions: buffer sizes, frame_max, send_queue_max.
- [ ] Buffer-full guard: terminate if recv_pos == recv_buf_max and incomplete.
- [ ] `send_now` goes through `self.io.send_now()`, not `posix.send`.

**MessageBusType (lifecycle manager):**
- [ ] `MessageBusType(IO, Options)` — owns one Connection.
- [ ] `listen()` — unix socket setup with `SOCK_CLOEXEC`.
- [ ] `tick_accept()` + `accept_callback` — async accept.
- [ ] `accept_callback` calls `connection.init(io, fd, context)`.
- [ ] `SO_SNDBUF` set to `send_queue_max × send_buf_max`.
- [ ] Delegation: `send_frame`, `suspend_recv`, `resume_recv`.
- [ ] Reconnect: `tick_accept` re-accepts when connection is `.closed`.
- [ ] Idle timeout: terminate if no complete frame within N seconds.

**IO layer additions:**
- [ ] `IO.send_now(fd, buf) ?usize` — non-blocking send, returns null on WouldBlock.
- [ ] `IO.shutdown(fd, how)` — wraps posix.shutdown.
- [ ] `SimIO.send_now` — PRNG-driven partial/null.
- [ ] `SimIO.shutdown` — marks connection shutdown state.
- [ ] `FuzzIO.send_now` — configurable `send_now_probability`.

## Phase 1.5: Consolidated Pipeline — Async Handler Interface

> **TB insight:** The SM pipeline is the single protocol. The
> handler is the pluggable implementation. The replica doesn't
> know if prefetch was satisfied from cache or required a disk
> read. Same interface, different backends.
>
> **Reverted: Gateway approach.** The gateway pattern tried to
> solve a protocol problem by extracting HTTP into a separate
> component. But HTTP decoding is an edge concern — not a core
> concern. The core is the SM pipeline (prefetch → handle →
> render). The handler implementation (native SQLite vs sidecar
> CALL/RESULT) is behind the handler interface. The server and
> SM don't know which one is running.

### Architecture

```
Edge (decode):  HTTP → parse request
                          ↓
Core (single):  SM pipeline: route → prefetch → handle → render
                Handler impl: native (sync) OR sidecar (async)
                All four stages async-capable.
                          ↓
Edge (encode):  HTTP response
```

The edges decode/encode external protocols. The core processes
requests through one pipeline of four stages. Every stage uses
the same interface: call handler → if `.pending`, return →
callback resumes → call again (idempotent) → complete → advance.

In native mode, all four stages return synchronously. In sidecar
mode, all four return `.pending` and resume via callback. Same
interface, same pipeline, no shims, no blocking.

**Route is a pipeline stage, not a pre-pipeline function.**
`translate()` moves from `process_inbox` (called before the
pipeline) into the pipeline as the first stage. `process_inbox`
passes the raw parsed HTTP data to the pipeline. The route
handler resolves it to a typed Message (native: pattern matching,
sidecar: CALL "route"). No `io.run_for_ns(0)` shim.

**Future protocols (WebSocket, gRPC, admin CLI) add new edges,
not new core paths.** Each edge decodes its protocol into raw
request data, feeds the SM pipeline, and encodes the response.
The pipeline and handlers don't change.

### What all-async unlocks

1. **Worker integration is trivial.** A worker handler is just
   another async handler. `handler_fulfill_order()` sends a CALL
   to the worker, returns `.pending`. No new stages.
2. **Hybrid native + sidecar.** Per-operation handler selection.
   Some ops handled by Zig (sync), others by sidecar (async).
3. **Route testable through pipeline.** Fuzzer exercises the full
   path: route → prefetch → handle → render.
4. **Zero blocking.** No `io.run_for_ns(0)` shim. Every stage
   returns control to the event loop. Foundation for concurrent
   pipeline (network-storage.md).
5. **Simpler SidecarHandlersType.** Every handler method has the
   same pattern. No special case for route being sync.

### What changes

**SM `PrefetchResult` gains `.pending` back — but correctly.**

The SM's `prefetch()` returns `.pending` when the handler needs
async IO. This is TB's pattern: `commit_prefetch()` returns
`.pending`, the callback fires, `commit_dispatch_resume()`
continues. The SM doesn't know if the handler used SQLite or
the sidecar — it just calls the handler and handles the result.

```zig
pub const PrefetchResult = enum {
    complete, // Handler returned data synchronously.
    busy,     // Storage busy — retry next tick.
    pending,  // Handler needs async IO — callback resumes.
};
```

**Handlers support async natively.**

The handler interface gains async support as a first-class
capability, not a sidecar special case:

```zig
// Native handler: sync — returns cache immediately.
fn handler_prefetch(storage, msg) ?Cache {
    return dispatch_prefetch(storage, msg); // SQLite query
}

// Sidecar handler: async — sends CALL, returns null.
// Bus callback fires → call_state = .complete → SM resumes.
fn handler_prefetch(storage, msg) ?Cache {
    switch (sidecar.call_state) {
        .idle => { sidecar.call_submit(bus, "prefetch", args); return null; },
        .receiving => return null,  // still pending
        .complete => { build cache from result; return cache; },
        .failed => return null,
    }
}
```

The SM calls the handler. The handler returns null for "not
ready" (busy or pending). The SM distinguishes via
`is_handler_pending()` — same as before, but through the
handler interface, not a sidecar-specific side channel.

**Server `commit_dispatch` has ONE set of stages.**

```
.route → .prefetch → .handle → .render
```

Four stages, all async-capable. Same for native and sidecar.
No `sidecar_*` stages. The handler implementation decides sync
vs async. The server doesn't know.

**`CommitStage` enum:**

```zig
const CommitStage = enum {
    idle,
    route,     // Resolve raw HTTP to typed Message
    prefetch,  // Load data for the operation
    handle,    // Execute business logic + writes
    render,    // Produce response (HTML/JSON)
};
```

**Server pipeline flow:**

When `sm.route()` / `sm.prefetch()` / etc. returns `.pending`:
- Server returns from `commit_dispatch`
- Bus callback fires `on_frame` → handler state updates
- `on_frame` calls `commit_dispatch` to resume
- SM calls handler again (idempotent) → `.complete` → advance

**`process_inbox` simplifies:**

```zig
fn process_inbox(server: *Server) void {
    for (connections) |*conn| {
        if (conn.state != .ready) continue;
        if (server.commit_stage != .idle) break;

        const parsed = http.parse_request(conn.recv_buf);
        // Don't call translate — route is a pipeline stage now.
        server.commit_stage = .route;
        server.commit_connection = conn;
        server.commit_parsed = parsed;  // raw HTTP data
        server.commit_dispatch();
    }
}
```

### What this eliminates

- `sidecar_route`, `sidecar_prefetch`, `sidecar_handle`,
  `sidecar_render` stages — all deleted from server.
- `if (App.sidecar_mode)` branch in `process_inbox` — deleted.
  HTTP parsing happens in both modes (the sidecar route is
  handled by the sidecar handler during translate, using
  `io.run_for_ns(0)` for the synchronous route CALL — this is
  the one acceptable shim, outside the pipeline).
- Sidecar bus/client fields on server — stay on server (server
  owns IO) but the server doesn't orchestrate CALL/RESULT. The
  handlers do, through the bus that the server provides.

### Sidecar handler IO — who calls the bus?

The handlers don't call the bus directly (handlers don't do IO).
The handlers call through a `SidecarProvider` that wraps the
bus. The provider is set at init time:

```zig
// App composition root:
pub const Handlers = if (sidecar_mode)
    SidecarHandlersType(Storage, SidecarClient)
else
    NativeHandlersType(Storage);
```

`SidecarHandlersType` implements the same interface as
`NativeHandlersType` (handler_prefetch, handler_execute,
handler_render). Inside, it calls `sidecar_client.call_submit`
and checks `sidecar_client.call_state`. The SM and server see
the same interface regardless.

This is the comptime cascade: `App` chooses the handler
implementation at compile time. The SM is parameterized on
`Handlers`. The server is parameterized on `App`. One binary
for native mode, one binary for sidecar mode. No runtime
`if (sidecar_mode)` checks.

### Dependencies

This phase requires:
- Phase 0 (done): MessagePool + Connection
- Phase 1 (done): ConnectionType + MessageBusType
- The handler interface to support async (`.pending` + callback)

### Checklist

**SM pipeline:**
- [ ] Add `.route` stage to `CommitStage` enum.
- [ ] Restore `PrefetchResult.pending` (or generalize to
  `StageResult { complete, busy, pending }`).
- [ ] SM gains `route()` method — calls handler, returns result.
- [ ] All four stages (route, prefetch, handle, render) return
  the same result type with `.pending` support.
- [ ] SM callback mechanism: handler completes async →
  `commit_dispatch_resume()` via `on_frame`.
- [ ] `process_inbox` — don't call `translate()`, start pipeline
  at `.route` with raw parsed HTTP data.

**Handler interface:**
- [ ] `handler_route(method, path, body)` — async-capable.
  Native: pattern match + return. Sidecar: CALL "route" → pending.
- [ ] `handler_prefetch(storage, msg)` — async-capable (already).
- [ ] `handler_execute(cache, msg, fw, db)` — async-capable.
- [ ] `handler_render(cache, op, status, fw, buf, storage)` —
  async-capable.
- [ ] All four use same pattern: check state → if idle, start →
  if pending, return null → if complete, return result.
- [ ] `is_handler_pending()` — generic, not sidecar-specific.

**Comptime handler selection:**
- [ ] `SidecarHandlersType(Storage, SidecarClient)` — implements
  same interface as native handlers using sidecar protocol.
- [ ] `App` composition root selects handlers at comptime.
- [ ] Delete `sidecar_mode` runtime flag.
- [ ] No `if (sidecar_mode)` checks anywhere.

**Server:**
- [ ] `commit_dispatch` — four stages: route, prefetch, handle,
  render. No sidecar-specific stages.
- [ ] `.pending` result → return from dispatch. Callback resumes.
- [ ] Delete all `sidecar_*` stages.
- [ ] Delete sidecar bus/client fields from server (move to
  SidecarHandlersType or App).
- [ ] All existing tests pass.

**Phase 1.5 status: Steps 1-3 DONE. Remaining for Phase 2:**
- [x] `.route` stage added to pipeline (Step 1).
- [x] `.pending` support on prefetch (Step 2).
- [x] Sidecar stages deleted from server (Step 3).
- [x] `sidecar_mode` flag deleted.
- [x] `is_handler_pending()` on HandlersType (native: false).
- [x] Double HTTP parse eliminated.
- [x] Stale doc comments fixed.

**Known items for Phase 2 to address:**
- [x] ~~`sm.commit()` needs .pending~~ — REVERTED. Execute is
  permanently synchronous. TB pattern: irreversible side effects
  (SQL writes inside transaction) must not cross async boundaries.
  Sidecar handle CALL moves to prefetch. Documented in commit().
- [x] Tracer span cleanup on `.pending` failure: sidecar_on_close
  cancels tracer spans before pipeline_reset. timeout_idle also
  cancels if the timed-out connection has a pending pipeline.
- [x] `SidecarHandlersType` added alongside `HandlersType`.
  HandlersType kept as name (not renamed) — comptime selection
  via HandlersFor makes the distinction clear.
- [x] `commit_dispatch_entered` guard in place. sidecar_on_frame
  calls commit_dispatch — guard prevents nested execution.

**Sidecar CALL flow (corrected):**
```
prefetch: CALL "route" → CALL "prefetch" → CALL "handle"
          (all three async, all in prefetch stage)
          .pending until all three results arrive
execute:  parse handle RESULT, execute SQL writes
          (always sync — transaction opens, writes, closes)
render:   CALL "render"
          (async, .pending until HTML arrives)
```

The handle CALL loads data. Execute processes loaded data.
Same split as TB: prefetch is async IO, execute is computation.
Execute is permanently synchronous — see commit() doc comment.

## Phase 2: Sidecar Integration — DONE

> All three steps complete. Server compiles and runs in both
> native (`zig build`) and sidecar (`zig build -Dsidecar=true`)
> modes. Bus embedded in Server (TB pattern). TS wire format
> updated with CRC. Full pipeline wired end-to-end.

### Step 1: SidecarHandlersType — DONE

`sidecar_handlers.zig` implements the full Handlers interface,
delegating to the sidecar via CALL/RESULT protocol over the
message bus. TB-audited across two rounds.

**Architecture (TB-audited):**

- `Cache = void` — sidecar keeps its own prefetch data. The SM
  stores/passes the cache opaquely. void is the right primitive.
- Execute is permanently synchronous. The handle CALL happens
  during the prefetch stage via multi-phase state machine:
  `PrefetchPhase { idle → prefetch_pending → handle_pending }`.
  Execute just applies the parsed writes. No async in execute.
- Handler_route is async in the `.route` pipeline stage. Server
  checks `is_handler_pending()` after null from translate.
- Handler_render returns `?[]const u8`. Null = pending. Native
  handlers always return non-null. Shared interface.
- Server resolves `Handlers = App.HandlersFor(Storage, IO)`,
  then `SM = App.StateMachineWith(Storage, Handlers)`. The SM
  never sees IO — only the resolved Handlers type.
- Frame building uses `call_submit` → `protocol.build_call`
  (bounds checked before writing). `protocol.write_call_header`
  is the single source of truth for CALL frame format.
- Pair assertions at boundaries: `assert(prefetch_phase == .idle)`
  at handler_route and handler_execute entry. Catches stale state
  from missed resets.
- Render failure returns visible error HTML, not silent empty page.
- `parse_handle_result` reads status_name_len as u16 BE (matching
  protocol test vector format). Unknown session_action rejected.
- Re-entrancy documented: `process_sidecar_frame` called from
  bus's `try_drain_recv` loop. Send and recv state independent.
  `commit_dispatch_entered` guard prevents nested execution.

**Files changed:**

| File | Change |
|---|---|
| `sidecar_handlers.zig` | NEW |
| `app.zig` | `sidecar_enabled`, `HandlersFor`, `StateMachineWith`, `?[]const u8` render |
| `framework/server.zig` | `Handlers` alias, `.pending` in route/render, sidecar callbacks, timeout handling |
| `main.zig` | `HandlersFor` + `StateMachineWith` resolution |
| `sidecar.zig` | `reset_request_state` made public |
| `protocol.zig` | `write_call_header` added |
| `build.zig` | `sidecar_handlers.zig` in unit-test step |

### Step 2: TS wire format — 8-byte header with CRC

**Files:**
- `adapters/call_runtime.ts` — sendFrame, processFrames
- `generated/serde.ts` — readFrameLength, writeFrameHeader

**Changes:**
- sendFrame: write `[length: u32 BE][crc32: u32 LE][payload]`
- processFrames: read 8-byte header, validate CRC before parsing
- CRC-32 via `zlib.crc32()` (Node.js 22+ built-in)
- CRC covers `len_bytes ++ payload_bytes` (incremental, two regions)
- serde.ts: update readFrameLength to read 8 bytes, add CRC check

**Deferred from Step 1 — do in Step 2:**
- Update `call_submit` to accept `request_id` parameter (currently
  hardcoded to 0). Wire `next_request_id` through SidecarHandlersType.
  Protocol-level change coordinated with TS side.

**Coordination:** no migration or backward compatibility needed.
The sidecar is started by the server (`npm run dev`). Both
sides update in the same commit. No rolling upgrade.

### Step 3: End-to-end test + server wiring

**Deferred from Step 1 — do in Step 3:**
- Add `sidecar_bus` field to Server struct
- Init bus with unix socket path in Server.init
- Call `Handlers.set_sidecar(&client, &bus)` during init
- Wire bus callbacks to `sidecar_on_frame` / `sidecar_on_close`
- Flip `sidecar_enabled = true` behind `-Dsidecar` build flag

**Cleanup:**
- `npm run dev` — start sidecar + server, verify HTTP requests work
- Delete `protocol.read_frame`, `protocol.write_frame`,
  `protocol.recv_exact`, `protocol.send_exact` (dead code)
- Remove `io.readable()` from IO if no other consumers
- Re-enable sidecar fuzzer (rewrite for SidecarClientType + FuzzIO)
  OR defer to Phase 3

### QUERY sub-protocol flow

```
Connection delivers QUERY frame via on_frame_fn(context, frame)
  → consumer: parse SQL, execute via query_dispatch_fn
  → consumer: build QUERY_RESULT in pool message (zero-copy)
  → bus.send_message(QUERY_RESULT)
  → Connection delivers next frame when available
```

QUERY_RESULT is built directly into a pool message buffer and
sent via `bus.send_message`. No suspend/resume needed — the
QUERY callback executes synchronously and the send queue holds
the response. The sidecar won't send the next frame until it
receives the QUERY_RESULT.

### Checklist

**Step 1 — DONE:**
- [x] `sidecar_handlers.zig` — SidecarHandlersType(StorageParam, IO)
- [x] `app.zig` — `sidecar_enabled`, `HandlersFor`, `StateMachineWith`
- [x] `framework/server.zig` — Handlers alias, .pending in route/render,
  sidecar_on_frame/on_close, timeout during .pending
- [x] `protocol.zig` — write_call_header
- [x] `main.zig` — HandlersFor + StateMachineWith
- [x] All unit tests, sim tests, fuzz smoke pass

**Step 2 — DONE:**
- [x] TS sidecar: 8-byte CRC frame header (sendFrame/processFrames)
- [x] TS sidecar: CRC-32 via Node.js `zlib.crc32`
- [x] `call_submit`: accepts request_id, validated in on_frame
- [x] Wire next_request_id through SidecarHandlersType

**Step 3 — DONE:**
- [x] Bus/Client embedded in Server (TB pattern)
- [x] Build flag: `-Dsidecar=true`
- [x] READY handshake on connect (version + PID)
- [x] Binary sidecar state (503 while disconnected)
- [x] Render crash fallback (200 degraded, no retry)
- [x] Kill on protocol violation (SIGKILL)
- [x] Response timeout (5s deadline)
- [x] Sidecar fuzzer rewrite (Phase 3)

**End-to-end verified manually (npm run dev):**
- [x] `tiger-web build` — annotation scan + codegen
- [x] `tiger-web dev` — server + sidecar start, READY handshake
- [x] GET /products → HTML rendered by TS sidecar
- [x] POST /products → product created, listed on next GET
- [x] Kill sidecar → 503 "service unavailable"
- [x] Restart sidecar → READY handshake → GET returns 200

**Remaining cleanup (not blocking):**
- [ ] Delete protocol.read_frame/write_frame (blocked by old test)
- [ ] Delete io.readable() (no callers)
- [ ] Automated e2e test script (currently manual curl commands)

## Phase 3: Fuzzers — DONE

Three files, two layers, shared IO:

- **`fuzz_io.zig`** — shared socket simulator. Bidirectional
  pairs, partial delivery, error injection. IO simulates sockets,
  fuzzers drive timing via do_recv/do_send.
- **`message_bus_fuzz.zig`** — transport layer. ConnectionType(FuzzIO).
  Frame accumulation, CRC, partial send/recv, backpressure,
  re-entrancy (send_frame + terminate from on_frame), delivery
  verification, error-free post-loop drain.
- **`sidecar_fuzz.zig`** — protocol layer. SidecarClientType(FuzzIO)
  through real ConnectionType. CALL/RESULT, QUERY sub-protocol,
  corrupt/truncated/wrong-tag frames, request_id mismatch,
  unsolicited frames, multi-call sequencing.

**Bugs found by fuzzers:**
- call_submit assert on full send queue (server crash)
- Null query_fn causing all QUERY events to fail

**Deterministic unit tests (message_bus.zig):**
- send_frame from on_frame (re-entrancy)
- terminate from on_frame (try_drain_recv stops)

Previously `sidecar_fuzz.zig` used socketpair + threads. Replaced with
  current socketpair + thread approach with bus + FuzzIO.

TB's principle: fuzz through the real code paths. The protocol
fuzzer must use the bus, not call `on_frame` directly. Calling
`on_frame` directly bypasses `try_drain_recv` re-entrancy
context, `recv_submitted` state, and `maybe(state == .terminating)`
checks. Bugs at the integration boundary would be invisible.

### message_bus_fuzz.zig — transport isolation (DONE)

FuzzIO embedded in `message_bus_fuzz.zig` (TB pattern). Exercises
`ConnectionType(FuzzIO)` — one connection per seed, no reconnects.

**FuzzIO design (implemented):**
- Synchronous tick (no priority queue — sufficient for serial pipeline)
- Bidirectional socket pairs with static send buffers (64KB)
- Random recv/send ordering per tick
- Recv leaves completion pending when no data (no spurious -1)
- Send leaves completion pending when buffer full (no 0-byte)
- inject_data returns false when buffer full (no silent truncation)
- fd recycling with aliasing assertion

**Fault injection (swarm-tested per seed):**
- recv_partial_probability (20-80%)
- send_partial_probability (20-80%)
- send_now_success_probability (30-90%)
- recv_error_probability (0-20%)
- send_error_probability (0-10%)
- Event weights via random_enum_weights (TB swarm pattern)
- Destructive event weights capped to avoid early termination

**What's tested:**
- [x] Frame accumulation (random chunk sizes via partial recv)
- [x] CRC validation (corrupt frames → terminate)
- [x] Oversized frame rejection
- [x] Partial sends + send_now fast path
- [x] Send queue with send_frame + send_message (zero-copy)
- [x] Backpressure (suspend_recv / resume_recv)
- [x] Terminate initiated by consumer
- [x] Disconnect (peer close → EOF)
- [x] Send error injection (EPIPE/ECONNRESET equivalent)
- [x] Re-entrancy: send_frame from on_frame (QUERY pattern)
- [x] Re-entrancy: terminate from on_frame (try_drain_recv stops)
- [x] Delivery verification (checksums in order, panic on mismatch)
- [x] Error-free post-loop drain (hard assertion if alive + missing)

**Deterministic re-entrancy tests (message_bus.zig unit tests):**
- [x] send_frame from on_frame — reply frame delivered
- [x] terminate from on_frame — second frame not delivered

**Not tested (deferred or out of scope):**
- [ ] Priority-queue scheduling (timing-dependent interleavings)
- [ ] Accept failure (MessageBus lifecycle, not Connection)
- [ ] Send corruption in transit (needs receiver-side Connection)
- [ ] Buffer-full slow-fill (only oversized header tested)
- [ ] Reconnection after termination (sidecar fuzzer's job)
- [ ] End-to-end delivery tracking (checksum-keyed).
- [ ] `bus.invariants()` checked every tick.
- [ ] Register in `fuzz_tests.zig` dispatcher.

### sidecar_fuzz.zig — protocol integration

Update the existing `sidecar_fuzz.zig` to use the bus instead
of raw socketpairs with threads. The fuzzer exercises the
CALL/RESULT protocol through the real Connection transport
with FuzzIO fault injection.

**Current approach (replaced):**
- `test_socketpair()` creates unix socket pair
- Thread writes test frames to one end
- `SidecarClient.on_recv()` reads from the other end
- Tests protocol state machine (idle → receiving → complete)

**New approach:**
- Create `ConnectionType(FuzzIO, .{ .send_queue_max = 2 })`
- FuzzIO injects CALL frames with PRNG-driven partial delivery
- `SidecarClient.on_frame` receives frames through real
  `try_drain_recv` → `on_frame_fn` path
- QUERY sub-protocol exercises real `suspend_recv` → `send_frame`
  → `resume_recv` re-entrancy
- Disconnect and error injection via FuzzIO fault ratios
- Protocol content validation (valid/corrupt/truncated RESULT,
  query limit exceeded) unchanged — same assertions, different
  transport

**What this catches that the old approach doesn't:**
- **Recv buffer compaction bugs:** After `on_frame` returns, the
  Connection compacts the recv buffer. Any slice stored by the
  consumer that aliases `frame` (a slice into recv_message.buffer)
  becomes invalid. The old blocking `read_frame` didn't compact
  until the next read, hiding this class of bugs. With FuzzIO
  injecting partial frames after RESULT, compaction triggers every
  time. Without `copy_state` in `on_frame`, `result_data` would
  point into compacted memory. **This bug was found during Phase 2
  implementation.** The fuzzer must exercise this path.
- Re-entrancy bugs: `send_frame` called from `on_frame_fn`
  inside `try_drain_recv` — state machine transitions that only
  happen in the real callback context
- Transport + protocol interaction: partial frame delivery
  mid-QUERY exchange, disconnect between QUERY and QUERY_RESULT
- CRC validation: corrupted frames rejected by Connection before
  reaching protocol layer

### sidecar_fuzz checklist

**Scope: protocol state machine only.** No server, no reconnect.
Recovery testing requires the full stack — deferred to sim.zig.

- [ ] Replace socketpair + thread with ConnectionType(FuzzIO).
- [ ] SidecarClient receives frames via bus on_frame callback.
- [ ] Valid CALL/RESULT exchange (call_submit → inject RESULT).
- [ ] QUERY sub-protocol via real send path (bus.send_message).
- [ ] Corrupt/truncated/wrong-tag RESULT → .failed.
- [ ] Request_id mismatch detection → .failed.
- [ ] Query count exceeded → .failed.
- [ ] Recovery after failure (reset_call_state → new CALL).
- [ ] Suspend/resume during QUERY — frame delivered after resume,
  stale-slice-after-compaction tested.
- [ ] Multi-call sequencing — multiple exchanges on same client,
  stale RESULT from call N injected during call N+1.
- [ ] copy_state overflow — QUERY results approaching state_buf_max.
- [ ] Compaction after RESULT: trailing bytes after RESULT frame,
  result_data in state_buf survives recv buffer compaction.
- [ ] Register updated fuzzer in `fuzz_tests.zig`.

**Hardening scenarios (from TB audit, bugs found in code review):**
- [ ] Unsolicited frame — inject frame when call_state != .receiving.
  Must set protocol_violation, not crash the server.
- [ ] Send queue overflow — burst QUERYs exceeding send_queue_max.
  Must set protocol_violation, not assert-crash.
- [ ] Compaction preserves advance_pos — suspend_recv during
  try_drain_recv, inject more data, resume. Validated-but-
  undelivered frames must be delivered after resume, not lost.
- [ ] state_buf capacity — inject large RESULT + QUERY results
  that approach state_buf_max. copy_state assert must fire on
  overflow, not silently corrupt.

### Recovery testing — sim.zig (separate concern)

Recovery requires Server + SM + MessageBus — wrong level for
the sidecar fuzzer. Connection terminates on error and never
reconnects. Recovery is a lifecycle concern, not a protocol concern.

| Layer | Behavior | Tested by |
|---|---|---|
| Connection | Terminates on error | message_bus_fuzz |
| MessageBus | tick_accept re-accepts | sim.zig (future) |
| call_submit | Returns false when disconnected | sidecar_fuzz |
| Server pipeline | Retries next tick if .busy | sim.zig (future) |
| HTTP connection | Survives until 30s timeout | sim.zig (future) |

Sim scenarios to add (Phase 4 / SimSidecar):
- [ ] Disconnect mid-CALL → pipeline .busy → reconnect → resume
- [ ] Multiple disconnect/reconnect within one HTTP request
- [ ] HTTP timeout while sidecar down → error response
- [ ] Sidecar reconnect after timeout → next request succeeds

### After Phase 3: delete TestIO from message_bus.zig

The Phase 1 unit tests use a `TestIO` shim — a third IO
implementation alongside `IO` and `SimIO` that requires manual
`tick()` calls. This tests a code path that doesn't exist in
production. TB doesn't do this — they test through real IO or
their synthetic FuzzIO, never a throwaway stub.

Once FuzzIO exists (Phase 3), migrate the unit tests to use
either:
- **Real IO** with socketpairs and `io.run_for_ns(0)` — tests
  the actual epoll path. The real code path.
- **FuzzIO** — tests with fault injection. The fuzzer IS the
  test suite.

Then delete `TestIO` and `TestContext` from `message_bus.zig`.
Two IO implementations (production + simulation), not three.

## Phase 3.5: Connection CloseReason — DONE

> Investigated "report, don't decide" (consumer chooses whether
> to terminate). Rejected: CRC errors can't be skipped (no sync
> markers), recv/send errors mean broken socket, half-duplex
> requires new states. Terminate-on-error is correct for framed
> byte streams. Recovery happens above (MessageBus, server).
>
> Implemented: CloseReason on terminate + on_close_fn. Consumer
> knows WHY the connection closed (eof, recv_error, send_error,
> crc_error, oversized, buffer_full, shutdown) for logging,
> metrics, and kill decisions.

### The problem

The Connection terminates on every error: CRC mismatch, recv
returning -1, send returning 0, oversized frame. TB does this
because TB has consensus — losing one connection is a non-event.
A web server needs availability — every terminated connection
is a failed request.

The sidecar protocol is stateless per-request. Each CALL/RESULT
is independent. A corrupt RESULT doesn't corrupt the next one.
TCP guarantees ordering — a CRC mismatch is a one-off, not a
stream desync. Terminating the entire connection is too aggressive.

### The fix: Connection reports, consumer decides

Replace `on_frame_fn: fn(*anyopaque, []const u8)` with
`on_event_fn: fn(*anyopaque, Event)`:

```zig
const Event = union(enum) {
    frame: []const u8,   // valid CRC-checked frame payload
    crc_error,           // frame failed CRC — data available but corrupt
    oversized: u32,      // frame claims size > frame_max
    eof,                 // peer closed (recv returned 0)
    recv_error,          // recv returned -1
    send_error,          // send returned -1 or 0
};
```

The Connection never calls `terminate`. The consumer switches on
the event and decides:

- `frame` → process it (current behavior)
- `crc_error` → sidecar: set protocol_violation, kill. HTTP: drop, continue
- `oversized` → terminate (malicious peer)
- `eof` → terminate (peer gone)
- `recv_error` → sidecar: retry or kill. HTTP: close connection
- `send_error` → terminate (can't send response)

### What this fixes

**Root cause 1 (fragile transport):** The fuzzer can sustain long
exchanges because one CRC error doesn't kill the connection. The
consumer drops the bad frame and continues. No weight caps, no
error-free drain.

**Root cause 3 (assert at trust boundary):** The Connection never
asserts on external input. It reports. The consumer (which knows
the trust model) decides. Unsolicited frames, send queue overflow,
CRC mismatches — all reported as events, not assert-crashes.

### Terminate call sites to convert (6 total)

From `message_bus.zig` ConnectionType:

1. `recv_callback` result < 0 → `Event.recv_error`
2. `recv_callback` result == 0 → `Event.eof`
3. `recv_callback` buffer full + incomplete → `Event.oversized` (keep terminate — malicious)
4. `advance()` len > frame_max → `Event.oversized`
5. `advance()` CRC mismatch → `Event.crc_error`
6. `send_callback` result <= 0 → `Event.send_error`

Site 3 is the only one that should still terminate internally
(buffer full with incomplete frame = peer filling buffer without
completing a frame = malicious). All others → report to consumer.

### Connection state after event

The Connection stays `.connected` after reporting an event.
The consumer calls `terminate()` if it wants to close. This
means the Connection must handle: event reported → consumer
does NOT terminate → recv/send loop continues.

For `recv_error` and `send_error`: the Connection should NOT
re-submit the failed operation. The consumer decides whether
to retry or terminate. The Connection stays in a "paused"
state until the consumer either calls `terminate()` or resumes.

For `crc_error`: the Connection advances past the bad frame
(skips the bytes) and continues `advance()`. The next valid
frame is delivered normally.

For `eof`: the consumer almost always terminates. But the
Connection doesn't assume this — it reports and waits.

### Implementation steps

1. Add `Event` union to ConnectionType (new type).
2. Change `on_frame_fn` to `on_event_fn` on Connection fields.
3. Convert `recv_callback` sites 1-2 to report events.
4. Convert `advance()` sites 4-5 to report events.
5. Convert `send_callback` site 6 to report event.
6. Keep site 3 (buffer full) as internal terminate.
7. Update server.zig HTTP connection consumer — terminate on
   all events (preserves current behavior for HTTP clients).
8. Update server.zig sidecar_on_frame — handle events:
   - `frame` → process (current behavior)
   - `crc_error` → protocol_violation, kill
   - `eof` → sidecar_on_close (current behavior)
   - `recv_error` → kill sidecar
   - `send_error` → kill sidecar
   - `oversized` → kill sidecar
9. Update message_bus_fuzz.zig — FuzzContext handles events.
10. Update sidecar_fuzz.zig — SidecarFuzzCtx handles events.
11. Update deterministic unit tests.
12. Update FuzzIO tick helpers (no change — they fire callbacks
    with i32 results, Connection converts to events).

### Files affected

| File | Change |
|---|---|
| framework/message_bus.zig | Event union, on_event_fn, convert 6 terminate sites |
| framework/server.zig | HTTP consumer (terminate on all), sidecar consumer (per-event) |
| message_bus_fuzz.zig | FuzzContext.on_event handles Event union |
| sidecar_fuzz.zig | SidecarFuzzCtx.on_event handles Event union |
| sidecar_handlers.zig | process_sidecar_frame receives Event, not raw frame |
| fuzz_io.zig | No change (fires i32 results, Connection wraps) |

### Verification

```bash
./zig/zig build unit-test    # connection tests + re-entrancy tests
./zig/zig build test         # sim tests (HTTP connections — all terminate)
./zig/zig build fuzz -- smoke # both fuzzers with Event handling
./zig/zig build -Dsidecar=true # sidecar mode compiles
```

### What this doesn't fix

**Root cause 2 (implicit callback wiring):** See Phase 3.5b below.
**Root cause 4 (process lifecycle):** See section below.

## Sidecar process lifecycle (root cause 4)

> **Deferred** until second adapter (Python/Go). See also:
> `docs/internal/decision-sidecar-lifecycle.md`.

### The problem

The server knows the sidecar's PID (from READY handshake) but
doesn't control how the process was spawned. `kill(pid, SIGKILL)`
may kill a wrapper (npx, poetry) while the actual process holding
the socket survives as an orphan.

### Current state

- READY frame carries `[version: u16 BE][pid: u32 BE]`
- Server calls `kill(pid, SIGKILL)` on protocol violations
- E2e test spawns node directly (no wrapper) to avoid the issue
- The hypervisor (systemd, docker) should ensure PID accuracy

### Future fix: flags byte in READY

```
[tag: 0x20][version: u16 BE][pid: u32 BE][flags: u8]
```

- bit 0: `kill_group` — use `kill(-pid)` (process group kill)
- bit 1-7: reserved

The adapter sets flags based on its runtime. The server reads
them. Each language adapter declares its own kill semantics.

### Alternative: server spawns sidecar

If the server spawns the sidecar itself (not the hypervisor),
it can `setsid()` to create a new process group. Then
`kill(-pid, SIGKILL)` always works. But this means the server
owns process management — more complexity, less separation.

## Phase 3.5b: Typed consumer — REJECTED

> Investigated adding comptime Consumer type parameter to
> ConnectionType. Rejected: causes comptime cascade explosion.
> SidecarClientType needs Consumer, SidecarHandlersType needs
> Consumer, HandlersFor needs Consumer, Server IS the Consumer
> → circular dependency.
>
> TB avoids this: MessageBus takes a typed callback FUNCTION,
> not a typed Consumer STRUCT. The function pointer breaks the
> circular dependency. The callback uses @fieldParentPtr to
> recover the consumer from the embedded Connection.
>
> Current *anyopaque + function pointers work. Misconfigurations
> are caught by fuzzers at runtime (zero frames delivered =
> obvious). Only two consumers (server + fuzzers). Not worth
> the comptime cascade.

### The problem

The callback chain is `bus.on_frame_fn → server.sidecar_on_frame →
client.on_frame`. Wired at runtime with `*anyopaque` and function
pointers. If you wire it wrong (null callback, wrong context, wrong
function), the compiler doesn't catch it — silent frame drops or
crash at runtime. The sidecar fuzzer hit this twice (dummy_on_frame,
null query_fn).

### The fix: comptime consumer parameter

```zig
pub fn ConnectionType(
    comptime IO: type,
    comptime Consumer: type,  // must have on_frame, on_close
    comptime options: Options,
) type
```

The Connection stores `consumer: *Consumer` (typed pointer, not
anyopaque). Calls `self.consumer.on_frame(frame)` directly. No
function pointers. No casting. Missing `on_frame` → compile error.

### Trade-off

Changes the ConnectionType signature — every consumer (server HTTP,
sidecar bus, fuzzers) becomes a comptime parameter. Larger refactor.
Only two consumers today (HTTP server + sidecar bus). The
`validateHandlersInterface` comptime check pattern could be applied
as a lighter alternative.

### Pragmatic interim

Add `assert(on_frame_fn != undefined)` in Connection.init. Catches
null/undefined wiring at init time, not at frame delivery time.
Not as good as comptime, but prevents the silent-drop class.

### Implementation scope

- Change `on_frame_fn` to `on_event_fn` on ConnectionType
- Update `advance()` to report crc_error instead of terminate
- Update `recv_callback` to report eof/recv_error
- Update `send_callback` to report send_error
- Update all consumers: server HTTP connections, sidecar bus
- Update FuzzIO tick helpers
- Update fuzzers and unit tests

This is a significant refactor — every consumer changes. But it's
the right primitive for a web server with external sidecar.

## Phase 4: SimSidecar

Simulation primitive for sim tests. Exercises the full sidecar
pipeline through the real Server + SM + MessageBus stack with
PRNG-driven fault injection. Tests recovery scenarios that the
protocol fuzzer can't (disconnect → 503 → reconnect → 200).

### Key insight: sidecar is just a client slot

SimIO already has `clients: [8]SimClient` with bidirectional
buffers, partial delivery, fault injection, disconnect/reconnect.
The sidecar bus uses the SAME SimIO instance. The sidecar
connection IS a client from SimIO's perspective.

**No SimIO modifications needed.** Reserve one client slot
(index 0) for the sidecar. SimSidecar uses the existing API:
- `connect_client(0)` → sidecar connects to unix socket
- `inject_bytes(0, READY_frame)` → READY handshake
- `inject_bytes(0, RESULT_frame)` → deliver RESULT
- `read_response(0)` → read CALL frames sent by server
- `disconnect_client(0)` → simulate sidecar crash
- `connect_client(0)` again → simulate restart

The bus's `tick_accept` finds the connected-but-unaccepted
client, accepts it, creates a Connection on that fd. All
existing SimIO mechanisms apply: partial delivery via PRNG,
recv/send faults, disconnect detection.

### SimSidecar struct

```zig
const SimSidecar = struct {
    prng: *PRNG,
    io: *SimIO,
    sidecar_slot: usize,          // client index (0)

    // Frame accumulation — partial delivery means CALLs
    // may arrive in chunks across multiple ticks.
    recv_buf: [frame_max + 8]u8,
    recv_len: u32,

    // Pending response state.
    response_buf: [frame_max + 8]u8,
    response_len: u32,
    response_delay: u32,          // ticks remaining before delivery

    // PRNG-driven fault injection (swarm-tested per seed).
    disconnect_probability: Ratio,
    response_delay_max: u32,      // 0..N ticks

    pub fn tick(self: *SimSidecar) void;
    pub fn connect(self: *SimSidecar) void;
    pub fn disconnect(self: *SimSidecar) void;
    fn try_read_frame(self: *SimSidecar) ?[]const u8;
    fn process_call(self: *SimSidecar, frame: []const u8) void;
    fn build_result(self: *SimSidecar, name: []const u8, request_id: u32) void;
};
```

SimSidecar accumulates bytes from SimIO's client recv_buf
(server's sends land there). When a complete CRC-framed CALL
arrives, process_call parses it and builds a RESULT using
protocol.zig primitives (pair assertion with decoder).

Hardcoded responses per operation — not real TS execution.
Tests the framework pipeline, not handler logic. V8 is
non-deterministic; sim tests must be fully deterministic.

### How it works

```
1. SimSidecar.connect():
   io.connect_client(0) → bus.tick_accept accepts fd
   → SimSidecar injects READY frame via io.inject_bytes(0, ...)
   → Server tick → bus recv → sidecar_on_frame → handshake complete

2. Test injects HTTP request:
   io.inject_post(1, "/products", body) → server tick
   → commit_dispatch → .route → handler_route → call_submit
   → bus.send_message → io.send(sidecar_fd, CALL frame)
   → SimIO captures to client[0].recv_buf

3. SimSidecar.tick():
   try_read_frame() — accumulate bytes from io.read_response(0)
   → When complete frame: process_call(frame)
   → Parse CALL name, build RESULT using protocol.zig
   → Set response_delay from PRNG

4. SimSidecar.tick() (subsequent):
   Countdown response_delay
   → When 0: io.inject_bytes(0, RESULT frame)
   → SimIO delivers on next recv for sidecar fd
   → bus recv_callback → sidecar_on_frame → pipeline resumes

5. Test reads HTTP response:
   io.read_response(1) → verify 200 + HTML
```

SimSidecar.tick() is called by the test between server ticks.
The test drives: server.tick() → sim_sidecar.tick() → io.run_for_ns().
Deterministic — same seed, same delays, same faults.

### READY handshake in sim

After bus.tick_accept accepts the sidecar connection, SimSidecar
injects a READY frame into sidecar_recv_buf. The server's
sidecar_on_frame parses it, sets sidecar_connected = true.
This exercises the real handshake path.

### QUERY sub-protocol

When SimSidecar receives a CALL that triggers queries (prefetch,
render), it processes them synchronously — no delay. The QUERY
frames go through the same sidecar_send_buf/recv_buf path.
SimSidecar builds QUERY frames, SimIO delivers them to the
server's bus recv, the server sends QUERY_RESULT, SimIO captures
it, SimSidecar reads the result and continues building the
RESULT frame.

### Recovery scenarios (from fault model doc)

These are the scenarios the protocol fuzzer can't test because
they need the full server stack:

- [ ] Disconnect mid-CALL → pipeline .busy → HTTP 503
- [ ] Reconnect after disconnect → READY handshake → next
  request succeeds (200)
- [ ] Disconnect during .render → render_crash_fallback
  (200 with degraded HTML, no duplicate writes)
- [ ] Response timeout (5s) → terminate connection → 503
- [ ] Sidecar down at startup → all requests get 503
  until READY handshake completes

**Additional scenarios (from TB audit):**
- [ ] Partial CALL frame delivery — SimSidecar accumulates
  bytes across multiple ticks before processing
- [ ] Protocol violation — SimSidecar injects malformed RESULT
  (wrong request_id, bad CRC) → server terminates connection, recovers
- [ ] Multiple HTTP requests during disconnect — all get 503
- [ ] Connect then disconnect before READY — server stays
  sidecar_connected = false, returns 503
- [ ] READY with wrong version → server rejects, terminates connection

### Fault injection

PRNG-driven, swarm-tested per seed:

- **Response delay:** 0..N ticks before RESULT. Tests pipeline
  staying in .pending across multiple ticks.
- **Disconnect:** PRNG chance per CALL to close the sidecar fd.
  Tests full recovery: on_close → pipeline_reset → 503 →
  reconnect → READY → 200.
- **Partial delivery:** SimIO already does this — same PRNG-
  driven partial recv/send applies to the sidecar fd.

No content corruption — SimSidecar produces valid RESULT frames.
Faults affect whether and when frames arrive.

### Compilation: sidecar_enabled in test binary

Test binaries don't have build_options → sidecar_enabled
defaults to false. Sidecar sim tests need it true.

**Solution:** Add a build step in build.zig that compiles
sim_sidecar.zig with `-Dsidecar=true` via build_options.
Same pattern as the main exe. The test binary gets its own
build_options module with sidecar_enabled = true.

sim_sidecar.zig exports `pub const build_options = .{
    .sidecar_enabled = true,
};` so app.zig reads it from root.

### Implementation steps

1. **build.zig: sidecar sim test step** — new test binary
   `sim_sidecar.zig` compiled with sidecar_enabled = true.
   Links sqlite3 + libc. Separate from existing `test` step.

2. **SimSidecar struct** — in sim_sidecar.zig. Frame
   accumulation (partial delivery), CALL parsing, RESULT
   building using protocol.zig primitives, PRNG delay,
   READY frame injection. Hardcoded responses per operation.

3. **SimSidecar.connect/disconnect** — uses existing SimIO
   connect_client/disconnect_client. No SimIO modifications.
   Reserve client slot 0 for sidecar.

4. **Basic sim test** — connect sidecar, inject HTTP request,
   SimSidecar processes CALL + injects RESULT, verify HTTP
   response. Full pipeline: route → prefetch → handle → render.

5. **Recovery sim tests** — 10 scenarios from the checklist.
   Each is a test function: setup → fault → verify.

6. **QUERY sub-protocol** — SimSidecar receives QUERY from
   server (via client slot recv_buf), builds QUERY_RESULT,
   injects back via inject_bytes. Synchronous — no delay.

### Disconnect/reconnect sequence (critical path)

```
1. SimSidecar is connected (slot 0, fd assigned, READY done)
2. HTTP request in-flight (CALL sent to sidecar)
3. sim_sidecar.disconnect() → io.disconnect_client(0)
4. Server tick → io.run_for_ns → bus recv returns -1
   → bus Connection terminate → on_close fires
   → server.sidecar_connected = false
5. Next HTTP request → .route → sidecar not connected → 503
6. sim_sidecar.connect() → io.connect_client(0) (new fd)
7. Server tick → bus.tick_accept → accepts new fd
8. sim_sidecar injects READY → server.sidecar_on_frame
   → handshake validates → sidecar_connected = true
9. Next HTTP request → routes to sidecar → 200
```

### Files affected

| File | Change |
|---|---|
| sim_sidecar.zig | NEW — SimSidecar + sidecar sim tests |
| build.zig | New test-sidecar step with sidecar_enabled = true |
| sim.zig | NO CHANGES — existing sim tests untouched |

### Verification

```bash
./zig/zig build unit-test     # existing tests unchanged
./zig/zig build test          # existing sim tests unchanged
./zig/zig build test-sidecar  # new sidecar sim tests
./zig/zig build fuzz -- smoke # fuzzers unchanged
```

## Dependencies

```
Phase 0:   MessagePool + Connection (*Message pointers) ✓ DONE
Phase 1:   Connection + MessageBus (transport primitive) ✓ DONE
Phase 1.5: Consolidated pipeline
           - Route as pipeline stage (no shim)
           - All stages async-capable
           - Comptime handler selection
           - Delete sidecar_* stages from server
    ↓
Phase 2:   Sidecar handlers (SidecarHandlersType + TS wire format)
    ↓
Phase 3:   MessageBus Fuzzer (can start during Phase 2)
    ↓
Phase 4:   SimSidecar
```

### Phase 4.5: Supervisor integration test — DEFERRED

Deferred because the cost exceeds the value at this stage:

**What it would test:** READY handshake over a real unix socket
with a real spawned process. The only path not covered by sim
tests or supervisor unit tests.

**Why we don't need it now:**
- Sim tests (sim_sidecar.zig, 10 tests) cover every connection
  lifecycle path: disconnect → 503 → reconnect → 200, render
  crash fallback, timeout, protocol violation.
- Supervisor unit tests (supervisor.zig, 16 tests) cover every
  state machine path: backoff, grace period, restart.
- The real socket path is exercised by developers on every
  `npm run dev` session. If READY fails, they see it immediately.
- The untested code is three posix wrappers (spawn, waitpid,
  kill) — trivial one-liners.

**Why it's costly:**
- Real processes introduce non-determinism — the thing TB's
  architecture is designed to avoid.
- Build dependency ordering (test needs a built binary).
- Process cleanup on test failure (defer kill).
- CI compatibility (some environments restrict fork/exec).
- Flaky failures at 3am: "is it my code or the OS?"
- Sim tests: <1s, deterministic, never flake.
  Integration test: 2-3s, non-deterministic, will flake.

**When to build it:** When a production bug proves the sim
missed something, or when CI confidence for the real socket
path becomes a shipping requirement.

Phase 1.5 is the architectural pivot. The SM pipeline becomes
the single protocol: route → prefetch → handle → render. All
four stages async-capable. Handler implementation pluggable at
comptime. Server has one commit_dispatch with one set of stages.

Phase 2 implements `SidecarHandlersType` — same interface as
native handlers, uses sidecar protocol internally. The server
doesn't change. Only the handler implementation.

After Phase 2, the shared memory transport (`sidecar-shm-transport.md`)
becomes actionable — swap the IO layer under the bus. Each phase
enables the next:

```
Phase 1.5 → pipeline supports .pending on all stages
    ↓
Phase 2   → handlers use the bus, return .pending
    ↓
shm transport → swap IO layer (mmap + futex), same bus/handlers
    ↓
multi-process → N sidecar processes, concurrent pipeline
```

The shared memory transport can't come before the pipeline because
handlers need to be async-capable (return `.pending`, resume via
callback) before there's a bus to swap the IO layer under.

Future protocols add edges (decode/encode), not core paths.
Workers are just async handlers — no new pipeline stages.

## TB audit result

Reviewed against TB's six principles. Final revision.

| Principle | Result | Notes |
|---|---|---|
| Safety | PASS | 3-phase termination, frame checksums, buffer-full guard, state checks after every callback, bounds proofs |
| Determinism | PASS | All state in struct, `send_now` through IO layer, FuzzIO with priority-queue scheduling |
| Boundedness | PASS | Static buffers, comptime-known sizes, `send_queue_max` asserted, `SO_SNDBUF` sized to queue depth |
| Fuzzable | PASS | Connection fuzzed in isolation, 12 scenarios, swarm testing, invariants every tick |
| Right Primitive | PASS | Connection (transport) separated from MessageBus (lifecycle), comptime parameterization, CRC-32 for transport integrity |
| Explicit | PASS | State enum, `maybe()`, comptime bounds per consumer, IO interface contract, implementation constraints numbered |

**Accepted trade-offs:**
- `advance()` re-reads the length prefix on partial-frame resume
  instead of caching it (TB caches via `advance_header`/`advance_body`).
  Simpler code, one extra u32 read on rare partial recv. The hot
  path is syscall overhead, not a 4-byte L1 cache read. `send_now`
  does more for throughput than validation caching could.
- Frame data valid only during callback (copy-on-receive via
  `copy_state`) instead of ref-counted message pool. Correct for
  our single-connection, static-buffer model. Documented contract.
- `send_queue.full()` is an assert, not a graceful drop. TB logs
  and drops. We assert because the consumer's `send_queue_max` is
  a compile-time bound that the consumer chose — exceeding it is
  a programming error, not a runtime condition.

## Implementation constraints (from TB audit)

These are specific correctness constraints discovered during
the design review. Each must be addressed during implementation
— not deferred, not optional.

### 1. `advance()` must bounds-check before accessing payload

The `advance()` pseudocode validates `len <= frame_max`, then
accesses `recv_buf[process_pos + 8 .. process_pos + 8 + len]`.
If `process_pos + 8 + len > recv_buf_max`, this is out of
bounds. The `len <= frame_max` check should catch this because
`recv_buf_max == frame_max + frame_header_size`, but this
relies on an implicit relationship.

**Direction:** Add a comptime assertion:
```zig
comptime { assert(recv_buf_max == options.frame_max + frame_header_size); }
```
And a runtime assertion before payload access:
```zig
assert(process_pos + frame_header_size + len <= recv_buf_max);
```
Belt and suspenders. The comptime assertion proves the runtime
one can never fail. The runtime one catches implementation bugs
where the comptime proof doesn't hold (e.g., process_pos is
wrong).

### 2. `send_now()` must go through `self.io`, not `posix.send`

The pseudocode shows `posix.send(fd, ..., MSG.DONTWAIT)`. This
is a direct syscall — SimIO can't intercept it. In simulation,
the Connection would bypass the synthetic IO and hit a real
(non-existent) fd.

**Direction:** `send_now()` calls `self.io.send_now(fd, buf)`
which returns `?usize`. The IO interface gains a `send_now`
method:
- Real IO: calls `posix.send` with `MSG.DONTWAIT | MSG.NOSIGNAL`
- SimIO: PRNG-driven partial/null return
- FuzzIO: configurable `send_now_probability`

This matches TB: `bus.io.send_now(connection.fd, ...)` in
`message_bus.zig` line 905.

### 3. Recv buffer full with incomplete frame

If the peer sends a length prefix claiming `frame_max` bytes
then stops (crash, malicious), the recv buffer fills to
`recv_buf_max` with no complete frame. `recv_slice()` would
return a zero-length slice. `io.recv` with a zero-length
buffer is undefined behavior on most platforms.

**Direction:** After `recv_callback` advances `recv_pos`, check:
```zig
if (recv_pos == recv_buf_max and advance_pos < recv_pos) {
    // Buffer full, frame incomplete. Peer is stuck or malicious.
    terminate(.shutdown);
    return;
}
```
This is an assertion about boundedness: the buffer can hold
exactly one maximum-size frame. If the buffer is full and the
frame isn't complete, something is wrong. Don't wait for the
idle timeout — terminate immediately.

The idle timeout remains as a second line of defense for the
case where the peer sends slowly (one byte per second, never
filling the buffer but never completing the frame).

### 4. `on_frame_fn` callback context

The pseudocode has `on_frame_fn: *const fn (*Self, []const u8)`.
The consumer receives a `*Connection`. To reach the MessageBus
or SidecarClient, it must use `@fieldParentPtr` — which
requires knowing the parent struct's field name. This is
implicit coupling.

**Direction:** Add an explicit context pointer, matching TB's
pattern. TB passes `*MessageBus` directly to its callback.
We pass a `*anyopaque` context set during `init()`:

```zig
on_frame_fn: *const fn (context: *anyopaque, frame: []const u8) void,
context: *anyopaque,
```

The consumer sets context during `connection.init()` to point
at whatever it needs (SidecarClient, WorkerClient, etc.). The
Connection doesn't know or care what the context is. No
`@fieldParentPtr` needed.

This is the right primitive: the Connection is a transport
layer, it shouldn't encode knowledge of its container's layout.

### 5. Checksum algorithm choice

The plan says "CRC-32 of the payload (or Aegis128L if we want
to match `framework/checksum.zig`)". This is an unresolved
decision.

**Direction:** Use CRC-32. Reasons:
- Aegis128L is a MAC (keyed), not a checksum. Using it without
  a key (zero-key) is functionally a checksum but semantically
  wrong for transport-level integrity. We're not authenticating
  the peer, just detecting corruption.
- CRC-32 is the standard for transport integrity (Ethernet,
  SCTP, iSCSI). It's what the use case calls for.
- CRC-32 is faster for small payloads (no AES-NI setup).
- `std.hash.crc.Crc32` is in the standard library. No
  dependency on our framework.
- TB uses its own checksum (Aegis128L) because it's also
  verifying message authenticity in a distributed system. We're
  on a local unix socket — corruption detection is sufficient.

### 6. CRC must cover the length prefix, not just the payload

The frame format is `[len][crc32][payload]`. If CRC covers only
the payload, a corrupted length is undetected. A bit flip in
the length field could cause:
- Larger than actual: buffer-full guard catches it eventually.
- Smaller than actual: CRC of truncated payload. Almost always
  a mismatch. But CRC-32 collision probability is 1/2^32 — over
  billions of frames, a truncated delivery is possible.

TB validates the header checksum before trusting any header
field. The header checksum covers the size field. If the header
is corrupt, the size is untrusted.

**Direction:** CRC covers `len_bytes ++ payload_bytes` via
incremental `Crc32.update()`. Two non-contiguous regions (len
at offset 0, payload at offset 8, CRC field in between at
offset 4). Same number of bytes hashed — no performance cost.

A corrupted length of any value produces a CRC mismatch because
the length bytes are included in the checksum. No undetected
truncation possible.

### 7. Frame data must be copied inside on_frame, not after

`on_frame_fn` receives `frame: []const u8` — a slice into the
Connection's `recv_message.buffer`. After `on_frame_fn` returns,
`try_drain_recv` compacts the recv buffer (`copy_left`),
invalidating the slice.

**Any data derived from `frame` that the consumer stores on its
own fields must be `copy_state`'d before `on_frame_fn` returns.**

This was not a bug in the old blocking `read_frame` code because
the recv buffer wasn't reused until the next `read_frame` call.
With the async bus, compaction is immediate after callback return.

**Found during Phase 2 implementation.** `result_data` was stored
as a direct slice into `frame`. After compaction, it pointed into
shifted or overwritten memory. Fixed by calling `copy_state`
inside `on_frame` before storing `result_data`.

**The sidecar fuzzer (Phase 3) must test this:** inject trailing
bytes after a RESULT frame so compaction runs after `on_frame`.
Assert that `result_data` (in `state_buf`) matches expected
payload.

## Extension points (future, not built now)

These are capabilities we've deliberately excluded but designed
the bus to accept without redesign. Each is additive — new code
alongside existing code, no structural changes.

### Layering guarantee

The architecture is layered so that changes below the bus don't
ripple above it, and changes above the bus don't ripple below:

```
Handlers          (call storage.query — don't know sync vs async)
    ↓
State Machine     (prefetch returns .pending — already async)
    ↓
MessageBus        (ConnectionType parameterized on IO type)
    ↓
IO layer          (epoll today — io_uring swaps here)
```

Each layer talks to the one below through a comptime interface.
Swapping the IO layer (epoll → io_uring) changes zero lines in
ConnectionType, MessageBusType, state machine, or handlers.
Adding network storage (SQLite → PostgreSQL) changes one line
in app.zig and adds a concurrent pipeline in the server — the
bus delivers frames regardless. See network-storage.md for the
full analysis.

This works because we followed TB's principle #5 (right
primitive) at every layer. The Connection is the transport
primitive — it doesn't know about storage, handlers, or
pipeline depth. The storage interface is the data primitive —
it doesn't know about connections or framing.

### Extension list

- **Outbound `connect()`.** The MessageBus currently only accepts
  inbound connections via `listen()` + `tick_accept()`. If we
  ever need the server to initiate connections (e.g., server-to-
  server replication, push-to-worker), add `connect(addr)` +
  `tick_connect()` + `connect_callback()` to the MessageBus.
  The Connection doesn't change — it still gets an fd via `init()`.
  The bus just obtains the fd differently. TB has this as
  `connect_connection()` + `connect_callback()`.

- **Multiple connections via pool/dispatcher.** For multiple
  sidecar runtimes, horizontal scaling, or PG connection pools
  (see network-storage.md), build a `ConnectionPool` above the
  MessageBus. The pool owns N MessageBus instances, dispatches
  requests to available ones, and manages the lifecycle. Each
  MessageBus owns one Connection — the pool is the concurrency
  coordinator. This requires concurrent pipeline work in the
  server (multiple `commit_stage` slots) alongside the pool.

- **io_uring IO layer.** Replace epoll with io_uring. The IO
  interface stays the same (`recv`, `send`, `send_now`, `accept`,
  `close`, `shutdown`). io_uring batches submissions and
  completions in single kernel transitions. Benchmarks show
  this saves ~1-2μs per request — irrelevant at 55K req/s with
  SQLite (<1% CPU on IO syscalls). Becomes meaningful with
  network storage where concurrent pipeline + batched IO
  submissions compound. See network-storage.md for throughput
  estimates. Build when profiling shows IO syscall overhead as
  a meaningful percentage of request time — not before.

- **`io.timeout` for idle detection.** The idle timeout (no
  complete frame within N seconds) currently needs manual
  timestamp tracking. If we add `io.timeout()` to the IO layer
  (TB has this), the Connection can use it to schedule a timeout
  completion that fires if no frame arrives. Cleaner than
  polling wall-clock time.

## What this replaces

- Raw `protocol.read_frame` / `write_frame` (blocking syscalls)
- `io.readable` + `sidecar_recv_callback` (manual epoll management)
- `sidecar_completion` field on server
- Blocking `listen_and_accept()` at startup
- `SO_RCVTIMEO` / `SO_SNDTIMEO` socket timeouts
- SimIO no-op for sidecar (line 574)
- Unchecksummed frame transport (length prefix only)
