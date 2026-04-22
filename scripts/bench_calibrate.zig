//! Benchmark calibration helper.
//!
//! Runs each benchmark configuration 3 times and prints the raw
//! per-run measurements in a format that can be spliced into
//! `docs/internal/benchmark-budgets.md`.
//!
//! Why this exists: the budgets doc records observed ns per bench
//! across 3 runs, and the budget constants in each `*_benchmark.zig`
//! file are `10 × max(runs)` rounded up. Without automation, a
//! recalibration pass is tedious and error-prone. With this script,
//! a recalibration is one invocation.
//!
//! Usage:
//!   ./zig/zig build scripts -- bench-calibrate
//!
//! The script does NOT mutate the budgets doc or the bench file
//! constants. It prints; a human reads and updates. Separation
//! keeps the mutation step a deliberate act, not an accident.
//!
//! Phase F will run this on the `ubuntu-22.04` runner to produce
//! CI-calibrated budgets that replace the current dev-machine ones.

const std = @import("std");

const Shell = @import("../shell.zig");

pub const CLIArgs = struct {};

const runs = 3;

// Three bench configurations cover all six benches. The
// fixed-input benches (crc_frame, hmac_session, wal_parse,
// route_match) produce the same numbers in smoke and benchmark
// mode, so a standard `zig build bench` suffices. Aegis and
// state_machine take size parameters; smoke-equivalent inputs must
// be forced via env var for their rows to calibrate smoke-mode
// budgets.
const EnvVar = struct {
    key: []const u8,
    value: []const u8,
};

const Config = struct {
    name: []const u8,
    env: []const EnvVar,
    measurement_lines: []const []const u8,
};

const configs = [_]Config{
    .{
        .name = "default (crc_frame, hmac_session, wal_parse, route_match)",
        .env = &.{},
        .measurement_lines = &.{
            "crc_frame_64 = ",
            "crc_frame_256 = ",
            "crc_frame_1024 = ",
            "crc_frame_4096 = ",
            "crc_frame_65536 = ",
            "hmac_session = ",
            "wal_parse = ",
            "route_match = ",
        },
    },
    .{
        .name = "aegis_checksum (blob_size=1024, smoke-equivalent)",
        .env = &.{.{ .key = "blob_size", .value = "1024" }},
        .measurement_lines = &.{"aegis_checksum = "},
    },
    .{
        .name = "state_machine (entity_count=10 ops=50, smoke-equivalent)",
        // Both env vars required — `entity_count` shrinks the seeded
        // product count, `ops` shrinks the per-bench inner loop.
        // Setting only one produced a hybrid (entity_count=10,
        // ops=5000) that matched neither smoke nor benchmark mode
        // and skewed state_machine numbers.
        .env = &.{
            .{ .key = "entity_count", .value = "10" },
            .{ .key = "ops", .value = "50" },
        },
        .measurement_lines = &.{
            "get_product = ",
            "list_products = ",
            "update_product = ",
        },
    },
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, _: CLIArgs) !void {
    shell.echo("# Benchmark calibration run — {s}", .{@tagName(@import("builtin").os.tag)});
    shell.echo("# Splice the per-line observations into `docs/internal/benchmark-budgets.md`.", .{});
    shell.echo("# Budget constants in each *_benchmark.zig file = 10 x max(runs) rounded up.", .{});
    shell.echo("", .{});

    for (configs) |config| {
        shell.echo("## {s}", .{config.name});
        shell.echo("", .{});

        for (0..runs) |i| {
            const captured = run_bench(shell, gpa, config) catch |err| {
                shell.echo("  run {d}: FAILED ({s})", .{ i + 1, @errorName(err) });
                continue;
            };
            // Shell's arena owns the captured bytes; no explicit free.
            // bench.report writes to stderr via std.debug.print — the
            // measurement lines are in captured[1], not stdout.
            const bench_output = captured[1];

            shell.echo("### run {d}", .{i + 1});
            for (config.measurement_lines) |needle| {
                if (find_line(bench_output, needle)) |line| {
                    shell.echo("  {s}", .{line});
                }
            }
            shell.echo("", .{});
        }
    }
}

fn run_bench(shell: *Shell, gpa: std.mem.Allocator, config: Config) !struct { []const u8, []const u8 } {
    _ = gpa;
    // Shell's child_env_map is shell.env (see shell.zig:531). Putting
    // overrides there propagates to every subsequent exec. We set
    // before the build, and clean up after (including on error) so
    // consecutive configs don't leak overrides.
    for (config.env) |ev| {
        try shell.env.put(ev.key, ev.value);
    }
    defer for (config.env) |ev| shell.env.remove(ev.key);

    return shell.exec_stdout_stderr("./zig/zig build bench", .{});
}

fn find_line(haystack: []const u8, needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, haystack, needle) orelse return null;
    const end_offset = std.mem.indexOfScalar(u8, haystack[start..], '\n') orelse haystack.len - start;
    return haystack[start .. start + end_offset];
}
