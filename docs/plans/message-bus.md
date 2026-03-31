# Message Bus — Framed IO Transport

> **Principle:** Always implement the most architecturally correct
> solution. The IO layer is the seam between application and OS.
> All socket communication goes through the message bus. No raw
> syscalls.

## What this is

A transport layer for framed communication over stream sockets,
modeled 1:1 on TigerBeetle's `message_bus.zig`. Handles:

- Non-blocking send/recv through the IO layer
- Frame accumulation and boundary detection (partial reads)
- Connection lifecycle (connect, disconnect)
- Backpressure (suspend recv when consumer is busy)
- Simulation support (SimIO intercepts, deterministic delivery)

The sidecar, worker client, and any future socket communication
use the message bus. Protocol logic (CALL/RESULT, QUERY) lives
in the consumer, not in the bus.

## Research phase

Read TigerBeetle's implementation before building ours:

### Read

- `src/message_bus.zig` — the full implementation. 1,214 lines.
  Most is cluster topology (multi-peer, replica identity,
  reconnection). Extract the core transport pattern.
- `src/message_bus.zig: Connection` — the inner struct. This is
  the core: recv buffer, frame accumulation, send queue, IO
  callbacks. This is what we're building.
- `src/message_buffer.zig` — how messages are buffered for recv.
- `src/message_pool.zig` — pre-allocated message pool. We may
  simplify to static buffers (our frames are bounded).

### What to extract (the core pattern)

**Recv path:**
```
io.recv(fd, buf) → recv_callback
  → accumulate bytes into recv_buf
  → check for complete frame (length prefix)
  → if complete: on_message(frame) — consumer callback
  → if incomplete: re-submit io.recv
  → if recv suspended (backpressure): don't re-submit
```

**Send path:**
```
io.send(fd, data) → send_callback
  → if partial send: re-submit remaining bytes
  → if complete: dequeue next from send queue (if any)
```

**Backpressure:**
```
suspend_recv() — stop submitting io.recv
resume_recv() — re-submit io.recv, drain buffered data
```

**Connection lifecycle:**
```
connect(fd) — set fd, submit initial io.recv
disconnect() — close fd, reset buffers
```

### What to skip (cluster-specific)

- Process identity (replica vs client)
- Multiple peer connections + connection pool
- Accept loop (server.zig already handles HTTP accepts)
- Reconnection to replicas
- Send queue ring buffer (we send one frame at a time)
- Message pool (we use static buffers)

## Implementation

### MessageBus struct

```zig
pub fn MessageBusType(comptime IO: type) type {
    return struct {
        io: *IO,
        fd: IO.fd_t,

        // Recv: accumulation buffer for partial reads.
        recv_buf: [frame_max + 4]u8,
        recv_pos: usize,
        recv_completion: IO.Completion,
        recv_submitted: bool,
        recv_suspended: bool,

        // Send: current outgoing frame.
        send_buf: [frame_max + 4]u8,
        send_pos: usize,
        send_len: usize,
        send_completion: IO.Completion,
        send_submitted: bool,

        // Consumer callback — called with complete frame data.
        on_frame_fn: *const fn (*MessageBus, []const u8) void,
        context: *anyopaque,

        pub fn connect(self: *MessageBus, fd: IO.fd_t) void;
        pub fn disconnect(self: *MessageBus) void;
        pub fn send_frame(self: *MessageBus, data: []const u8) void;
        pub fn suspend_recv(self: *MessageBus) void;
        pub fn resume_recv(self: *MessageBus) void;

        fn submit_recv(self: *MessageBus) void;
        fn recv_callback(context: *anyopaque, result: i32) void;
        fn try_parse_frame(self: *MessageBus) ?[]const u8;
        fn submit_send(self: *MessageBus) void;
        fn send_callback(context: *anyopaque, result: i32) void;
    };
}
```

### Recv callback (from TB's Connection.recv_callback)

```
recv_callback:
  if result <= 0: disconnect, return
  recv_pos += result
  while try_parse_frame() returns frame:
    on_frame_fn(frame)
    if recv_suspended: return  // consumer needs time
  if !recv_suspended: submit_recv()  // ready for more
```

### Frame boundary detection

```
try_parse_frame:
  if recv_pos < 4: return null  // need length prefix
  len = read_u32_be(recv_buf[0..4])
  if recv_pos < 4 + len: return null  // need more data
  frame = recv_buf[4..4+len]
  // Shift remaining bytes to front of buffer.
  memmove(recv_buf, recv_buf[4+len..], recv_pos - 4 - len)
  recv_pos -= 4 + len
  return frame
```

### Send path (from TB's Connection.send)

```
send_frame:
  write length prefix + data into send_buf
  send_len = 4 + data.len
  send_pos = 0
  submit_send()

send_callback:
  if result <= 0: disconnect, return
  send_pos += result
  if send_pos < send_len: submit_send()  // partial, continue
  // else: send complete
```

### Checklist

- [ ] Implement MessageBusType(IO) struct.
- [ ] recv path: submit_recv, recv_callback, try_parse_frame.
- [ ] send path: send_frame, submit_send, send_callback.
- [ ] Backpressure: suspend_recv, resume_recv.
- [ ] connect/disconnect lifecycle.
- [ ] on_frame_fn callback to consumer.

## Integration

### SidecarClient uses MessageBus

SidecarClient stops using `protocol.read_frame`/`write_frame`
(raw syscalls). Instead:

```zig
const SidecarClient = struct {
    bus: *MessageBus,
    // ... protocol state (call_state, result_flag, etc.)

    fn on_frame(bus: *MessageBus, frame: []const u8) void {
        const self = ...; // from bus.context
        // Existing on_recv logic — parse RESULT/QUERY.
    }
};
```

`call_submit` calls `bus.send_frame(call_data)`.
`on_frame` replaces `on_recv`'s frame reading — it receives a
complete frame, no `read_frame` call needed.

QUERY sub-protocol: `on_frame` receives QUERY, executes SQL,
calls `bus.send_frame(query_result)`, bus delivers next frame
when ready.

### WorkerClient uses MessageBus

Same pattern but on the worker socket. Multiple CALLs in-flight —
`on_frame` matches request_id to pending slots.

### Server integration

`submit_sidecar_recv` and `sidecar_recv_callback` are replaced by
the MessageBus recv path. The server creates the MessageBus with
the sidecar fd, sets `on_frame_fn` to SidecarClient's handler.

No more `io.readable` on the sidecar fd — MessageBus manages its
own `io.recv`.

### Checklist

- [ ] SidecarClient: replace read_frame/write_frame with MessageBus.
- [ ] SidecarClient.on_frame: existing on_recv logic, no IO calls.
- [ ] call_submit: use bus.send_frame.
- [ ] QUERY sub-protocol: on_frame → send_frame → next recv.
- [ ] WorkerClient: MessageBus on worker socket.
- [ ] Server: remove submit_sidecar_recv, sidecar_recv_callback,
  sidecar_completion. MessageBus handles all sidecar IO.
- [ ] Remove SO_RCVTIMEO/SO_SNDTIMEO from sidecar fd.
- [ ] Set sidecar fd to non-blocking.
- [ ] All existing tests pass.
- [ ] End-to-end sidecar test passes.
- [ ] Sidecar fuzzer passes (adjust for non-blocking).

## SimSidecar

Simulation primitive. Separate from SimIO's HTTP clients.

### SimIO registration

SimIO gains `sidecar: ?*SimSidecar` + `register_sidecar(fd)`.
Send/recv paths check: if fd matches sidecar, route to SimSidecar.
Otherwise route to SimClient.

### SimSidecar struct

```
SimSidecar:
  fd: fd_t
  prng: *PRNG
  pending_call: ?[]const u8
  response_delay: u32
  ticks_remaining: u32

  inject_call(data)               // called by SimIO on send
  tick()                          // countdown, deliver when 0
  make_result(call) → frame       // generate valid RESULT
  has_response() → bool           // true when ready to deliver
  take_response() → []const u8    // RESULT frame bytes
```

### How it works

Server sends CALL via `bus.send_frame` → SimIO intercepts send →
`sidecar.inject_call(data)`. SimSidecar stores CALL, PRNG picks
delay. `tick()` counts down. When ready, `has_response()` returns
true. SimIO delivers the RESULT bytes on next recv for that fd.

QUERY sub-protocol: SimSidecar responds to QUERY_RESULTs with
the next frame (QUERY or RESULT). All within the tick cycle.

### Checklist

- [ ] SimSidecar struct with PRNG-driven response timing.
- [ ] SimIO: register_sidecar, route send/recv for sidecar fd.
- [ ] SimSidecar.tick() called from SimIO.run_for_ns.
- [ ] QUERY sub-protocol handling.
- [ ] Sim test: full HTTP → CALL → delay → RESULT → response cycle.
- [ ] PRNG faults: drop RESULT, delay, malformed. Exercises dead
  dispatch + pipeline failure paths.

## Dependencies

```
MessageBus (transport)
    ↓
SidecarClient + WorkerClient (consumers)
    ↓
SimSidecar (simulation)
```

Build bottom-up. MessageBus first, then rewire consumers, then sim.

## What this replaces

- Raw `protocol.read_frame` / `write_frame` (blocking syscalls)
- `io.readable` + `sidecar_recv_callback` (manual epoll management)
- `sidecar_completion` field on server
- todo.md items 4 (SimSidecar) and 5 (non-blocking frame IO)
