# Decision: kqueue port from TigerBeetle, Docker for deployment only

## Context

We tried to make the framework run on macOS via Docker. This created
a shell/Docker layer (focus CLI, focus-internal, Dockerfile, polling
file watcher, sleep loops) that violated every TB principle. The root
issue: macOS doesn't have io_uring.

## Decision: port io/darwin.zig from TigerBeetle

TigerBeetle already solved this. Their IO layer has platform
implementations:

```
tigerbeetle/src/io/linux.zig   (1880 lines, io_uring)
tigerbeetle/src/io/darwin.zig  (1093 lines, kqueue)
tigerbeetle/src/io/windows.zig (1598 lines, IOCP)
```

Our linux.zig is a direct copy of TB's (35 lines diff — import paths
and one superblock check removed). The darwin.zig port is the same
operation: copy, adjust imports, remove superblock check.

## How to port

```bash
# 1. Copy darwin.zig
cp /path/to/tigerbeetle/src/io/darwin.zig framework/io/darwin.zig

# 2. Adjust imports (same as linux.zig)
# Change: const buffer_limit = @import("../io.zig").buffer_limit;
# To:     const buffer_limit = @import("../io_defs.zig").buffer_limit;
# Same for DirectIO.

# 3. Remove superblock zone check in open_file (if present)
# Same as linux.zig — comment with "not applicable to tiger_web"

# 4. Add platform switch to framework/io.zig
# const InnerIO = switch (builtin.target.os.tag) {
#     .linux => @import("io/linux.zig").IO,
#     .macos => @import("io/darwin.zig").IO,
#     else => @compileError("unsupported platform"),
# };
```

## Why not Docker for dev

Docker on macOS runs a Linux VM. This works, but:
- Volume mounts don't propagate inotify events (file watching broken)
- Container port binding fails silently on address-in-use
- `seccomp=unconfined` required for io_uring (security concern for users)
- 7GB build context copies on every `docker build`
- Process lifecycle (kill/restart) is unreliable across container boundary
- Error messages go to Docker logs, not the user's terminal
- Adds 6-18 seconds to startup for no framework benefit

With the kqueue port:
- `focus dev handlers/` runs natively on macOS
- File watching uses kqueue (sub-ms, kernel-level)
- Errors go straight to the terminal
- No container, no VM, no port mapping, no seccomp
- Cross-compile: `zig build -Dtarget=aarch64-macos`

## Docker's remaining role

Docker is for **deployment**, not development:
- `Dockerfile` defines the production image
- CI uses Docker for reproducible builds
- Deployment targets (Fly.io, Railway, etc.) use the Dockerfile

Developers never touch Docker. `focus dev` is native.

## What stays from the Docker session

The framework bugs found DURING the Docker work are all valid:
- SQL cache pointer-identity bug (FNV-1a content hash)
- SHM region header not written after memset
- OperationValues not generated for new operations
- Ecommerce route table shadowing user routes
- Scanner generating routes for .ts files (should be .zig only)
- Comptime assertion checking exhaustiveness (wrong — scanner's job)
- Bus termination deadline (defense-in-depth, correct)
- Mutation-safe sidecar_on_close (stage-aware recovery)
- SQL error messages in server logs
- build_result protocol helper

These stay regardless of the distribution mechanism.

## Reference

- TB io/darwin.zig: `/home/walker/Documents/personal/tigerbeetle/src/io/darwin.zig`
- TB io/linux.zig: `/home/walker/Documents/personal/tigerbeetle/src/io/linux.zig`
- Our linux.zig: `/home/walker/Documents/personal/tiger_web/framework/io/linux.zig`
- Diff: 35 lines (import paths + superblock check removal)
