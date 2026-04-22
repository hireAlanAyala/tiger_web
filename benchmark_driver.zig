//! `tiger-web benchmark` — closed-loop HTTP load driver.
//!
//! **Port source:** pattern-transplant from TigerBeetle's
//! `src/tigerbeetle/benchmark_driver.zig` + `src/tigerbeetle/benchmark_load.zig`.
//! Neither is whole-file cp-able — TB's driver spawns a `tigerbeetle`
//! child process and hands VSR `io/time` refs to the load module; our
//! driver runs against an already-running server over HTTP, no child
//! process, no VSR. See DR-3 in
//! `docs/internal/decision-benchmark-tracking.md`.
//!
//! D.1 state (this commit): CLI skeleton. Validates args, prints them,
//! returns an unimplemented error. D.2/D.3 will replace `run` with
//! the actual load generator (histogram + percentile walk
//! transplanted from TB with passage citations; HTTP client loop +
//! warmup written fresh for our domain).

const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.benchmark);

const BenchmarkArgs = @import("main.zig").BenchmarkArgs;

pub fn run(gpa: std.mem.Allocator, cli: BenchmarkArgs) !void {
    _ = gpa;
    assert(cli.port > 0);
    assert(cli.connections > 0);
    assert(cli.requests > 0);

    log.info(
        "benchmark (D.1 skeleton): port={d} connections={d} requests={d} warmup={d}s ops={s}",
        .{ cli.port, cli.connections, cli.requests, cli.@"warmup-seconds", cli.ops },
    );
    log.err("benchmark load generator not yet implemented (Phase D.2/D.3)", .{});
    return error.NotYetImplemented;
}
