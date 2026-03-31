# Sidecar IO Layer — Non-blocking frames + SimSidecar

> **Principle:** Always implement the most architecturally correct
> solution. The IO layer is the seam between application and OS.
> Bypassing it means the code can't be simulated.

## Problem

The sidecar uses raw `posix.recv`/`posix.send` via `read_frame`/
`write_frame` in `protocol.zig`. This bypasses the IO layer (epoll
in production, SimIO in simulation). Two consequences:

1. **Blocking IO inside epoll callback.** `sidecar_recv_callback`
   calls `on_recv` which calls `read_frame` (blocking recv). Works
   for unix sockets (microseconds) but violates the principle that
   IO callbacks must not block.

2. **Can't simulate the sidecar.** SimIO intercepts IO operations
   for deterministic testing. The sidecar bypasses SimIO — no
   simulation possible. The async pend/resume path (commit_dispatch
   stages) has no automated deterministic test.

These are the same fix. Make the sidecar go through the IO layer.
SimSidecar falls out naturally.

## Layer 1: Buffered frame reader on SidecarClient

Replace `read_frame` (blocking recv loop) with buffered IO-layer
reads. Same pattern as HTTP connection recv:

1. `io.recv(fd, buf)` — non-blocking, delivers partial data.
2. Accumulate bytes in a frame buffer.
3. Try to parse: read 4-byte length prefix, check if enough data.
4. If complete frame: process it (call `on_recv` logic).
5. If incomplete: wait for next `io.recv` callback.

SidecarClient gains:
- `frame_recv_buf`: accumulation buffer for partial reads.
- `frame_recv_pos`: bytes received so far.
- `submit_recv()`: registers `io.recv` on the sidecar fd.
- `recv_callback()`: accumulates bytes, checks for complete frame.
- `on_frame()`: protocol logic, split from recv buffering.

Separation of concerns:
- `recv_callback` owns buffering (accumulate, check boundary).
- `on_frame` owns protocol logic (RESULT → complete, QUERY →
  respond + re-arm recv).

```
recv_callback (IO layer)
  → accumulate bytes into frame_recv_buf
  → if complete frame: on_frame(frame)
  → if incomplete: re-submit io.recv

on_frame (protocol logic)
  → if RESULT: store result, .complete, call commit_dispatch
  → if QUERY: execute SQL, io.send QUERY_RESULT, re-submit
    io.recv via send_callback chain
```

The QUERY sub-protocol chains IO callbacks:
recv → on_frame (QUERY) → io.send QUERY_RESULT → send_callback
→ re-submit io.recv → recv_callback → on_frame (RESULT) → complete.

Each step is one IO callback. No blocking. Fully deterministic in
SimIO. The state machine (`.receiving` until `.complete`) drives the
transitions. Same pattern as TB's replication protocol processing.

`call_submit` uses `io.send` instead of `write_frame` (blocking
send loop). Send callback confirms delivery.

### Checklist

- [ ] Add frame_recv_buf + frame_recv_pos to SidecarClient.
- [ ] `submit_recv()` calls `io.recv(fd, buf, completion, ...)`.
- [ ] `recv_callback()` accumulates bytes, parses frame header.
- [ ] When complete frame available, call existing on_recv logic.
- [ ] If incomplete, re-submit `io.recv`.
- [ ] Replace `call_submit` write path with `io.send`.
- [ ] Replace QUERY_RESULT write in on_recv with `io.send`.
- [ ] Remove `SO_RCVTIMEO`/`SO_SNDTIMEO` — no longer blocking.
- [ ] Set sidecar fd to non-blocking (`SOCK.NONBLOCK`).
- [ ] All existing tests pass (native Zig path unchanged).
- [ ] End-to-end sidecar test passes.
- [ ] Sidecar fuzzer passes (may need adjustment for non-blocking).

## Layer 2: SimSidecar

Simulation primitive for the sidecar. Separate from SimIO (which
simulates HTTP clients). Same pattern as TB's SimStorage — each
simulated component has its own type.

SimSidecar speaks CALL/RESULT frames. It receives CALL frames
from the server (via SimIO's send interception on the sidecar fd),
processes them (PRNG-driven), and delivers RESULT frames back
(via SimIO's recv delivery).

### Registration mechanism

SimSidecar owns a fd. SimIO gains a registration field:
`sidecar: ?*SimSidecar`. At test init, SimSidecar registers with
SimIO via `io.register_sidecar(fd, *SimSidecar)`.

SimIO's send/recv paths check: "is this fd the registered sidecar?"
If yes, route to SimSidecar. If no, route to SimClient (HTTP).
One field, one check per send/recv. Same as TB's pattern — SimStorage
is a known component, not discovered dynamically.

### How it works

When the server does `io.send(sidecar_fd, call_frame)`, SimIO
routes to SimSidecar.inject_call(data). SimSidecar stores the CALL,
PRNG decides response delay. SimSidecar.tick() counts down. When
ready, SimSidecar writes a RESULT frame into SimIO's recv buffer
for the sidecar fd. Next `io.recv` callback delivers the RESULT.

For QUERY sub-protocol: when on_frame sends a QUERY_RESULT via
`io.send`, SimIO routes to SimSidecar. SimSidecar processes it
(acknowledges the QUERY response) and prepares the next frame
(another QUERY or final RESULT).

### SimSidecar struct

```
SimSidecar:
  fd: fd_t                           // SimIO-managed fd
  prng: *PRNG                        // controls timing + faults
  pending_call: ?[]const u8          // CALL frame waiting for response
  response_delay: u32                // ticks before RESULT is delivered
  ticks_remaining: u32               // countdown

  inject_call(data)                  // called by SimIO on send
  tick()                             // decrement counter, deliver when 0
  make_result(call) → result_frame   // generate valid RESULT for CALL
```

### Checklist

- [ ] SimSidecar struct with PRNG-driven response timing.
- [ ] SimIO gains `sidecar: ?*SimSidecar` field + `register_sidecar`.
- [ ] SimIO send/recv paths: if fd matches sidecar fd, route to
  SimSidecar. Otherwise route to SimClient.
- [ ] SimIO routes sidecar fd sends to SimSidecar.inject_call.
- [ ] SimSidecar.tick() called from SimIO.run_for_ns.
- [ ] When response ready, SimSidecar writes RESULT into SimIO
  recv buffer for the sidecar fd.
- [ ] QUERY sub-protocol: intercept QUERY_RESULT sends, respond
  with valid empty row sets.
- [ ] Sim test: HTTP request → sidecar CALL → SimSidecar delay →
  RESULT → pipeline resume → HTTP response. Full cycle.
- [ ] PRNG-driven faults: drop RESULT, delay RESULT, send malformed
  RESULT. Exercises dead dispatch deadline + pipeline failure.

## Dependency

Layer 1 must be done first. Without IO-layer sidecar operations,
SimIO can't intercept the sidecar fd.

## What this replaces

- todo.md item 4 (SimSidecar) — implemented here.
- todo.md item 5 (non-blocking sidecar frame IO) — implemented here.
- The protocol fuzzer's pend/resume tests remain (they test the
  state machine directly). SimSidecar tests the integration
  (commit_dispatch + pipeline + IO).
