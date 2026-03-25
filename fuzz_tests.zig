//! Fuzz test dispatcher — single binary routing to all fuzzers.
//!
//! Matches TigerBeetle's fuzz_tests.zig pattern: one binary, subcommand
//! selects the fuzzer, --seed and --events-max are common flags.
//!
//! Usage:
//!   zig build fuzz -- state_machine 12345               # specific seed
//!   zig build fuzz -- --events-max=100000 state_machine  # with options
//!   zig build fuzz -- state_machine                     # random seed
//!   zig build fuzz -- smoke                             # all fuzzers, small event counts

const std = @import("std");
const assert = std.debug.assert;
const flags = @import("tiger_framework").flags;
const fuzz = @import("fuzz_lib.zig");

const log = std.log.scoped(.fuzz);

const Fuzzers = .{
    .state_machine = @import("fuzz.zig"),
    .replay = @import("replay_fuzz.zig"),
    .sidecar = @import("sidecar_fuzz.zig"),
    .row_format = @import("row_format_fuzz.zig"),
    // Quickly run all fuzzers as a smoke test
    .smoke = {},
};

const FuzzersEnum = std.meta.FieldEnum(@TypeOf(Fuzzers));

const CLIArgs = struct {
    events_max: ?usize = null,

    @"--": void,
    fuzzer: FuzzersEnum,
    seed: ?u64 = null,
};

pub fn main() !void {
    var args = std.process.args();
    const cli_args = flags.parse(&args, CLIArgs);

    switch (cli_args.fuzzer) {
        .smoke => {
            assert(cli_args.seed == null);
            assert(cli_args.events_max == null);
            try main_smoke();
        },
        else => try main_single(cli_args),
    }
}

fn main_smoke() !void {
    var timer_all = try std.time.Timer.start();
    inline for (comptime std.enums.values(FuzzersEnum)) |fuzzer| {
        const events_max: ?usize = switch (fuzzer) {
            .smoke => continue,
            .state_machine => 10_000,
            .replay => 5_000,
            .sidecar => 5_000,
            .row_format => 10_000,
        };

        var timer_single = try std.time.Timer.start();
        try @field(Fuzzers, @tagName(fuzzer)).main(std.heap.page_allocator, .{
            .seed = 123,
            .events_max = events_max,
        });
        const fuzz_duration = timer_single.lap();
        if (fuzz_duration > 10 * std.time.ns_per_s) {
            log.err("fuzzer too slow for smoke mode: " ++ @tagName(fuzzer) ++ " {}", .{
                std.fmt.fmtDuration(fuzz_duration),
            });
        }
    }

    log.info("done in {}", .{std.fmt.fmtDuration(timer_all.lap())});
}

fn main_single(cli_args: CLIArgs) !void {
    assert(cli_args.fuzzer != .smoke);

    const seed = cli_args.seed orelse std.crypto.random.int(u64);
    log.info("Fuzz seed = {}", .{seed});

    var timer = try std.time.Timer.start();
    switch (cli_args.fuzzer) {
        .smoke => unreachable,
        inline else => |fuzzer| try @field(Fuzzers, @tagName(fuzzer)).main(std.heap.page_allocator, .{
            .seed = seed,
            .events_max = cli_args.events_max,
        }),
    }
    log.info("done in {}", .{std.fmt.fmtDuration(timer.lap())});
}
