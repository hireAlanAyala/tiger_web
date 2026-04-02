# Decision: Sidecar Lifecycle Management

## The problem

The server needs to kill the sidecar on protocol violations.
`SIGKILL(pid)` is the mechanism. But `pid` from the READY
handshake might be a wrapper process (npx, poetry, deno run)
whose children hold the actual socket.

## Decision: the adapter declares its runtime semantics

The READY handshake should carry enough information for the
server to manage the sidecar's lifecycle. The server doesn't
know about Node.js process trees or Python virtualenvs.

### Current READY frame

```
[tag: 0x20][version: u16 BE][pid: u32 BE]
```

### Future READY frame (proposed)

```
[tag: 0x20][version: u16 BE][pid: u32 BE][flags: u8]
```

Flags:
- bit 0: `kill_group` — SIGKILL should target the process GROUP
  (-pid), not the individual process. Set when the runtime uses
  a process tree (Node via npx, Python via poetry).
- bit 1-7: reserved

The adapter sets the flags based on its runtime. The server
reads them and adjusts its kill strategy:
- `kill_group = false`: `kill(pid, SIGKILL)`
- `kill_group = true`: `kill(-pid, SIGKILL)` (process group)

### Alternative: spawn with setsid

If the sidecar process is spawned by the server (not the
hypervisor), the server can call `setsid()` to create a new
session/process group. Then `kill(-pid, SIGKILL)` always works
regardless of the runtime's process tree.

But when the hypervisor spawns the sidecar (systemd, docker),
the server doesn't control the process group. The flags approach
is more general.

### For now

The READY frame carries `pid`. The e2e test spawns Node directly
(no npx wrapper) to avoid the process tree issue. In production,
the hypervisor should ensure the PID in READY matches the
actual process holding the socket — either by spawning node
directly or by using a process manager that sets up correct
process groups.

This decision can be revisited when adding Python/Go adapters.
The READY frame has room for a flags byte without breaking
the wire format (just extend the payload).
