# Decision: Direct imports with stdx as a build module

## Status: Adopted (2026-03-26)

## Context

TigerBeetle imports `stdx` as a build.zig module (`@import("stdx")`) in every
compilation unit. Every other dependency is imported by direct file path
(`@import("shell.zig")`, `@import("../shell.zig")`). There is no re-export
layer.

We originally had `framework/lib.zig` — a file that re-exported stdx, flags,
prng, and all framework modules. Every root-level file did
`@import("framework/lib.zig").something`. This diverged from TB's pattern and
caused two problems:

1. **`@src().file` path mismatch.** When Zig compiles a file via module import,
   `@src().file` returns a path relative to the module root. When compiled via
   direct `@import("path/to/file.zig")`, it returns a path relative to the
   compilation root. TB's Snap test framework and the flags self-compilation
   test both use `@src().file` to locate source files. With the re-export
   layer, stdx was compiled via direct path in some compilation units and via
   module in others, producing different `@src().file` results for the same
   file. Tests failed because paths doubled (`framework/stdx/framework/stdx/flags.zig`).

2. **API wrapping.** TB exports `stdx.flags` as the parse function directly
   (`pub const flags = @import("flags.zig").parse`). Our callers did
   `flags.parse(...)`. The re-export layer had to wrap this:
   `pub const flags = struct { pub const parse = stdx.flags; }`. This kind
   of adapter exists only because of the indirection layer. Remove the layer,
   remove the adapter.

## Decision

- **`stdx` is always imported as a build.zig module**: `@import("stdx")`.
  Every executable, test step, and compilation unit in build.zig gets
  `root_module.addImport("stdx", stdx_module)`. This matches TB exactly.

- **Framework modules are imported by direct file path**:
  `@import("framework/server.zig")`, `@import("framework/auth.zig")`, etc.
  No re-export layer. Each file imports only what it uses.

- **No `framework/lib.zig`**. Deleted. If a file needs auth and marks, it
  imports both. This is explicit — you can grep for `@import("framework/auth.zig")`
  and find every user.

- **`stdx.flags` is called directly**: `stdx.flags(&args, CLIArgs)`, not
  `flags.parse(&args, CLIArgs)`. TB designed it this way — the `flags` export
  IS the parse function.

- **`stdx.PRNG` is the PRNG type**: `const PRNG = @import("stdx").PRNG`.
  Matches TB's `const PRNG = @import("stdx").PRNG`.

## Why TB does it this way

TB's comment in their build.zig says stdx is "independent from the rest of the
codebase." Module wiring makes this real:

- **Module boundary isolation.** `@src().file` paths are relative to the module
  root, not the project root. Snap tests, self-compilation tests, and any code
  that locates its own source files work consistently regardless of where in
  the project tree the file lives.

- **No diamond imports.** When two compilation paths reach the same file,
  Zig may compile it twice with different `@src()` contexts. Module wiring
  ensures one canonical compilation per file.

- **Flat namespace.** TB's stdx.zig re-exports everything: `pub const PRNG`,
  `pub const Duration`, `pub const flags`, `pub const BitSetType`. One import
  (`@import("stdx")`) gives you the full toolkit. No hierarchy to navigate.

- **Separate `std_options` per compilation unit.** The main server, scripts
  executable, fuzz dispatcher, and sim tests each have their own log config.
  Module wiring means stdx is compiled once per compilation unit with that
  unit's `std_options` — correct by construction.

## Consequences

- Every new executable or test step in build.zig must include
  `exe.root_module.addImport("stdx", stdx_module)`.
- Every test run step must include
  `run.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe)` for the flags
  self-compilation test.
- Framework files within `framework/` import stdx as `@import("stdx")` (module),
  not `@import("stdx/stdx.zig")` (path). The module wiring resolves this.
- Adding a new framework module is: create the file, import it directly where
  needed. No registration step.
