const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const print_exe = b.option(bool, "print-exe", "Build tasks print the path of the executable") orelse false;

    // stdx module — all compilation units use @import("stdx"), matching TB's pattern.
    // Each compilation unit has its own std_options (root owns log config), but stdx
    // is shared via module wiring so @src().file paths resolve correctly for Snap tests.
    const stdx_module = b.addModule("stdx", .{
        .root_source_file = b.path("framework/stdx/stdx.zig"),
    });

    // --- Build options ---
    const sidecar_enabled = b.option(bool, "sidecar", "Enable sidecar handler mode") orelse false;
    const sidecar_count: u8 = b.option(u8, "sidecar-count", "Number of sidecar connections (default 1)") orelse 1;
    const build_options = b.addOptions();
    build_options.addOption(bool, "sidecar_enabled", sidecar_enabled);
    build_options.addOption(u8, "sidecar_count", sidecar_count);

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "tiger-web",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("stdx", stdx_module);
    exe.root_module.addOptions("build_options", build_options);
    exe.linkSystemLibrary("sqlite3");
    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);

    // --- Worker executable ---
    const worker_exe = b.addExecutable(.{
        .name = "tiger-worker",
        .root_source_file = b.path("worker.zig"),
        .target = target,
        .optimize = optimize,
    });
    worker_exe.root_module.addImport("stdx", stdx_module);
    b.installArtifact(worker_exe);

    const worker_cmd = b.addRunArtifact(worker_exe);
    worker_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| worker_cmd.addArgs(args);
    const worker_step = b.step("run-worker", "Run the worker process");
    worker_step.dependOn(&worker_cmd.step);

    // --- Load test ---
    const load_exe = b.addExecutable(.{
        .name = "tiger-load",
        .root_source_file = b.path("load_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    load_exe.root_module.addImport("stdx", stdx_module);
    load_exe.linkLibC();
    b.installArtifact(load_exe);

    const load_cmd = b.addRunArtifact(load_exe);
    load_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| load_cmd.addArgs(args);
    const load_step = b.step("load", "Run HTTP load test");
    load_step.dependOn(&load_cmd.step);

    // --- Replay tool ---
    const replay_exe = b.addExecutable(.{
        .name = "tiger-replay",
        .root_source_file = b.path("replay.zig"),
        .target = target,
        .optimize = optimize,
    });
    replay_exe.root_module.addImport("stdx", stdx_module);
    replay_exe.linkSystemLibrary("sqlite3");
    replay_exe.linkLibC();
    b.installArtifact(replay_exe);

    const replay_cmd = b.addRunArtifact(replay_exe);
    replay_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| replay_cmd.addArgs(args);
    const replay_step = b.step("replay", "Run the replay tool");
    replay_step.dependOn(&replay_cmd.step);

    // --- Simulation tests ---
    const sim_tests = b.addTest(.{
        .root_source_file = b.path("sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_tests.root_module.addImport("stdx", stdx_module);
    sim_tests.root_module.addOptions("build_options", build_options);
    sim_tests.linkSystemLibrary("sqlite3");
    sim_tests.linkLibC();
    const run_sim_tests = b.addRunArtifact(sim_tests);
    run_sim_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    const test_step = b.step("test", "Run simulation tests");
    test_step.dependOn(&run_sim_tests.step);

    // --- Sidecar simulation tests ---
    // Separate binary with sidecar_enabled = true. Exercises the full
    // sidecar pipeline (route → prefetch → handle → render) through
    // the real Server + SM + MessageBus stack with SimSidecar driving
    // the CALL/RESULT protocol deterministically.
    const sidecar_sim_options = b.addOptions();
    sidecar_sim_options.addOption(bool, "sidecar_enabled", true);
    sidecar_sim_options.addOption(u8, "sidecar_count", 2);

    const sidecar_sim = b.addTest(.{
        .root_source_file = b.path("sim_sidecar.zig"),
        .target = target,
        .optimize = optimize,
    });
    sidecar_sim.root_module.addImport("stdx", stdx_module);
    sidecar_sim.root_module.addOptions("build_options", sidecar_sim_options);
    sidecar_sim.linkSystemLibrary("sqlite3");
    sidecar_sim.linkLibC();
    const run_sidecar_sim = b.addRunArtifact(sidecar_sim);
    run_sidecar_sim.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    const sidecar_test_step = b.step("test-sidecar", "Run sidecar simulation tests");
    sidecar_test_step.dependOn(&run_sidecar_sim.step);

    // --- Fuzz test dispatcher ---
    const fuzz_exe = b.addExecutable(.{
        .name = "tiger-fuzz",
        .root_source_file = b.path("fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_exe.root_module.addImport("stdx", stdx_module);
    fuzz_exe.root_module.addOptions("build_options", build_options);
    fuzz_exe.linkSystemLibrary("sqlite3");
    fuzz_exe.linkLibC();
    b.installArtifact(fuzz_exe);

    const fuzz_cmd = b.addRunArtifact(fuzz_exe);
    fuzz_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| fuzz_cmd.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&fuzz_cmd.step);

    // --- Fuzz build-only step (used by CFO to build without running) ---
    // With -Dprint-exe, prints the executable path to stdout (CFO captures this
    // to spawn the binary directly, excluding build time from seed duration).
    const fuzz_build_step = b.step("fuzz:build", "Build fuzz test binary");
    fuzz_build_step.dependOn(print_or_install(b, fuzz_exe, print_exe));

    // --- Scripts executable (CFO and other automation) ---
    const scripts_exe = b.addExecutable(.{
        .name = "tiger-scripts",
        .root_source_file = b.path("scripts.zig"),
        .target = target,
        .optimize = .Debug,
    });
    scripts_exe.root_module.addImport("stdx", stdx_module);
    b.installArtifact(scripts_exe);

    const scripts_cmd = b.addRunArtifact(scripts_exe);
    scripts_cmd.step.dependOn(b.getInstallStep());
    scripts_cmd.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    if (b.args) |args| scripts_cmd.addArgs(args);
    const scripts_step = b.step("scripts", "Run automation scripts");
    scripts_step.dependOn(&scripts_cmd.step);

    // --- Annotation scanner ---
    const scanner_exe = b.addExecutable(.{
        .name = "annotation-scanner",
        .root_source_file = b.path("annotation_scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    scanner_exe.root_module.addImport("stdx", stdx_module);
    b.installArtifact(scanner_exe);

    const scanner_cmd = b.addRunArtifact(scanner_exe);
    if (b.args) |args| {
        scanner_cmd.addArgs(args);
    } else {
        scanner_cmd.addArg("handlers/");
    }
    const scanner_step = b.step("scan", "Scan handlers for annotation and status exhaustiveness");
    scanner_step.dependOn(&scanner_cmd.step);

    // --- Unit tests for individual modules ---
    const modules = [_][]const u8{
        "message.zig",
        "framework/message_pool.zig",
        "wal_test.zig",
        "annotation_scanner.zig",
        "supervisor.zig",
    };
    const unit_test_step = b.step("unit-test", "Run unit tests");
    for (modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.root_module.addOptions("build_options", build_options);
        const run_unit_test = b.addRunArtifact(unit_test);
        run_unit_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_unit_test.step);
    }

    // Modules that need libc (socketpair for tests) but not sqlite.
    for ([_][]const u8{ "framework/message_bus.zig", "sidecar_handlers.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.root_module.addOptions("build_options", build_options);
        unit_test.linkLibC();
        const run_ut = b.addRunArtifact(unit_test);
        run_ut.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_ut.step);
    }

    // Modules that need sqlite3 + libc.
    for ([_][]const u8{ "storage.zig", "replay.zig", "state_machine_test.zig", "sidecar.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.root_module.addOptions("build_options", build_options);
        unit_test.linkSystemLibrary("sqlite3");
        unit_test.linkLibC();
        const run_ut = b.addRunArtifact(unit_test);
        run_ut.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_ut.step);
    }

    // Load gen tests (needs libc for posix sockets, no sqlite3).
    {
        const load_test = b.addTest(.{
            .root_source_file = b.path("load_gen.zig"),
            .target = target,
            .optimize = optimize,
        });
        load_test.root_module.addImport("stdx", stdx_module);
        load_test.root_module.addOptions("build_options", build_options);
        load_test.linkLibC();
        const run_load_test = b.addRunArtifact(load_test);
        run_load_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_load_test.step);
    }

    // Framework unit tests.
    const fw_test_modules = [_][]const u8{
        "framework/tracer.zig",
        "framework/http.zig",
        "framework/marks.zig",
        "framework/time.zig",
        "framework/auth.zig",
        "framework/checksum.zig",
        "framework/parse.zig",
    };
    for (fw_test_modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.root_module.addOptions("build_options", build_options);
        const run_fw_test = b.addRunArtifact(unit_test);
        run_fw_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_fw_test.step);
    }

    // Trace engine + event tests.
    for ([_][]const u8{ "framework/trace_event.zig", "framework/trace.zig" }) |trace_file| {
        const trace_test = b.addTest(.{
            .root_source_file = b.path(trace_file),
            .target = target,
            .optimize = optimize,
        });
        trace_test.root_module.addImport("stdx", stdx_module);
        trace_test.root_module.addOptions("build_options", build_options);
        trace_test.linkLibC();
        const run_trace_test = b.addRunArtifact(trace_test);
        unit_test_step.dependOn(&run_trace_test.step);
    }

    // Shell + scripts tests.
    const shell_test = b.addTest(.{
        .root_source_file = b.path("shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_test.root_module.addImport("stdx", stdx_module);
    shell_test.root_module.addOptions("build_options", build_options);
    const run_shell_test = b.addRunArtifact(shell_test);
    run_shell_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_shell_test.step);

    const scripts_test = b.addTest(.{
        .root_source_file = b.path("scripts.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripts_test.root_module.addImport("stdx", stdx_module);
    scripts_test.root_module.addOptions("build_options", build_options);
    const run_scripts_test = b.addRunArtifact(scripts_test);
    run_scripts_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_scripts_test.step);

    // --- Cross-language adapter tests (requires npx tsx) ---
    // These read binary vectors written by Zig unit tests (/tmp/tiger_*.bin).
    // CI must run unit-test BEFORE test-adapter to generate the vectors.
    {
        const adapter_test_step = b.step("test-adapter", "Run TypeScript cross-language tests");
        for ([_][]const u8{
            "generated/serde_test.ts",
            "generated/call_test.ts",
            "generated/routing_test.ts",
        }) |test_file| {
            const cmd = b.addSystemCommand(&.{ "npx", "-y", "tsx", test_file });
            adapter_test_step.dependOn(&cmd.step);
        }
    }

    // --- CI pipeline (zig build ci -- <mode>) ---
    // Matches TB's pattern: build step that invokes other build steps as subprocesses.
    // Modes: test (default), fuzz (commit-SHA seed), clients (example projects).
    build_ci(b, scripts_exe, .{
        .zig_exe = b.graph.zig_exe,
    });

    // --- Benchmark (smoke mode as part of unit-test, real via bench step) ---
    const bench_smoke_options = b.addOptions();
    bench_smoke_options.addOption(bool, "benchmark", false);

    const bench_smoke = b.addTest(.{
        .root_source_file = b.path("state_machine_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_smoke.root_module.addImport("stdx", stdx_module);
    bench_smoke.root_module.addOptions("build_options", build_options);
    bench_smoke.root_module.addOptions("bench_options", bench_smoke_options);
    bench_smoke.linkSystemLibrary("sqlite3");
    bench_smoke.linkLibC();
    const run_bench_smoke = b.addRunArtifact(bench_smoke);
    run_bench_smoke.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_bench_smoke.step);

    const bench_real_options = b.addOptions();
    bench_real_options.addOption(bool, "benchmark", true);

    const bench_real = b.addTest(.{
        .root_source_file = b.path("state_machine_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_real.root_module.addImport("stdx", stdx_module);
    bench_real.root_module.addOptions("build_options", build_options);
    bench_real.root_module.addOptions("bench_options", bench_real_options);
    bench_real.linkSystemLibrary("sqlite3");
    bench_real.linkLibC();
    const bench_run = b.addRunArtifact(bench_real);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Run state machine benchmark");
    bench_step.dependOn(&bench_run.step);
}

/// CI pipeline — ported from TigerBeetle's build.zig build_ci pattern.
/// Invokes build steps as subprocesses so each has its own exit code.
fn build_ci(
    b: *std.Build,
    scripts: *std.Build.Step.Compile,
    options: struct { zig_exe: []const u8 },
) void {
    const step_ci = b.step("ci", "Run the full CI pipeline");

    const CIMode = enum {
        @"test", // Main test suite: scan, unit tests, sim tests, fuzz smoke.
        fuzz, // Fuzz smoke + commit-SHA seeded fuzz run.
        clients, // Example project tests (adapter + integration).
        default, // test + clients.
        all,
    };

    const mode: CIMode = if (b.args) |args| mode: {
        if (args.len != 1) {
            step_ci.dependOn(&b.addFail("ci: expected 1 argument (test|fuzz|clients)").step);
            return;
        }
        if (std.meta.stringToEnum(CIMode, args[0])) |m| {
            break :mode m;
        } else {
            step_ci.dependOn(&b.addFail("ci: unknown mode").step);
            return;
        }
    } else .default;

    const all = mode == .all;
    const default = all or mode == .default;

    if (default or mode == .@"test") {
        // Scan annotations — regenerate routes + manifest.
        build_ci_step(b, step_ci, &.{ "scan", "--", "handlers/",
            "--routes-zig=generated/routes.generated.zig",
            "--manifest=generated/manifest.json",
        });
        // Freshness check — committed routes file must match scanner output.
        // Only check routes.generated.zig (from Zig handlers). manifest.json
        // is overwritten by both Zig and TypeScript scans — can't freshness check.
        const freshness = b.addSystemCommand(&.{ "git", "diff", "--exit-code", "generated/routes.generated.zig" });
        freshness.setName("freshness check: routes.generated.zig");
        step_ci.dependOn(&freshness.step);
        // Unit tests.
        build_ci_step(b, step_ci, &.{"unit-test"});
        // Simulation tests.
        build_ci_step(b, step_ci, &.{"test"});
        // Fuzz smoke.
        build_ci_step(b, step_ci, &.{ "fuzz", "--", "smoke" });
        // Scripts help (verifies scripts compile).
        build_ci_script(b, step_ci, scripts, &.{"--help"}, options.zig_exe);
    }

    if (all or mode == .fuzz) {
        build_ci_step(b, step_ci, &.{ "fuzz", "--", "smoke" });
        // Per-commit deterministic fuzz: state_machine with commit SHA as seed.
        // Same idea as TB's VOPR — every commit gets a unique fuzz pass.
        // Convert first 8 hex chars of SHA to decimal u32 via printf.
        const cmd = std.mem.join(b.allocator, " ", &.{
            options.zig_exe, "build", "fuzz", "--", "state_machine",
            "$(printf '%d' 0x$(git rev-parse HEAD | cut -c1-8))",
        }) catch @panic("OOM");
        const fuzz_seeded = b.addSystemCommand(&.{ "sh", "-c", cmd });
        fuzz_seeded.has_side_effects = true;
        fuzz_seeded.setName("fuzz state_machine <commit-sha>");
        step_ci.dependOn(&fuzz_seeded.step);
    }

    if (default or all or mode == .clients) {
        // Cross-language tests (Level 1: binary protocol boundary).
        build_ci_step(b, step_ci, &.{"test-adapter"});
        // Example project integration test (Level 2: full handler logic).
        build_ci_script(b, step_ci, scripts, &.{"ci"}, options.zig_exe);
    }
}

/// Run a build step as a subprocess. Ported from TB's build_ci_step.
fn build_ci_step(
    b: *std.Build,
    step_ci: *std.Build.Step,
    command: []const []const u8,
) void {
    const system_command = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    for (command) |arg| system_command.addArg(arg);
    const name = std.mem.join(b.allocator, " ", command) catch @panic("OOM");
    system_command.setName(name);
    system_command.has_side_effects = true;
    step_ci.dependOn(&system_command.step);
}

/// Run the scripts executable with args. Ported from TB's build_ci_script.
fn build_ci_script(
    b: *std.Build,
    step_ci: *std.Build.Step,
    scripts: *std.Build.Step.Compile,
    argv: []const []const u8,
    zig_exe: []const u8,
) void {
    const run_artifact = b.addRunArtifact(scripts);
    run_artifact.addArgs(argv);
    run_artifact.setEnvironmentVariable("ZIG_EXE", zig_exe);
    run_artifact.has_side_effects = true;
    step_ci.dependOn(&run_artifact.step);
}

/// Ported from TigerBeetle's build.zig. When print=true, compiles the artifact
/// and prints its path to stdout (used by CFO to spawn the binary directly,
/// separating build time from fuzzer runtime). When print=false, installs normally.
fn print_or_install(b: *std.Build, compile: *std.Build.Step.Compile, print: bool) *std.Build.Step {
    const PrintStep = struct {
        step: std.Build.Step,
        compile: *std.Build.Step.Compile,

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const print_step: *@This() = @fieldParentPtr("step", step);
            const path = print_step.compile.getEmittedBin().getPath2(step.owner, step);
            try std.io.getStdOut().writer().print("{s}\n", .{path});
        }
    };

    if (print) {
        const print_step = b.allocator.create(PrintStep) catch @panic("OOM");
        print_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "print exe",
                .owner = b,
                .makeFn = PrintStep.make,
            }),
            .compile = compile,
        };
        print_step.step.dependOn(&print_step.compile.step);
        return &print_step.step;
    } else {
        return &b.addInstallArtifact(compile, .{}).step;
    }
}
