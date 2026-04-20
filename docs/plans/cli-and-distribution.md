# CLI & Distribution Plan

## Problem

The framework needs to run on developer machines (Linux + macOS).
The first attempt used Docker + shell scripts. It was wrong — too many
layers, wrong primitives, fragile timing, violated the project's own
principle ("centralize on Zig for all of the things").

## Principles

1. One Zig binary (`focus`) is the entire framework interface
2. The user's daily command is `focus dev src/` — no wrappers
3. The framework is language-agnostic at the protocol level
4. The adapter is a file, not a package
5. No config files unless the user creates one
6. macOS support via kqueue port (copy from TigerBeetle), not Docker

---

## Responsibility boundaries

Three layers. No item crosses boundaries.

### Framework (server binary)

The server is a runtime — it accepts connections and serves requests.
It does NOT know about files, builds, scaffolds, dev mode, or deployment.

- Accept HTTP connections
- SHM protocol (CALL/RESULT dispatch)
- SQLite read/write (prefetch + handle)
- WAL (write-ahead log for crash recovery)
- Worker dispatch (async background tasks)
- Wire format (always includes errors when they occur — no mode awareness)
- `ensure_schema` for FRAMEWORK tables only (internal migrations)
- Graceful disconnect/reconnect (bus termination deadline)
- Port selection (picks available port, prints to stdout)

### CLI tool (focus binary)

The CLI is a build/dev tool — it orchestrates the framework + user code.
It does NOT serve HTTP, access SQLite at runtime, or handle requests.

- Scaffold projects (`focus new`)
- Scan annotations (embedded scanner, language-agnostic)
- Apply user schema (`focus schema apply schema.sql --db tiger_web.db`)
- Start server + sidecar (`focus dev` / `focus start`)
- File watching + rebuild + restart sidecar (inotify/kqueue)
- Generate Dockerfile on demand (`focus deploy --dockerfile`)
- Upgrade adapter files (`focus upgrade`)
- Compile native addon (`focus compile-addon`)
- Print docs (`focus docs`)

### User / Adapter

The user owns their code and decides how it compiles, runs, and deploys.
The framework never reads package.json, go.mod, or any language-specific config.

- Handler code (`src/`)
- Build hook (compile/transpile — declared in `.focus`)
- Start hook (run sidecar — declared in `.focus`)
- `schema.sql` (their DDL, applied by CLI before server start)
- Error presentation (adapter decides: dev error page vs production 500)
- Deployment infrastructure (VM, Docker, k8s — their choice)
- `.focus` file (two lines they own and edit)
- `focus/` directory (adapter files, vendored, committed)

### Boundary rules

1. The server never reads user files (schema, handlers, config)
2. The CLI never handles HTTP requests or touches SQLite at runtime
3. The adapter never starts/stops processes or watches files
4. Errors flow DOWN the stack: framework → wire protocol → adapter → user
5. Configuration flows UP: user → `.focus` → CLI → server flags
6. The server has NO concept of "dev mode" vs "production mode"
7. The CLI owns process lifecycle; the server owns connection lifecycle

---

## The CLI

```
focus new --ts myapp        Scaffold a TypeScript project
focus new --go myapp        Scaffold a Go project
focus build src/            Scan annotations + generate dispatch
focus dev src/              Build + server + sidecar + watch + reload
focus start src/            Production mode (no watch, no rebuild)
focus docs                  Print reference
```

### `focus dev src/`

What it does:
1. Read `.focus` file (build + start hooks). Error if missing.
2. Scan `src/` for annotations (scanner linked into the binary)
3. Generate framework artifacts (operations.zig, routes.zig, manifest.json)
4. Run the user's build hook (from `.focus`, e.g., `npx tsx focus/codegen.ts`)
5. Start the server (embedded in the focus binary — same process)
6. Start the sidecar (spawn start hook with $SHM $SOCK in env)
7. Watch `src/` for changes (inotify on Linux, kqueue on macOS)
8. On change: re-scan, re-run build hook, restart sidecar
9. Server stays up — bus deadline handles reconnection

### Self-contained binary

The focus binary contains EVERYTHING framework-owned:
- Annotation scanner (linked in, not shelled out to `zig build scan`)
- Adapter templates (@embedFile for scaffold)
- Server (embedded — `focus dev` runs the server in-process)
- Schema apply (embedded SQLite, same as server)
- Docs (@embedFile reference text)

The binary does NOT contain or assume:
- Node.js / Go / Python (user's runtime)
- npx / tsx / go build (user's build tools)
- Any package manager

External dependencies are declared in `.focus` hooks. The binary
reads the hooks and spawns them. It never hardcodes a runtime.

### No install path, no relative walks

The binary is self-contained. It doesn't need to find:
- A framework installation directory
- A scanner binary on disk
- Adapter files in a lib/ folder
- build.zig (that's for framework development only)

Everything is compiled in. `focus` works from any directory without
PATH configuration or install conventions. Download → run.

### Build and start hooks

The CLI needs to know two things it can't derive:
- How to compile the user's handlers (build hook)
- How to run the sidecar process (start hook)

These are set ONCE at scaffold time and stored in a minimal file:

```
# .focus (created by scaffold, user-owned, committed to git)
build = tsx focus/codegen.ts
start = tsx focus/sidecar.ts
```

Two lines. No TOML parser, no JSON, no YAML. `key = rest of line`.
If the file doesn't exist, `focus dev src/` errors:
"no .focus file — run focus new or create one with build/start hooks."

The user sees this file on day one (scaffolded). They can edit it.
They understand it. It's two commands.

---

## The adapter

A directory of files copied into the project at scaffold time.
Not a package. Not a dependency. Not versioned externally.

```
myapp/
  src/                  ← user's code (annotations here)
    list_items.ts
    create_item.ts
  focus/                ← scaffolded, user-owned, committed
    sidecar.ts          ← SHM runtime (~400 lines)
    codegen.ts          ← reads manifest.json, generates dispatch
    types.ts            ← SDK types (RouteRequest, HandleContext, etc.)
    serde.ts            ← binary row reader
  schema.sql            ← user's database schema
  .focus                ← build + start hooks
  package.json          ← user's package config (no framework entries)
  tsconfig.json
```

The `focus/` directory is:
- Created by `focus new --ts`
- Committed to git by the user
- Never modified by the framework after scaffold
- Upgradeable via `focus upgrade` (user opts in, sees diff)

### Why not a package?

| Concern | Package approach | File approach |
|---------|-----------------|---------------|
| Installation | `npm install @focus/ts` | `focus new --ts` (already done) |
| Updates | `npm update` (surprise breaks) | `focus upgrade` (explicit, shows diff) |
| Vendoring | node_modules (gitignored) | `focus/` (committed) |
| Reading the code | buried in node_modules | right there in the project |
| Languages without packages | doesn't work (C, Zig, etc.) | works everywhere |
| Version conflicts | possible | impossible (it's your file) |
| Offline use | needs registry | just files on disk |

### Per-language adapters

Each adapter implements the same protocol (~400 lines):
- Open SHM region (mmap)
- Poll for new server_seq (atomic load)
- Parse CALL frame (tag + request_id + name + args)
- Dispatch to user's handler function
- Write RESULT frame (tag + request_id + flag + data)
- Compute CRC, bump sidecar_seq

Plus codegen (reads manifest.json, generates dispatch tables):
- TypeScript: `codegen.ts` generates `handlers.generated.ts`
- Go: `codegen.go` generates `handlers_generated.go`
- Python: `codegen.py` generates `handlers_generated.py`

Plus types/SDK for the language:
- TypeScript: `types.ts` (interfaces: RouteRequest, HandleContext, etc.)
- Go: `types.go` (structs)
- Python: `types.py` (dataclasses or TypedDict)

---

## Platform support

```zig
// framework/io.zig
const InnerIO = switch (builtin.target.os.tag) {
    .linux => @import("io/linux.zig").IO,
    .macos => @import("io/darwin.zig").IO,
    else => @compileError("unsupported platform"),
};
```

Port TigerBeetle's `io/darwin.zig` (1093 lines) with surgical edits:
- Import path adjustment (same as linux.zig)
- Remove superblock zone check (not applicable)
- Everything else identical

Cross-compile: `zig build -Dtarget=aarch64-macos`

The `focus` binary works natively on both Linux and macOS.
No Docker in the dev path.

---

## Schema

Two problems, two solutions:

**Initialization** (tables don't exist yet): `focus schema apply`
**Schema changed** (tables exist with wrong shape): `focus schema reset`

### Commands

```
focus schema apply schema.sql --db tiger_web.db
```
Opens DB, runs schema.sql (`CREATE TABLE IF NOT EXISTS ...`). Idempotent.
Safe to run multiple times. Does nothing if tables already exist.
`focus dev` runs this automatically on startup.

```
focus schema reset --db tiger_web.db
```
Deletes the DB file, re-runs schema.sql. Destructive. Explicit.
User must type this command — never automatic.

### What happens when the user forgets

User edits schema.sql (adds a column), runs `focus dev`, handler
crashes. The error flows through the wire protocol to the adapter:

```
Error: no such column: done
  SQL: SELECT id, title, done FROM todos WHERE id = ?1
  Hint: schema.sql may have changed. Run: focus schema reset
```

The error message does the DX work. No magic, no auto-detection,
no surprise data loss. Just a clear instruction.

### Responsibility

- **Server:** `ensure_schema` for FRAMEWORK tables only (internal,
  versioned). Never touches user tables. Doesn't know they exist.
- **CLI:** `schema apply` (create user tables, idempotent) and
  `schema reset` (destroy + recreate, explicit).
- **User:** writes schema.sql, runs `schema reset` when they change
  it. Manages production migrations themselves (outside the framework).

### Why not auto-reset on schema change

Safety > DX. The user might have seed data, test fixtures, or hours
of manual testing state. Silently deleting it because they added a
column is hostile. An explicit command with a destructive name
(`reset`) makes the consequence obvious.

If we find a better pattern later (auto-reset with prompt, schema
diffing, etc.), we add it. For now: explicit, safe, good errors.

---

## Deployment

The framework has no opinion about where you run. Production is:

```
focus start src/ --schema schema.sql
```

Works on a VM, a laptop, a container, a Raspberry Pi. The framework
starts, serves, stops cleanly on SIGTERM. That's the contract.

### No Dockerfile by default

`focus new` does NOT scaffold a Dockerfile. Most early development
doesn't need containers. The user deploys however they want:

```bash
# Bare metal / VM
scp -r . server:myapp/
ssh server "cd myapp && focus start src/"

# Systemd
[Service]
ExecStart=/usr/local/bin/focus start src/ --schema schema.sql
WorkingDirectory=/opt/myapp
```

### `focus deploy --dockerfile` (on demand)

When the user decides they want a container image:

```
focus deploy --dockerfile
```

Generates a `Dockerfile` tailored to the project:
- Reads `.focus` to determine the start hook (which runtime)
- Detects package manager (package.json → Node, go.mod → Go, etc.)
- Picks minimal base image (debian-slim + runtime)
- Outputs a file the user owns, edits, commits

```dockerfile
# Generated by: focus deploy --dockerfile
# Edit freely — the framework won't overwrite this.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y libsqlite3-0 nodejs npm
COPY . /app
WORKDIR /app
RUN npm install --production && focus build src/
CMD ["focus", "start", "src/", "--schema", "schema.sql"]
```

The framework never touches this file again. It's yours.

### Why not scaffold by default (Rails' mistake)

Rails assumed Docker/Heroku from day one. This meant:
- Beginners hit Docker errors before writing a route
- The Dockerfile drifted from the app over time
- "deploy" became synonymous with "container"

Our position: deployment is the user's problem. We generate the
boilerplate when asked. Before that, `focus start src/` is deploy.
One binary, one sidecar process, one database file. No orchestrator.

---

## Installation

```
curl -sSf https://focus.dev/install.sh | sh
```

Downloads the pre-compiled binary for the user's platform
(linux-x86_64, linux-aarch64, darwin-aarch64, darwin-x86_64).
Puts it in `~/.focus/bin/` and adds to PATH.

Alternative: language package managers carry the binary
(like esbuild distributes via npm). But this is optional —
the curl install works for everyone.

---

## What the user remembers

```
focus new --ts myapp        ← once
cd myapp && focus dev src/  ← every day
focus docs                  ← when stuck
```

Three commands. No Docker. No config files to learn.
No package manager interaction for the framework.
Their code in `src/`, framework scaffold in `focus/`,
hooks in `.focus`, schema in `schema.sql`.

---

## Decisions log

| Decision | Reasoning |
|----------|-----------|
| `src/` as documentation default | Universal across languages, not enforced |
| `.focus` file for hooks | Simplest possible config (2 lines), no parser complexity |
| Adapter as files, not package | Works for all languages, no registry dependency |
| `focus dev` owns file watching | Framework primitive (inotify/kqueue in Zig) |
| `focus dev` does NOT own compilation | User's build hook — framework doesn't know their toolchain |
| No `focus.toml` | Two-line `.focus` file is sufficient |
| No `package.json` scripts scaffolded | Not all languages have package.json |
| Port kqueue, not Docker | Docker is deployment, not development |
| Server reads schema.sql | Owns the DB connection, no external sqlite3 process |
| CLI name is temporary | User writes it once, rename later is trivial |
| No language-level package | Adapter is vendored files, not external dependency |

---

## Native addon (TypeScript/Node.js)

The SHM protocol requires `mmap` (shared memory) and `futex_wake` (signal
the server). These are syscalls with no pure-JS equivalent in Node.js.

### Solution: ship C source, compile with zig cc

The addon is 60 lines of C (`focus/shm.c`). It does two things:
- `shm_open` + `mmap` → returns a Node Buffer backed by shared memory
- `futex_wake` → syscall to wake the server's poll

At scaffold time, `focus new --ts` compiles it:
```
zig cc -shared -o focus/shm.node focus/shm.c -I<node-headers> -lrt
```

No node-gyp. No python. No make. No g++. The Zig toolchain (already
installed for the server) is the C compiler.

### Platform differences

| Platform | Shared lib flag | Link flag | Header discovery |
|----------|----------------|-----------|-----------------|
| Linux x86_64 | `-shared` | `-lrt` | `node -e "console.log(process.config.variables.node_root_dir)"` |
| Linux aarch64 | `-shared` | `-lrt` | same |
| macOS x86_64 | `-dynamiclib` | (none) | same |
| macOS aarch64 | `-dynamiclib` | (none) | same |

`focus compile-addon` subcommand handles the detection and emits the
correct command. Runs once at scaffold time + any time the user changes
Node versions.

### When Node headers are missing

`focus compile-addon` checks for headers before compiling. If missing:
```
error: Node.js headers not found.
  nvm users: nvm install --reinstall-packages-from=current
  system:    apt install nodejs-dev (Debian) / brew install node (macOS)
  or:        use Bun (no addon needed)
```

### Bun/Deno: no addon needed

```typescript
// focus/shm.ts — runtime detection
const shm = typeof Bun !== 'undefined'
  ? Bun.mmap(path)
  : require('./shm.node').mmapShm(path, size);
```

Bun has native `Bun.mmap()`. Deno has FFI for mmap. Both eliminate
the C addon entirely. Same performance, zero compilation.

### The .node file is local-dev only

The scaffolded `shm.node` is compiled for the host platform.
Production builds (Dockerfile) recompile for the target:
```dockerfile
RUN focus compile-addon
```

The `.node` file is gitignored — each machine compiles its own.
The `.c` source is committed (60 lines, auditable).

### What focus/ contains for TypeScript

```
focus/
  shm.c              ← C source (60 lines), committed
  shm.node           ← compiled addon, gitignored
  sidecar.ts         ← SHM runtime (~400 lines)
  codegen.ts         ← manifest → handlers.generated.ts
  types.ts           ← SDK types (RouteRequest, etc.)
  serde.ts           ← binary row reader
```

---

## Primitives

### SHM name passing

The CLI starts the server, knows the PID, computes the SHM name
(`tiger-{pid}`), passes it to the start hook as `$SHM` environment
variable. One source of truth. The adapter reads `$SHM` — never
discovers or scans for it.

### Server binary — embedded in CLI

One binary. The server IS the CLI.

```
focus dev src/       ← runs server in-process
focus build src/     ← runs scanner in-process
focus start src/     ← runs server in-process (production)
focus schema apply   ← opens SQLite in-process
focus docs           ← prints embedded text
```

No shelling out to a separate `tiger-web` binary. Same pattern as
TigerBeetle: `tigerbeetle start`, `tigerbeetle format`, `tigerbeetle repl`.
One binary, different subcommands. Two binaries means two versions
to keep in sync.

The current `tiger-web` binary name in `build.zig` becomes `focus`.
One build target, one output.

### Database file location

Working directory. `./tiger_web.db` and `./tiger_web.wal` next to
the project. Not in a `data/` subdirectory.

- `.gitignore` excludes `*.db` and `*.wal`
- Two instances in different directories: no conflict
- Two instances in same directory: SQLite WAL mode handles it
  (concurrent readers, single writer, locking is SQLite's job)

Don't over-engineer this.

### SHM and socket cleanup

The process that creates the resource cleans it up.

**Clean shutdown (SIGTERM):** Server unlinks SHM + socket in signal
handler. Already implemented.

**Crash (stale files):** On next start, `shm_unlink` before
`shm_open(O_CREAT|O_EXCL)`. Already in the code. Socket: `unlink`
before `bind`. Already in the code.

No new work. The user never sees stale files because the server
always cleans up before creating.

### Socket path — PID-namespaced

The socket path must be unique per instance (same as SHM):

```
/tmp/tiger-{pid}.sock
```

Not a fixed path like `/tmp/tiger-web.sock`. Multiple projects
on one machine never conflict. The CLI computes the path, passes
it to the server and to the start hook as `$SOCK`.

### Testing

Not the framework's problem. Handler functions are pure:

```typescript
// Unit test — call the function directly
import { handle } from './src/create_post.ts';
const result = handle({ id: '...', prefetched: {}, body: { title: 'test' } }, mockDb);
assert(result === 'ok');
```

- `route()`: takes request, returns result. Testable.
- `prefetch()`: declares queries. Testable (check captured SQL).
- `handle()`: takes context + db, returns status. Testable with mock db.
- `render()`: takes context, returns HTML string. Testable.

Integration tests: start the server, curl it. Same as the smoke test.
No `focus test` command. No test framework. The user uses their
language's test runner (jest, go test, pytest).

### Multiple projects on one machine

Everything is PID-namespaced:
- SHM: `tiger-{pid}` (unique per server process)
- Socket: `/tmp/tiger-{pid}.sock` (unique per server process)
- Port: auto-selected (OS assigns, no conflicts)
- DB: in working directory (different projects = different dirs)

No coordination, no locking, no port registry. Run 10 projects
simultaneously — zero conflicts.

### Install and updates

```
curl -sSf https://focus.dev/install.sh | sh
```

The script:
1. Detects platform (linux-x86_64, linux-aarch64, darwin-aarch64, darwin-x86_64)
2. Downloads binary + `.sha256` checksum file
3. Verifies: `sha256sum -c focus.sha256`
4. Installs to `~/.focus/bin/focus`
5. Adds to PATH (prints instruction if shell doesn't auto-detect)

Updates:
```
focus self-update
```
Downloads latest binary, verifies checksum, replaces itself.
No auto-update. Explicit command. Same as `zig` distribution model.

Source: GitHub releases with checksums. No brew tap, no apt repo,
no npm global install. One download, one verify, done.

### Logging in dev

Three sources, one terminal stream, each labeled:

```
[server]  info: listening on http://localhost:4291
[sidecar] [shm] connected to tiger-8421
[watch]   rebuilt in 280ms, restarting sidecar
[sidecar] [shm] READY sent
[server]  info: sidecar slot 0 ready
```

Rules:
- Server logs to stderr with scoped prefixes (existing: `info(server):`)
- CLI prefixes server lines with `[server]`
- Sidecar stdout/stderr forwarded, prefixed with `[sidecar]`
- File watcher prints `[watch]` lines
- Colors: server=dim, sidecar=normal, watch=bold (terminal only)
- No interleaving without labels — user must know which process spoke
- `--quiet` suppresses server logs, shows only sidecar + watch

---

## Resolved questions

**Should `focus upgrade` exist?**
Yes. The adapter is vendored — user owns the files. When the protocol
changes, they need a path forward. `focus upgrade` diffs current adapter
against the new version, shows changes, user accepts or rejects. No
auto-update. Same as `go mod tidy`.

**Should the SHM name be auto-discovered by the adapter?**
No. Explicit argument. The `focus` CLI owns the lifecycle — it knows
the server PID, computes the SHM name (`tiger-{pid}`), passes it as
a CLI argument to the sidecar start hook. No scanning `/dev/shm/`.
A command-line argument IS the contract between the two processes.

**Should `focus dev` print structured output for IDE integration?**
Not now. Build for the terminal first. If an IDE wants integration
later, a `--json` flag is a 10-line addition. Don't design for it
until someone asks. YAGNI.

**Should adapter files be @embedFile'd or fetched from URL?**
`@embedFile`. Adapter is ~1500 lines across 5 files (~20KB). Embedding
has zero runtime cost. Fetching from URL adds: network dependency on
`focus new`, offline failure, CDN requirement, cache invalidation. TB
embeds everything. No external fetches for correctness-critical paths.

**macOS `shm_open` path differences?**
Non-issue. POSIX `shm_open("/tiger-123", ...)` works identically on
Linux and macOS. Linux maps to `/dev/shm/`, macOS maps to private
tmpfs. The path is opaque — adapter uses the POSIX name passed as
argument. Same code, both platforms.

**Can the SHM C addon be eliminated for Node?**
No. `SharedArrayBuffer` is process-local (threads only, not inter-process).
Worker threads with shared mmap still needs mmap (C). There is no pure-JS
path to inter-process shared memory in Node.js. The 60-line C addon is
the minimum viable primitive. Zig toolchain compiles it — no external
deps. Users who want zero native code use Bun (has `Bun.mmap()` natively).

**Should `.focus` hooks support environment variable expansion?**
Yes — `$SHM` and `$SOCK` are passed by the CLI to the start hook.
`focus dev` sets these in the environment before invoking the hook command.
No custom expansion logic — standard shell env vars via the subprocess
environment.

## Implementation order

### Done
- [x] Port io/darwin.zig from TigerBeetle (1 file, 2 line edits)
- [x] Platform switch in io.zig (comptime Linux/macOS)
- [x] CI: macOS runner added to GitHub Actions
- [x] All framework bug fixes committed (18 commits)
- [x] Extend typescript.ts — generates operations.ts as 4th output
- [x] Schema subcommand in main.zig (apply + reset, no default --db)
- [x] Write focus.zig — single Zig binary with new, build, dev
- [x] Scanner linked in-process (no subprocess)
- [x] Adapter templates @embedFile'd (13 files scaffolded)
- [x] Server embedded (server_run in background thread)
- [x] Schema embedded (cmd_schema called in-process)
- [x] Refactor server_run as composable library function (TB pattern)
- [x] validate_config_opts returns errors (not process.exit)
- [x] Allocator passed as parameter (not module-level global)
- [x] Delete shell scripts (focus, focus-internal)

### Next
- [x] File watcher: inotify on Linux, stat polling on macOS
- [x] Labeled output: [watch] from focus, scoped logs from server, [shm] from sidecar
- [ ] Move smoke test to ci.zig (delete shell script)
- [ ] Update Dockerfile (deployment only, remove shell references)

### Deferred (after CLI works)
- `focus self-update` (GitHub releases + checksum verification)
- `focus upgrade` (diff vendored adapter against new version)
- `focus deploy --dockerfile` (generate tailored Dockerfile)
- Wire protocol error encoding (prefetch_error in RESULT frames)
- install.sh (curl | sh distribution)

---

**How do SQL errors reach the user?**
The framework always includes errors in the wire protocol — no "dev mode"
flag, no mode awareness. When prefetch SQL fails, the RESULT frame includes
an error status + error message. The adapter reads this and passes it to
the handler's render context (e.g., `ctx.prefetch_error`). The adapter
decides presentation: in development, show the SQL error in the browser.
In production, show a generic 500. The server never decides how to
present errors — it just reports them through the wire format.
