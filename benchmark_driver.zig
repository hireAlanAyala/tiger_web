//! `tiger-web benchmark` — CLI entry for the SLA-tier load generator.
//!
//! Thin orchestrator. CLI arg validation + dispatch to
//! `benchmark_load.zig`. Kept separate from `benchmark_load.zig` so
//! the loader is reusable by future sim/replay callers without the
//! stdout-driver boilerplate.
//!
//! **Port source:** shape from TigerBeetle
//! `src/tigerbeetle/benchmark_driver.zig`. TB's driver spawns a
//! `tigerbeetle` child process, hands VSR `io`/`time` refs to
//! `benchmark_load.command_benchmark`. Our driver is much simpler —
//! the server is an already-running HTTP process we connect to by
//! port. No child process, no VSR.

const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.benchmark);

const BenchmarkArgs = @import("main.zig").BenchmarkArgs;
const benchmark_load = @import("benchmark_load.zig");

pub fn run(gpa: std.mem.Allocator, cli: BenchmarkArgs) !void {
    assert(cli.port > 0);
    assert(cli.connections > 0);
    assert(cli.requests > 0);

    try benchmark_load.run(gpa, cli);
}
