# CLI consolidation — one entry point

## Problem

Commands are fragmented across three mechanisms:
- Zig binary: `tiger-web start`, `tiger-web trace`
- zig build targets: `zig build test`, `zig build bench`, `zig build load`, `zig build scan`
- Shell scripts: `tiger-web dev` (shell), `scripts/loadtest.sh`

A new user can't discover available commands from one place. They
need to know which mechanism runs which command. TB has one CLI
(`tigerbeetle start`, `tigerbeetle benchmark`). We should too.

## Target CLI

```
tiger-web start [options] [-- sidecar-command...]
tiger-web dev [options]
tiger-web trace --max=<size> :<port>
tiger-web build
tiger-web test
tiger-web bench
tiger-web load [options]
tiger-web scan <handlers-dir>
tiger-web init <project-name>
```

### Command descriptions

| Command | What it does | Current mechanism |
|---|---|---|
| `start` | Run the server | Zig binary (exists) |
| `dev` | File watch + auto-compile + sidecar restart | Shell script (exists, moves to Zig) |
| `trace` | Attach to running server, capture trace | Zig binary (exists) |
| `build` | Codegen + scan annotations + generate dispatch | `npm run build` (moves to Zig orchestration) |
| `test` | Unit + sim + fuzz smoke | `zig build test` (wraps) |
| `bench` | Micro-benchmark (budget assertions) | `zig build bench` (wraps) |
| `load` | HTTP throughput with orphan safety | `scripts/loadtest.sh` (moves to Zig) |
| `scan` | Validate handler annotations | `zig build scan` (wraps) |
| `init` | Scaffold new project | New |

### What runs under the hood

`dev`, `build`, `test`, `bench`, `load`, `scan` shell out to
`zig build` or `npx`. The user never types `zig build` directly.
Same pattern as `cargo test`, `next build`, `go test`.

`start` and `trace` are native Zig (no shelling out). These are
the production commands — no build system dependency.

### Help output

```
Usage: tiger-web <command> [options]

Commands:
  start   Run the server
  dev     Start dev server with file watching + auto-restart
  trace   Attach to a running server, capture a Chrome Tracing file
  build   Codegen + validate annotations + generate dispatch
  test    Run unit, simulation, and fuzz tests
  bench   Micro-benchmark with budget assertions
  load    HTTP throughput benchmark
  scan    Validate handler annotations
  init    Scaffold a new project

Run 'tiger-web <command> --help' for command-specific options.
```

## Implementation strategy

### Phase 1: Wrap existing mechanisms (minimal change)

Add subcommands to the Zig binary that shell out:
- `test` → `std.process.Child.init(.{"./zig/zig", "build", "test"})`
- `bench` → `std.process.Child.init(.{"./zig/zig", "build", "bench"})`
- `scan` → `std.process.Child.init(.{"./zig/zig", "build", "scan", ...})`
- `load` → inline the loadtest.sh logic in Zig

No behavior change — same tools, unified entry point.

### Phase 2: Move shell scripts to Zig

- `dev`: file watcher (inotify) + zig build + sidecar restart.
  The Zig server stays running, only the sidecar restarts on
  handler changes. Faster than Next.js full-bundle recompile.
- `build`: run scanner + codegen. Currently `npm run build`
  calls the scanner and TypeScript adapter. Move orchestration
  to Zig, keep the adapter as a child process.

### Phase 3: `init` scaffolding

Generate project structure:
```
my-app/
  handlers/
    get_product.ts
  generated/
  CLAUDE.md (or equivalent config)
```

Template-based. No runtime dependency — just file creation.

## Trigger

First external user. Until then, the fragmented CLI works for us
and the mechanisms are transparent. Consolidating prematurely adds
a wrapper layer that obscures what's actually running.

## Licensing consideration

In VC-driven open source, the CLI is often the monetization seam:
- **Framework/runtime**: open source (MIT/Apache), drives adoption
- **CLI/tooling**: source-available or closed source, drives revenue
  (Vercel's `next` CLI, Netlify CLI, PlanetScale CLI, Turbo)
- **Cloud hosting**: the actual business, CLI is the funnel

Pattern: the server (`tiger-web start`) is open source. The dev
tooling (`dev`, `build`, `init`, `trace`) could be source-available
or proprietary. The CLI is the developer's daily touchpoint — it's
what creates lock-in and justifies pricing.

Decision: defer. Build it open source first. If monetization
matters later, the CLI is a natural split point because it's a
single binary with clear command boundaries. `start` stays open,
`dev`/`build`/`init` become the paid tier. Or keep everything
open and monetize hosting (TB's model: open source DB, paid cloud).

## Non-goals

- No internal vs external CLI split. One CLI, one audience.
- No hiding commands. `fuzz` is a subcommand, just not in the
  summary help. Power users find it via `tiger-web fuzz --help`.
- No plugin system. Commands are compiled into the binary.
