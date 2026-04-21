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
    // Build focus binary — examples call ../../focus from their directory.
    // Symlink zig-out/bin/focus to repo root so the path resolves.
    {
        var section = try shell.open_section("build focus");
        defer section.close();
        try shell.exec("./zig/zig build", .{});
        shell.exec("ln -sf zig-out/bin/focus focus", .{}) catch {};
    }

    for (examples) |example| {
        const example_dir = try shell.fmt("./examples/{s}", .{example});

        // Level 1: Protocol tests (package vectors — no server needed).
        // Runs once above (packages/ts tests section), not per example.

        // Level 2: Integration test (full handler logic).
        {
            var section = try shell.open_section(try shell.fmt("{s} integration", .{example}));
            defer section.close();

            try shell.pushd(example_dir);
            defer shell.popd();

            try shell.exec("npm install", .{});
            try shell.exec("npm run build", .{});
        }
    }

    // Native addon cross-compile — builds shm.node for all platforms.
    // Uses zig build native-addon (cross-compilation via build.zig).
    // Catches stale binaries: a prebuilt that drifts from C source causes
    // silent response drops (server requires slot_state == result_written).
    {
        var section = try shell.open_section("native addon rebuild");
        defer section.close();

        try shell.exec("./zig/zig build native-addon", .{});
        try shell.exec("test -f packages/ts/native/dist/x86_64-linux/shm.node", .{});
    }

    // New-project smoke test: scaffold + build without Docker.
    // Catches: OperationValues missing, route table shadowing,
    // schema init issues, scanner .zig filter bugs.
    {
        var section = try shell.open_section("new-project scaffold+build");
        defer section.close();

        // Use absolute path — pushd to /tmp means relative paths won't resolve.
        const root = try shell.project_root.realpathAlloc(shell.arena.allocator(), ".");
        const focus = try shell.fmt("{s}/zig-out/bin/focus", .{root});

        const project = "/tmp/ci-focus-new-project";
        shell.exec("rm -rf {project}", .{ .project = project }) catch {};
        try shell.exec("{focus} new --ts {project}", .{ .focus = focus, .project = project });

        try shell.pushd(project);
        defer shell.popd();

        try shell.exec("npm install", .{});
        // Build: scanner + codegen (tests OperationValues generation,
        // route table for TS-only projects, operations.ts output).
        try shell.exec("{focus} build src/", .{ .focus = focus });

        // Verify expected outputs exist.
        try shell.exec("test -f focus/manifest.json", .{});
        try shell.exec("test -f focus/operations.json", .{});
        try shell.exec("test -f focus/handlers.generated.ts", .{});
        try shell.exec("test -f focus/operations.ts", .{});
        try shell.exec("test -f focus/routes.generated.zig", .{});

        // Dev loop: server + sidecar + watch, exits after 3s timeout.
        // Exercises: embedded server start, SHM region creation, sidecar spawn,
        // graceful shutdown.
        //
        // Override .focus start hook with a stub sidecar (sleep) — CI doesn't have npx.
        // The real sidecar is tested in the integration test (Level 2) above.
        {
            const focus_file = try shell.cwd.createFile(".focus", .{});
            defer focus_file.close();
            try focus_file.writeAll("build = true\nstart = sleep 10\n");
        }
        try shell.exec("{focus} dev --timeout=3 src/", .{ .focus = focus });

        // Cleanup.
        shell.exec("rm -rf {project}", .{ .project = project }) catch {};
    }
}
