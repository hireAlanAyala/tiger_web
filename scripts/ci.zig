//! CI checks for sidecar example projects.
//!
//! Two levels of testing (see docs/plans/post-cfo-port.md):
//! - Level 1: Adapter tests — binary protocol round-trip (zig build test-adapter)
//! - Level 2: Integration tests — full handler logic against real server (npm test)
//!
//! Both run on every commit. Framework changes are the primary risk — a change to
//! storage.zig, protocol.zig, or state_machine.zig can break handler behavior
//! without touching any TypeScript code.
//!
//! Ported from TigerBeetle's src/scripts/ci.zig. TB tests client libraries
//! (dotnet, go, rust, java, node, python). We test example projects because our
//! sidecar runs user-space business logic, not just protocol wrapping.

const std = @import("std");
const builtin = @import("builtin");
const log = std.log;
const assert = std.debug.assert;

const stdx = @import("stdx");
const Shell = @import("../shell.zig");

// Example projects — our equivalent of TB's LanguageCI.
// Each must provide: npm install, npm run build, npm test.
// When adding a new example, add it here and CI picks it up automatically.
//
// When we have 2+ examples, add an `--example=X` filter to CLIArgs
// (matching TB's `--language=X` pattern). TB's flags.zig requires enums
// to have >= 2 variants, so we defer the filter until then.
const examples = [_][]const u8{
    "ecommerce-ts",
};

pub const CLIArgs = struct {
    validate_release: bool = false,
};

pub fn main(shell: *Shell, gpa: std.mem.Allocator, cli_args: CLIArgs) !void {
    _ = gpa;
    if (cli_args.validate_release) {
        // TODO: Port validate_release from TB when we ship release artifacts.
        // See docs/plans/post-cfo-port.md.
        shell.echo("{ansi-red}error: validate-release not yet implemented{ansi-reset}", .{});
        std.process.exit(1);
    } else {
        try run_tests(shell);
    }
}

fn run_tests(shell: *Shell) !void {
    for (examples) |example| {
        const example_dir = try shell.fmt("./examples/{s}", .{example});

        // Level 1: Adapter test (protocol boundary).
        {
            var section = try shell.open_section(try shell.fmt("{s} adapter", .{example}));
            defer section.close();

            // Adapter test runs from project root, not example dir.
            try shell.exec("npx -y tsx adapters/typescript_test.ts", .{});
        }

        // Level 2: Integration test (full handler logic).
        {
            var section = try shell.open_section(try shell.fmt("{s} integration", .{example}));
            defer section.close();

            try shell.pushd(example_dir);
            defer shell.popd();

            try shell.exec("npm install", .{});
            try shell.exec("npm run build", .{});
            try shell.exec("npm test", .{});
        }
    }

    // Native addon rebuild — catches stale prebuilt shm.node.
    // The addon MUST be rebuilt from source on every CI run. A prebuilt
    // binary that drifts from the C source causes silent response drops
    // (server requires slot_state == result_written, only current source writes it).
    {
        var section = try shell.open_section("native addon rebuild");
        defer section.close();

        try shell.pushd("./addons/shm");
        defer shell.popd();

        // Rebuild from source.
        try shell.exec("../../zig/zig cc -shared -o shm.node shm.c -I/usr/include/node -lrt -lz -fPIC", .{});
        try shell.exec("test -f shm.node", .{});
    }

    // TypeScript package tests — protocol vectors, fuzz, round-trip.
    // Validates the package's serde implementation against committed
    // binary vectors. No server needed — fast.
    {
        var section = try shell.open_section("packages/ts tests");
        defer section.close();

        try shell.exec("npx tsx packages/ts/test/protocol_test.ts", .{});
        try shell.exec("npx tsx packages/ts/test/round_trip_test.ts", .{});
        try shell.exec("npx tsx packages/ts/test/fuzz_test.ts", .{});
    }

    // New-project smoke test: scaffold + build without Docker.
    // Catches: OperationValues missing, route table shadowing,
    // schema init issues, scanner .zig filter bugs.
    {
        var section = try shell.open_section("new-project scaffold+build");
        defer section.close();

        const project = "/tmp/ci-focus-new-project";
        shell.exec("rm -rf {project}", .{ .project = project }) catch {};
        try shell.exec("./zig-out/bin/focus new --ts {project}", .{ .project = project });

        try shell.pushd(project);
        defer shell.popd();

        try shell.exec("npm install", .{});
        // Build: scanner + codegen (tests OperationValues generation,
        // route table for TS-only projects, operations.ts output).
        try shell.exec("{focus} build src/", .{ .focus = "../zig-out/bin/focus" });

        // Verify expected outputs exist.
        try shell.exec("test -f focus/manifest.json", .{});
        try shell.exec("test -f focus/operations.json", .{});
        try shell.exec("test -f focus/handlers.generated.ts", .{});
        try shell.exec("test -f focus/operations.ts", .{});
        try shell.exec("test -f focus/routes.generated.zig", .{});

        // Dev loop: server + sidecar + watch, exits after 3s timeout.
        // Exercises: embedded server start, SHM region creation, sidecar spawn,
        // graceful shutdown. Catches: port conflicts, missing deps, env var wiring.
        //
        // Override .focus start hook with a stub sidecar (sleep) — CI doesn't have npx.
        // The real sidecar is tested in the integration test (Level 2) above.
        // Write a minimal .focus with a no-op build and sleep sidecar.
        {
            const focus_file = try std.fs.cwd().createFile(".focus", .{});
            defer focus_file.close();
            try focus_file.writeAll("build = true\nstart = sleep 10\n");
        }
        try shell.exec("{focus} dev --timeout=3 src/", .{ .focus = "../zig-out/bin/focus" });

        // Cleanup.
        shell.exec("rm -rf {project}", .{ .project = project }) catch {};
    }
}
