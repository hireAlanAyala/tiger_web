# Plan: CLI Polish (Low Priority)

Items deferred from the high-priority polish pass. None of these block
shipping or affect correctness. Implement when time permits or when a
user hits the friction.

## Deferred items

| Item | What | Why deferred |
|------|------|--------------|
| `focus docs` | Print framework reference to stdout | No content written yet — needs guide/ docs first |
| `focus deploy --dockerfile` | Generate production Dockerfile from project | Deployment story undefined — premature |
| `focus self-update` | Download latest focus binary | Blocked on hosting (no binary distribution yet) |
| `focus upgrade` | Update vendored adapter files in focus/ | Need versioning strategy — which files are user-editable vs framework-owned |
| `--verbose` flag | Show scanner/codegen internals on build failure | Build hook already inherits stderr — most failures visible without this |
| Build hook failure quoting | Show the exact command that failed | Minor UX — currently shows exit code which is sufficient |
| `.focus` `port` field | Default dev port without `--port` flag every time | Convenience only — `--port` works fine |
| `run_server` uses `page_allocator` | Process-lifetime thread, leaks by design | Acceptable — server thread never returns. Would need GPA threading support to fix. |
| inotify watch list unbounded | No cap on watched directories | Pathological case (thousands of dirs) not realistic for handler source trees |
| macOS stat polling untested | Compiles but never exercised | Blocked on darwin.zig TimeOS fix — separate work item |
| Install script (`curl \| sh`) | Download + install focus binary | Blocked on binary hosting (GitHub releases, CDN, etc) |

## What was completed in the high-priority pass

- [x] Atomic `shutdown_requested` (signal handler race fix)
- [x] Dynamic inotify watches (IN_CREATE on new subdirs)
- [x] Print actual URL (`http://localhost:{port}`) from port_signal atomic
- [x] Schema hot-reload (watches schema.sql mtime, re-applies on change)
- [x] `.focus` `db` field (configurable DB name, defaults to tiger_web.db)
- [x] Sidecar crash shows exit code
- [x] `isatty` check (suppress ANSI when piped)
- [x] `--port` passthrough to embedded server
- [x] Vendored SQLite amalgamation (zero system deps, cross-compile works)
- [x] ReleaseSafe build tested (6.3MB focus, 4.6MB tiger-web)
- [x] CI stub sidecar (sed override for hermetic smoke test)
- [x] Signal handlers (SIGINT/SIGTERM → clean sidecar kill)
- [x] Sidecar restart backoff (5s between attempts)
- [x] PID-scoped socket path (no collision between concurrent sessions)
- [x] Recursive inotify watches (all subdirs at init)
- [x] Error output to stderr
- [x] parse_hook handles comments, trailing whitespace, prefix collision

## macOS cross-compile status

SQLite amalgamation cross-compiles clean for aarch64-macos. The build
fails due to `framework/io/darwin.zig` referencing `TimeOS` which doesn't
exist in our time.zig. Fix: add TimeOS alias or port the relevant time
primitives. This is tracked separately in the DX recovery plan.
