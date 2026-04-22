# Draft: Windows Binary Support

## Context

macOS support landed (April 2026) and exposed a pattern: every Linux
assumption was invisible until we tested on a second platform. The
macOS port taught us:

1. **`cp` from TB, don't write from memory.** Our from-scratch TimeSim
   drifted from TB's on every field. The macOS clock code (copied from
   TB) was correct on the first try. CLAUDE.md rule: "cp the TB file
   and make surgical edits."

2. **Grep `std.os.linux` across the entire codebase once.** We found
   `linux.getpid()` three times, each in a different session. One grep
   on day one would have caught all three.

3. **Test on real hardware from the first commit.** CI caught
   `shm_open` ETIMEDOUT on macOS — a behavior difference no
   cross-compilation check can find. Add `windows-latest` to CI
   before writing any code.

4. **Dead code from reverted experiments is the worst debt.** The futex
   scaffolding compiled on Linux, crashed on macOS. Delete dead code
   before porting.

5. **Use the right primitive, not a platform workaround.** The
   `shm_open` readiness probe was wrong on every platform — we just
   didn't know it until macOS returned ETIMEDOUT. The atomic bool
   signal was always the correct answer.

## Approach

**Copy from TigerBeetle, make surgical edits.**

TB ships Windows binaries today. Their `io/windows.zig` (1,598 lines)
is a complete IOCP implementation. Their build system has `x86_64-windows`
as a first-class target. Their Node.js client links `ws2_32` + `advapi32`
and generates `node.lib` via `zig dlltool`.

Reference: `/home/walker/Documents/personal/tigerbeetle`

## What TB already has (copy via `cp`)

| File | Lines | What it does |
|------|-------|--------------|
| `src/io/windows.zig` | 1,598 | IOCP event loop — accept, recv, send, timeout, fsync |
| `src/io/common.zig` | 155 | Cross-platform TCP options, socket helpers (already ported) |
| `src/stdx/time.zig` | Windows monotonic (QueryPerformanceCounter) + realtime (GetSystemTimePreciseAsFileTime) |
| `src/stdx/mlock.zig` | Windows memory lock (SetProcessWorkingSetSize) — already ported |
| `build.zig` | Platform enum, `zig dlltool` for node.lib, ws2_32/advapi32 linkage |

**Surgical edits needed (same as macOS port):**
- Import paths: `@import("../constants.zig")` → `@import("constants.zig")`
- Module name: `@import("vsr")` → domain-specific imports
- Remove VSR/consensus-specific code (replication, grid, superblock)
- Keep: socket IO, timeout, event signaling, file IO

## Implementation phases

### Phase 1: IO layer + basic server (copy + compile)

1. `cp` TB's `io/windows.zig` to `framework/io/windows.zig`
2. Surgical edits: import paths, remove VSR-specific code
3. Add `x86_64-windows` to the `InnerIO` switch in `framework/io.zig`
4. Add Windows time functions to `framework/time.zig` (copy from TB)
5. Cross-compile: `./zig/zig build -Dtarget=x86_64-windows`
6. Add `windows-latest` to CI matrix — run unit tests + sim tests

**Expected issues (from macOS experience):**
- `std.os.linux` references anywhere in the server path (grep first)
- `/tmp` paths hardcoded (use `std.fs.tmpDir` or `%TEMP%`)
- Unix socket paths (Windows uses named pipes or TCP loopback)
- Signal handling (no SIGINT/SIGTERM — use SetConsoleCtrlHandler)

### Phase 2: SHM transport on Windows

**This is the unexplored part.** TB does NOT use shared memory on
Windows. Our SHM transport (`shm_bus.zig`) uses POSIX `shm_open` +
`mmap`. Windows equivalent:

```
shm_open + mmap → CreateFileMapping + MapViewOfFile
shm_unlink → CloseHandle (reference counted, auto-cleanup)
```

**Unknowns:**
- Does Zig's `std.os.windows` expose `CreateFileMapping`? If not, need
  `@cImport` or extern declarations.
- Memory-mapped file naming: `Global\\tiger-{pid}` vs `Local\\tiger-{pid}`.
  Global requires SeCreateGlobalPrivilege (elevated). Local is per-session.
- Atomics (`__atomic_load_n` in shm.c): MSVC uses `_InterlockedCompareExchange`.
  Zig's `@atomicStore`/`@atomicLoad` compile to correct intrinsics on all platforms.
  The C addon needs `#ifdef _WIN32` guards or Zig-native addon.
- `ftruncate` on memory-mapped files: Windows uses `SetFilePointerEx` +
  `SetEndOfFile` or just specify size in `CreateFileMapping`.

**Decision needed:** Is SHM the right primitive on Windows, or should
the sidecar use TCP loopback (127.0.0.1) or named pipes? TB uses named
pipes for IPC on Windows (`\\.\pipe\[name]`). Named pipes avoid the
SHM complexity entirely but add kernel buffering overhead.

Benchmark before deciding. If TCP loopback gives >30K req/s on Windows,
SHM may not be worth the complexity. Our Linux SHM advantage is 45K vs
30K (socket) — if Windows TCP is fast enough, skip SHM.

### Phase 3: Native addon for Windows

1. Add `x86_64-windows` to `NativePlatform` enum in `build.zig`
2. Cross-compile `shm.c` (or Windows-specific variant) as `.dll`
3. TB pattern: `zig dlltool` generates `node.lib` import library from
   N-API symbol exports. Copy their `build_node_client` Windows path.
4. Link `ws2_32` (Winsock) if using TCP loopback transport
5. Runtime detection in `shm_client.ts`: add `"win32": "windows"` to
   `platformMap`

### Phase 4: Focus CLI on Windows

**Unknowns:**
- `std.Thread.spawn` works on Windows (Zig std supports it)
- `std.process.Child` for sidecar process management — works, but no
  process groups (no `pgid=0`). Supervisor needs `TerminateProcess`
  instead of `kill(-pgid, SIGTERM)`
- File watcher: no `inotify`, no `kqueue`. Use `ReadDirectoryChangesW`
  or `FindFirstChangeNotification`. TB doesn't have a file watcher —
  this is our code, needs Windows implementation.
- `.focus` file: same format, just path separators (`\` vs `/`)
- `shm_open` readiness probe: already replaced with atomic signal
  (lesson from macOS). No Windows-specific fix needed.

### Phase 5: CI + release

1. Add `windows-latest` to CI matrix (test + clients)
2. Cross-compile all binaries for Windows in `build_native_addon`
3. Embed `x86_64-windows/shm.node` in focus binary
4. Test `focus new`, `focus build`, `focus dev` on Windows CI

## What we do NOT know yet

These are genuinely unexplored. Don't plan around assumptions — verify
on real hardware first (lesson from macOS ETIMEDOUT).

1. **Windows SHM performance.** `CreateFileMapping` + `MapViewOfFile`
   might have different overhead than POSIX `shm_open` + `mmap`. Or
   Windows named pipes might be fast enough to skip SHM entirely.

2. **Node.js addon loading on Windows.** The `.node` file is a `.dll`
   renamed. Node's `require()` should load it, but code signing,
   Windows Defender, and DLL search paths could interfere. TB tests
   this in CI — we should too before assuming it works.

3. **IOCP completion model vs our callback bridge.** Our `IO` wrapper
   bridges TB's typed callbacks to raw `fn(*anyopaque, i32)` callbacks.
   TB's `io/windows.zig` uses IOCP (`GetQueuedCompletionStatusEx`),
   which has a different completion model than io_uring/kqueue. The
   bridge might need adjustments. Read `windows.zig` carefully before
   assuming the same wrapper works.

4. **Process management without signals.** The supervisor uses
   `SIGTERM` for graceful shutdown and `waitpid` for exit detection.
   Windows has `TerminateProcess` (not graceful) and
   `WaitForSingleObject`. The `SidecarChild` in focus.zig needs a
   Windows code path. TB's multiversion.zig shows the pattern (named
   pipes for handle passing).

5. **WAL file locking.** Our WAL uses `posix.open` with `O_APPEND`.
   Windows file locking is mandatory (not advisory like POSIX). Two
   `focus dev` sessions writing the same WAL might deadlock instead of
   corrupting silently. Might actually be better — but needs testing.

## Estimated effort

Phase 1 (IO + basic server): 1-2 days — mostly `cp` + surgical edits.
Phase 2 (SHM or alternative): 1-2 days — decision + implementation.
Phase 3 (native addon): half day — build.zig changes, TB has the pattern.
Phase 4 (focus CLI): 1 day — file watcher + process management.
Phase 5 (CI): half day — add to matrix, fix whatever breaks.

Total: ~4-5 days, front-loaded with `cp` from TB.

## Non-goals

- ARM Windows (aarch64-windows). TB doesn't target it either. x86_64 only.
- WSL. Users on WSL should use the Linux binary.
- GUI. The framework is CLI-only.
