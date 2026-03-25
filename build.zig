const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No framework module — all framework files imported via direct file
    // path (@import("framework/lib.zig")). This keeps everything in one
    // compilation unit so std_options in the root controls logging for
    // ALL code including framework internals. Matches TigerBeetle: one
    // compilation unit, root owns log config.

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "tiger-web",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    replay_exe.linkSystemLibrary("sqlite3");
    replay_exe.linkLibC();
    b.installArtifact(replay_exe);

    const replay_cmd = b.addRunArtifact(replay_exe);
    replay_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| replay_cmd.addArgs(args);
    const replay_step = b.step("replay", "Run the replay tool");
    replay_step.dependOn(&replay_cmd.step);

    // --- Simulation tests ---
    const sim_exe = b.addExecutable(.{
        .name = "tiger-sim",
        .root_source_file = b.path("sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_exe.linkSystemLibrary("sqlite3");
    sim_exe.linkLibC();
    b.installArtifact(sim_exe);
    const run_sim_tests = b.addRunArtifact(sim_exe);
    if (b.args) |args| run_sim_tests.addArgs(args);
    const test_step = b.step("test", "Run simulation tests");
    test_step.dependOn(&run_sim_tests.step);

    // --- Fuzz test dispatcher ---
    const fuzz_exe = b.addExecutable(.{
        .name = "tiger-fuzz",
        .root_source_file = b.path("fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
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
        const run_unit_test = b.addRunArtifact(unit_test);
        unit_test_step.dependOn(&run_unit_test.step);
    }

    // Modules that need sqlite3 + libc.
    for ([_][]const u8{ "storage.zig", "replay.zig", "state_machine_test.zig", "sidecar.zig", "sidecar_test.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.linkSystemLibrary("sqlite3");
        unit_test.linkLibC();
        unit_test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }

    // Framework unit tests.
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
    bench_real.root_module.addOptions("bench_options", bench_real_options);
    bench_real.linkSystemLibrary("sqlite3");
    bench_real.linkLibC();
    const bench_run = b.addRunArtifact(bench_real);
    bench_run.has_side_effects = true;
    const bench_step = b.step("bench", "Run state machine benchmark");
    bench_step.dependOn(&bench_run.step);
}
