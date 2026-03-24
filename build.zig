const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Framework as a local package dependency.
    const framework = b.dependency("tiger_framework", .{
        .target = target,
        .optimize = optimize,
    }).module("tiger_framework");

    // Helper: add framework module + system libs to a compile step.
    const addFramework = struct {
        fn apply(mod: *std.Build.Module, fw: *std.Build.Module) void {
            mod.addImport("tiger_framework", fw);
        }
    }.apply;

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "tiger-web",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(exe.root_module, framework);
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
    addFramework(worker_exe.root_module, framework);
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
    addFramework(replay_exe.root_module, framework);
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
    addFramework(sim_tests.root_module, framework);
    sim_tests.linkLibC();
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const test_step = b.step("test", "Run simulation tests");
    test_step.dependOn(&run_sim_tests.step);

    // --- Fuzz test dispatcher ---
    const fuzz_exe = b.addExecutable(.{
        .name = "tiger-fuzz",
        .root_source_file = b.path("fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(fuzz_exe.root_module, framework);
    fuzz_exe.linkSystemLibrary("sqlite3");
    fuzz_exe.linkLibC();
    b.installArtifact(fuzz_exe);

    const fuzz_cmd = b.addRunArtifact(fuzz_exe);
    fuzz_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| fuzz_cmd.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    fuzz_step.dependOn(&fuzz_cmd.step);

    // --- Annotation scanner ---
    const scanner_exe = b.addExecutable(.{
        .name = "annotation-scanner",
        .root_source_file = b.path("annotation_scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(scanner_exe.root_module, framework);
    b.installArtifact(scanner_exe);

    const scanner_cmd = b.addRunArtifact(scanner_exe);
    scanner_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| scanner_cmd.addArgs(args);
    const scanner_step = b.step("scan", "Scan annotations for handler exhaustiveness");
    scanner_step.dependOn(&scanner_cmd.step);

    // --- Unit tests for individual modules ---
    // Modules with no C dependencies.
    // These must NOT import app.zig (which pulls in SqliteStorage → sqlite3).
    // They use state_machine and message module-level types directly.
    const modules = [_][]const u8{
        "message.zig",
        "wal_test.zig",
        "annotation_scanner.zig",
        "codegen.zig",
        "serde_test_codegen.zig",
    };
    const unit_test_step = b.step("unit-test", "Run unit tests");
    for (modules) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        addFramework(unit_test.root_module, framework);
        const run_unit_test = b.addRunArtifact(unit_test);
        unit_test_step.dependOn(&run_unit_test.step);
    }

    // Modules that need libc only (no sqlite3).
    for ([_][]const u8{}) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        addFramework(unit_test.root_module, framework);
        unit_test.linkLibC();
        unit_test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }

    // Modules that need sqlite3 + libc (import app.zig → storage.zig → sqlite3).
    // state_machine_test.zig is separate from state_machine.zig so that
    // files importing the SM module don't transitively need sqlite3.
    for ([_][]const u8{ "storage.zig", "replay.zig", "state_machine_test.zig", "sidecar.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        addFramework(unit_test.root_module, framework);
        unit_test.linkSystemLibrary("sqlite3");
        unit_test.linkLibC();
        unit_test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }

    // Framework unit tests (run from the framework's own test targets).
    const fw_test_modules = [_][]const u8{
        "framework/tracer.zig",
        "framework/http.zig",
        "framework/marks.zig",
        "framework/prng.zig",
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
        unit_test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }

    // --- Codegen ---
    const codegen_exe = b.addExecutable(.{
        .name = "tiger-codegen",
        .root_source_file = b.path("codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(codegen_exe.root_module, framework);

    const codegen_cmd = b.addRunArtifact(codegen_exe);
    const codegen_output = codegen_cmd.captureStdOut();
    const wf = b.addUpdateSourceFiles();
    wf.addCopyFileToSource(codegen_output, "generated/types.generated.ts");

    // Serde test codegen — generates round-trip test file.
    const serde_test_exe = b.addExecutable(.{
        .name = "tiger-serde-test-codegen",
        .root_source_file = b.path("serde_test_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(serde_test_exe.root_module, framework);

    const serde_test_cmd = b.addRunArtifact(serde_test_exe);
    const serde_test_output = serde_test_cmd.captureStdOut();
    wf.addCopyFileToSource(serde_test_output, "generated/serde_test.generated.ts");

    const codegen_step = b.step("codegen", "Generate TypeScript type definitions");
    codegen_step.dependOn(&wf.step);

    // --- Adapter test (opt-in, requires npx tsx) ---
    const adapter_test_cmd = b.addSystemCommand(&.{ "npx", "-y", "tsx", "adapters/typescript_test.ts" });
    adapter_test_cmd.step.dependOn(codegen_step);
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
    addFramework(bench_smoke.root_module, framework);
    bench_smoke.root_module.addOptions("bench_options", bench_smoke_options);
    bench_smoke.linkSystemLibrary("sqlite3");
    bench_smoke.linkLibC();
    unit_test_step.dependOn(&b.addRunArtifact(bench_smoke).step);

    const bench_real_options = b.addOptions();
    bench_real_options.addOption(bool, "benchmark", true);

    const bench_real = b.addTest(.{
        .root_source_file = b.path("state_machine_benchmark.zig"),
        .target = target,
        .optimize = optimize,
    });
    addFramework(bench_real.root_module, framework);
    bench_real.root_module.addOptions("bench_options", bench_real_options);
    bench_real.linkSystemLibrary("sqlite3");
    bench_real.linkLibC();
    const bench_run = b.addRunArtifact(bench_real);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Run state machine benchmark");
    bench_step.dependOn(&bench_run.step);
}
