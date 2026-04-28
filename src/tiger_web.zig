//! tiger-web public module root.
//!
//! Mirrors TigerBeetle's `src/vsr.zig` pattern: a single module file
//! that re-exports the public API surface. Other binaries (the focus
//! codegen CLI at root) import via `@import("tiger_web").X` rather
//! than reaching into individual files via relative paths.
//!
//! TB's `src/vsr.zig` line 7: *"vsr.zig is the root of a zig package,
//! reexport all public APIs. Note that we don't promise any stability
//! of these interfaces yet."* Same disclaimer applies here.

pub const main = @import("main.zig");
pub const scanner = @import("annotation_scanner.zig");
