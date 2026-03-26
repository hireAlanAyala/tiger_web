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

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "tiger-web",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("stdx", stdx_module);
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
    sim_tests.linkSystemLibrary("sqlite3");
    sim_tests.linkLibC();
    const run_sim_tests = b.addRunArtifact(sim_tests);
    run_sim_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    const test_step = b.step("test", "Run simulation tests");
    test_step.dependOn(&run_sim_tests.step);

    // --- Fuzz test dispatcher ---
    const fuzz_exe = b.addExecutable(.{
        .name = "tiger-fuzz",
        .root_source_file = b.path("fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_exe.root_module.addImport("stdx", stdx_module);
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
        "wal_test.zig",
        "annotation_scanner.zig",
    };
    const unit_test_step = b.step("unit-test", "Run unit tests");
    for (modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        const run_unit_test = b.addRunArtifact(unit_test);
        run_unit_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_unit_test.step);
    }

    // Modules that need sqlite3 + libc.
    for ([_][]const u8{ "storage.zig", "replay.zig", "state_machine_test.zig", "sidecar.zig", "sidecar_test.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.linkSystemLibrary("sqlite3");
        unit_test.linkLibC();
        const run_ut = b.addRunArtifact(unit_test);
        run_ut.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_ut.step);
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
        const run_fw_test = b.addRunArtifact(unit_test);
        run_fw_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_fw_test.step);
    }

    // Shell + scripts tests.
    const shell_test = b.addTest(.{
        .root_source_file = b.path("shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_test.root_module.addImport("stdx", stdx_module);
    const run_shell_test = b.addRunArtifact(shell_test);
    run_shell_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_shell_test.step);

    const scripts_test = b.addTest(.{
        .root_source_file = b.path("scripts.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripts_test.root_module.addImport("stdx", stdx_module);
    const run_scripts_test = b.addRunArtifact(scripts_test);
    run_scripts_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_scripts_test.step);

    // --- Adapter test (opt-in, requires npx tsx) ---
    const adapter_test_cmd = b.addSystemCommand(&.{ "npx", "-y", "tsx", "adapters/typescript_test.ts" });
    const adapter_test_step = b.step("test-adapter", "Run TypeScript adapter test");
    adapter_test_step.dependOn(&adapter_test_cmd.step);

    // --- Benchmark (smoke mode as part of unit-test, real via bench step) ---
    const bench_smoke_options = b.addOptions();
    bench_smoke_options.addOption(bool, "benchmark", false);

    const bench_smoke = b.addTest(.{
        .root_source_file = b.path("state_machine_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_smoke.root_module.addImport("stdx", stdx_module);
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
    bench_real.root_module.addOptions("bench_options", bench_real_options);
    bench_real.linkSystemLibrary("sqlite3");
    bench_real.linkLibC();
    const bench_run = b.addRunArtifact(bench_real);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Run state machine benchmark");
    bench_step.dependOn(&bench_run.step);
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
