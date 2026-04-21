//! TypeScript package CI — build, test, verify.
//!
//! Runs as part of the root CI (scripts/ci.zig calls this).
//! Three test levels:
//!   1. Protocol vectors (no server needed — fast)
//!   2. Fuzz + round-trip (no server needed — fast)
//!   3. SHM integration (spawns server — slow)

const std = @import("std");
const Shell = @import("../../shell.zig");

pub fn run(shell: *Shell) !void {
    // Type-check the package.
    {
        var section = try shell.open_section("packages/ts type-check");
        defer section.close();

        try shell.pushd("./packages/ts");
        defer shell.popd();

        try shell.exec("npx tsc --noEmit", .{});
    }

    // Protocol vector tests — validates serde against committed vectors.
    {
        var section = try shell.open_section("packages/ts protocol vectors");
        defer section.close();

        try shell.exec("npx tsx packages/ts/test/protocol_test.ts", .{});
    }

    // Round-trip tests — build/parse frames, validate against vectors.
    {
        var section = try shell.open_section("packages/ts round-trip");
        defer section.close();

        try shell.exec("npx tsx packages/ts/test/round_trip_test.ts", .{});
    }

    // Fuzz test — random bytes, assert no crash.
    {
        var section = try shell.open_section("packages/ts fuzz");
        defer section.close();

        try shell.exec("npx tsx packages/ts/test/fuzz_test.ts", .{});
    }
}
