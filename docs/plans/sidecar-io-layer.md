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
- `recv_callback()`: appends data, tries to parse complete frame.

`on_recv` no longer calls `read_frame`. It receives a complete
frame (already parsed by `recv_callback`).

Similarly, `call_submit` uses `io.send` instead of `write_frame`
(blocking send loop). For QUERY_RESULT responses during the QUERY
sub-protocol, same pattern.

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

### How it works

SimIO already manages fds. The sidecar fd is a SimIO-managed fd.
When the server does `io.send(sidecar_fd, call_frame)`, SimIO
captures the data. SimSidecar reads it. When SimSidecar decides
to respond (PRNG controls timing), it writes a RESULT frame into
SimIO's recv buffer for that fd. Next `io.recv` callback delivers
the RESULT to the server.

For QUERY sub-protocol: when on_recv sends a QUERY_RESULT via
`io.send`, SimSidecar intercepts it, processes the QUERY, and
sends back a QUERY_RESULT. All synchronous within the tick.

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
