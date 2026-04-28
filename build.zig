const std = @import("std");
const builtin = @import("builtin");

/// Link SQLite from the vendored amalgamation. Zero system dependencies.
fn link_sqlite(step: *std.Build.Step.Compile) void {
    const sqlite_flags: []const []const u8 = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1" };
    step.addCSourceFile(.{
        .file = step.step.owner.path("src/vendor/sqlite3/sqlite3.c"),
        .flags = sqlite_flags,
    });
    // Zig shim: compiled wrappers for SQLITE_TRANSIENT (see sqlite3_zig.h).
    step.addCSourceFile(.{
        .file = step.step.owner.path("src/vendor/sqlite3/sqlite3_zig.c"),
        .flags = sqlite_flags,
    });
    step.addIncludePath(step.step.owner.path("src/vendor/sqlite3"));
    step.linkLibC();
}

/// Platforms for cross-compiling the SHM native addon.
/// Matches TigerBeetle's Platform enum pattern (build.zig line 1328).
/// No Windows — we target Linux and macOS only.
const NativePlatform = enum {
    @"aarch64-linux",
    @"x86_64-linux",
    @"aarch64-macos",
    @"x86_64-macos",

    const all: []const NativePlatform = std.enums.values(NativePlatform);

    fn target_resolved(platform: NativePlatform, b: *std.Build) std.Build.ResolvedTarget {
        const query = std.Target.Query.parse(.{
            .arch_os_abi = @tagName(platform),
        }) catch unreachable;
        return b.resolveTargetQuery(query);
    }
};

/// Cross-compile the SHM native addon (shm.c) for all platforms.
/// Matches TigerBeetle's build_node_client pattern:
/// - addLibrary(.dynamic) per platform
/// - vendored node-api-headers
/// - linker_allow_shlib_undefined = true
/// - output to packages/ts/native/dist/{platform}/shm.node
fn build_native_addon(b: *std.Build) *std.Build.Step {
    const step = b.step("native-addon", "Cross-compile shm.node for all platforms");

    for (NativePlatform.all) |platform| {
        const resolved_target = platform.target_resolved(b);

        const lib = b.addLibrary(.{
            .name = "shm",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .target = resolved_target,
                .optimize = .ReleaseFast,
            }),
        });

        lib.root_module.addCSourceFile(.{
            .file = b.path("packages/ts/native/shm.c"),
            .flags = &.{"-fPIC"},
        });

        lib.root_module.addSystemIncludePath(b.path("src/vendor/node-api-headers"));
        lib.linkLibC();
        lib.linker_allow_shlib_undefined = true;

        // Install to packages/ts/native/dist/{platform}/shm.node in the source tree.
        const usf = b.addUpdateSourceFiles();
        usf.addCopyFileToSource(
            lib.getEmittedBin(),
            b.fmt("packages/ts/native/dist/{s}/shm.node", .{@tagName(platform)}),
        );
        step.dependOn(&usf.step);
    }

    return step;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const print_exe = b.option(bool, "print-exe", "Build tasks print the path of the executable") orelse false;

    // stdx module — all compilation units use @import("stdx"), matching TB's pattern.
    // Each compilation unit has its own std_options (root owns log config), but stdx
    // is shared via module wiring so @src().file paths resolve correctly for Snap tests.
    const stdx_module = b.addModule("stdx", .{
        .root_source_file = b.path("src/framework/stdx/stdx.zig"),
    });

    // --- Build options ---
    const sidecar_enabled = b.option(bool, "sidecar", "Enable sidecar handler mode") orelse false;
    const sidecar_count: u8 = b.option(u8, "sidecar-count", "Number of sidecar connections (default 1)") orelse 1;
    const pipeline_slots: u8 = b.option(u8, "pipeline-slots", "Number of concurrent pipeline slots (default = sidecar-count)") orelse sidecar_count;
    const build_options = b.addOptions();
    build_options.addOption(bool, "sidecar_enabled", sidecar_enabled);
    build_options.addOption(bool, "skip_native_routes", false);
    build_options.addOption(u8, "sidecar_count", sidecar_count);
    build_options.addOption(u8, "pipeline_slots", pipeline_slots);

    // --- Main executable ---
    const exe = b.addExecutable(.{
        .name = "tiger-web",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("stdx", stdx_module);
    exe.root_module.addOptions("build_options", build_options);
    link_sqlite(exe);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);


    // --- Replay tool ---
    const replay_exe = b.addExecutable(.{
        .name = "tiger-replay",
        .root_source_file = b.path("src/replay.zig"),
        .target = target,
        .optimize = optimize,
    });
    replay_exe.root_module.addImport("stdx", stdx_module);
    replay_exe.root_module.addOptions("build_options", build_options);
    link_sqlite(replay_exe);
    b.installArtifact(replay_exe);

    const replay_cmd = b.addRunArtifact(replay_exe);
    replay_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| replay_cmd.addArgs(args);
    const replay_step = b.step("replay", "Run the replay tool");
    replay_step.dependOn(&replay_cmd.step);

    // --- Simulation tests ---
    const sim_tests = b.addTest(.{
        .root_source_file = b.path("src/sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    sim_tests.root_module.addImport("stdx", stdx_module);
    sim_tests.root_module.addOptions("build_options", build_options);
    link_sqlite(sim_tests);
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
    sidecar_sim_options.addOption(bool, "skip_native_routes", false);
    sidecar_sim_options.addOption(u8, "sidecar_count", 2);
    sidecar_sim_options.addOption(u8, "pipeline_slots", 2);

    const sidecar_sim = b.addTest(.{
        .root_source_file = b.path("src/sim_sidecar.zig"),
        .target = target,
        .optimize = optimize,
    });
    sidecar_sim.root_module.addImport("stdx", stdx_module);
    sidecar_sim.root_module.addOptions("build_options", sidecar_sim_options);
    link_sqlite(sidecar_sim);
    const run_sidecar_sim = b.addRunArtifact(sidecar_sim);
    run_sidecar_sim.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    const sidecar_test_step = b.step("test-sidecar", "Run sidecar simulation tests");
    sidecar_test_step.dependOn(&run_sidecar_sim.step);

    // --- Fuzz test dispatcher ---
    const fuzz_exe = b.addExecutable(.{
        .name = "tiger-fuzz",
        .root_source_file = b.path("src/fuzz_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    fuzz_exe.root_module.addImport("stdx", stdx_module);
    fuzz_exe.root_module.addOptions("build_options", build_options);
    link_sqlite(fuzz_exe);
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

    // --- Focus CLI (project scaffolding, build, dev) ---
    // Focus CLI always runs with sidecar (it embeds the server + spawns sidecar).
    // Focus CLI: 4 pipeline slots for concurrent request handling.
    // One sidecar connection, 4 concurrent in-flight requests.
    const focus_build_options = b.addOptions();
    focus_build_options.addOption(bool, "sidecar_enabled", true);
    focus_build_options.addOption(bool, "skip_native_routes", true);
    focus_build_options.addOption(u8, "sidecar_count", 1);
    focus_build_options.addOption(u8, "pipeline_slots", 4);

    // Cross-compile native addon for all platforms before building focus,
    // so @embedFile can find the platform-specific shm.node binary.
    const native_addon_step = build_native_addon(b);

    const focus_exe = b.addExecutable(.{
        .name = "focus",
        .root_source_file = b.path("focus.zig"),
        .target = target,
        .optimize = optimize,
    });
    focus_exe.root_module.addImport("stdx", stdx_module);
    focus_exe.root_module.addOptions("build_options", focus_build_options);
    // tiger_web module — public API root for binaries that live
    // outside src/ (focus.zig at repo root, because @embedFile of
    // packages/* + templates/* requires it inside Zig's package
    // boundary). Same pattern as TigerBeetle's `vsr` module rooted
    // at `src/vsr.zig`: a single re-export hub that holds the
    // public surface; cross-tree binaries reach in via
    // `@import("tiger_web").X` rather than relative paths.
    const tiger_web_module = b.createModule(.{
        .root_source_file = b.path("src/tiger_web.zig"),
        .target = target,
        .optimize = optimize,
    });
    tiger_web_module.addImport("stdx", stdx_module);
    tiger_web_module.addOptions("build_options", focus_build_options);
    // tiger_web re-exports storage.zig which @cImports sqlite3_zig.h;
    // the module compiles separately from focus_exe so it needs its
    // own include path + libc link.
    tiger_web_module.addIncludePath(b.path("src/vendor/sqlite3"));
    tiger_web_module.link_libc = true;
    focus_exe.root_module.addImport("tiger_web", tiger_web_module);

    focus_exe.step.dependOn(native_addon_step);
    link_sqlite(focus_exe);
    b.installArtifact(focus_exe);

    const focus_cmd = b.addRunArtifact(focus_exe);
    focus_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| focus_cmd.addArgs(args);
    const focus_step = b.step("focus", "Run the focus CLI");
    focus_step.dependOn(&focus_cmd.step);

    // --- Zig sidecar benchmark tool ---
    const zig_sidecar_exe = b.addExecutable(.{
        .name = "zig-sidecar",
        .root_source_file = b.path("src/zig_sidecar.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Allow imports from the root (protocol.zig, message.zig).
    zig_sidecar_exe.root_module.addImport("stdx", stdx_module);
    link_sqlite(zig_sidecar_exe);
    b.installArtifact(zig_sidecar_exe);

    // --- Scripts executable (CFO and other automation) ---
    const scripts_exe = b.addExecutable(.{
        .name = "tiger-scripts",
        .root_source_file = b.path("src/scripts.zig"),
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

    // --- Bench discipline check ---
    // Runs `tiger-scripts bench-check` — asserts every *_benchmark.zig
    // file has a budget reference pointing at docs/internal/benchmark-budgets.md
    // and calls bench.assert_budget. Wired into `unit-test` below so
    // every commit's CI run enforces it. Automation, not discipline.
    const bench_check_cmd = b.addRunArtifact(scripts_exe);
    bench_check_cmd.step.dependOn(&b.addInstallArtifact(scripts_exe, .{}).step);
    bench_check_cmd.addArg("bench-check");
    const bench_check_step = b.step("bench-check", "Assert benchmark-tracking discipline");
    bench_check_step.dependOn(&bench_check_cmd.step);

    // --- Style check ---
    // Runs `tiger-scripts style-check` — mechanical TIGER_STYLE
    // enforcement on hot-path files (function-length, assertion
    // density, known-throwaway markers). Same rationale as
    // bench-check: converts prose rules into build gates so
    // discipline that keeps slipping stops slipping.
    const style_check_cmd = b.addRunArtifact(scripts_exe);
    style_check_cmd.step.dependOn(&b.addInstallArtifact(scripts_exe, .{}).step);
    style_check_cmd.addArg("style-check");
    const style_check_step = b.step("style-check", "Assert TIGER_STYLE hot-path discipline");
    style_check_step.dependOn(&style_check_cmd.step);

    // --- Annotation scanner ---
    const scanner_exe = b.addExecutable(.{
        .name = "annotation-scanner",
        .root_source_file = b.path("src/annotation_scanner.zig"),
        .target = target,
        .optimize = optimize,
    });
    scanner_exe.root_module.addImport("stdx", stdx_module);
    b.installArtifact(scanner_exe);

    const scanner_cmd = b.addRunArtifact(scanner_exe);
    if (b.args) |args| {
        scanner_cmd.addArgs(args);
    } else {
        scanner_cmd.addArg("src/handlers/");
    }
    const scanner_step = b.step("scan", "Scan handlers for annotation and status exhaustiveness");
    scanner_step.dependOn(&scanner_cmd.step);

    // --- Unit tests for individual modules ---
    const modules = [_][]const u8{
        "src/message.zig",
        "src/framework/message_pool.zig",
        "src/wal_test.zig",
        "src/annotation_scanner.zig",
        "src/supervisor.zig",
    };
    const unit_test_step = b.step("unit-test", "Run unit tests");
    // Benchmark discipline check runs first — a calibration violation
    // should fail fast, before expensive test suites.
    unit_test_step.dependOn(&bench_check_cmd.step);
    unit_test_step.dependOn(&style_check_cmd.step);
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
    // Linux-only: io/linux.zig (io_uring), message_bus.zig (unix sockets),
    // worker_dispatch.zig (SHM), worker_integration_test.zig.
    if (target.result.os.tag == .linux) {
        for ([_][]const u8{ "src/framework/message_bus.zig", "src/framework/io/linux.zig", "src/framework/worker_dispatch.zig", "src/worker_integration_test.zig" }) |mod| {
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
    }

    // Modules that need sqlite3 + libc.
    for ([_][]const u8{ "src/storage.zig", "src/replay.zig", "src/state_machine_test.zig" }) |mod| {
        const unit_test = b.addTest(.{
            .root_source_file = b.path(mod),
            .target = target,
            .optimize = optimize,
        });
        unit_test.root_module.addImport("stdx", stdx_module);
        unit_test.root_module.addOptions("build_options", build_options);
        link_sqlite(unit_test);
        const run_ut = b.addRunArtifact(unit_test);
        run_ut.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_ut.step);
    }

    // Framework unit tests.
    const fw_test_modules = [_][]const u8{
        "src/framework/http.zig",
        "src/framework/marks.zig",
        "src/framework/time.zig",
        "src/framework/auth.zig",
        "src/framework/checksum.zig",
        "src/framework/parse.zig",
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
    for ([_][]const u8{ "src/trace_event.zig", "src/trace.zig" }) |trace_file| {
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
        .root_source_file = b.path("src/shell.zig"),
        .target = target,
        .optimize = optimize,
    });
    shell_test.root_module.addImport("stdx", stdx_module);
    shell_test.root_module.addOptions("build_options", build_options);
    const run_shell_test = b.addRunArtifact(shell_test);
    run_shell_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_shell_test.step);

    const scripts_test = b.addTest(.{
        .root_source_file = b.path("src/scripts.zig"),
        .target = target,
        .optimize = optimize,
    });
    scripts_test.root_module.addImport("stdx", stdx_module);
    scripts_test.root_module.addOptions("build_options", build_options);
    const run_scripts_test = b.addRunArtifact(scripts_test);
    run_scripts_test.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_scripts_test.step);

    // --- unit-test-build: kcov-attachable aggregated test binary ---
    //
    // Plan Phase G.0.a. Produces `./zig-out/bin/tiger-unit-test` —
    // a single binary with every test block imported via
    // `tiger_unit_tests.zig`. Needed because `zig build unit-test`
    // runs tests in-process and leaves no on-disk artifact for kcov
    // to attach to. Mirrors TigerBeetle's `test:unit:build`:
    //   - `tigerbeetle/build.zig:895-918` creates `test-unit`,
    //     installs the artifact; our version does the same with
    //     link_sqlite + linkLibC applied (our aggregator imports
    //     modules that need both).
    //
    // Usage: `zig build unit-test-build` → binary appears in
    // `zig-out/bin/`. Running it executes all tests sequentially.
    const unit_test_binary = b.addTest(.{
        .name = "tiger-unit-test",
        .root_source_file = b.path("src/tiger_unit_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_binary.root_module.addImport("stdx", stdx_module);
    unit_test_binary.root_module.addOptions("build_options", build_options);
    // `test_options` matches TB's `tigerbeetle/build.zig:885-893,915`
    // pattern: a build-time module that exposes a `benchmark: bool`
    // toggle. `framework/bench.zig` reads it at line 77 to switch
    // between smoke (small inputs, silent) and benchmark (real
    // inputs, prints) modes. The aggregator carries
    // `framework/bench.zig` so it has to provide the option module.
    //
    // **Intent: aggregator runs in smoke mode.** TB's `b.args`
    // populates from `zig build test -- "benchmark: name"`-style
    // invocations; ours doesn't because `unit_test_binary` is an
    // install-only step (`addInstallArtifact`, not `addRunArtifact`),
    // so `b.args` is empty here regardless of how `zig build` was
    // invoked. Result: `test_options.benchmark` is always false,
    // bench files always run their smoke variant inside
    // `tiger-unit-test` — the desired behavior. The TB-style
    // `b.args` parser is preserved verbatim in case our invocation
    // shape ever grows to match TB's, so this expression doesn't
    // need to be rewritten when that happens.
    const test_options = b.addOptions();
    test_options.addOption(bool, "benchmark", for (b.args orelse &.{}) |arg| {
        if (std.mem.indexOf(u8, arg, "benchmark") != null) break true;
    } else false);
    unit_test_binary.root_module.addOptions("test_options", test_options);
    link_sqlite(unit_test_binary);
    unit_test_binary.linkLibC();
    const unit_test_build_step = b.step("unit-test-build", "Build unit tests as ./zig-out/bin/tiger-unit-test");
    unit_test_build_step.dependOn(&b.addInstallArtifact(unit_test_binary, .{}).step);

    // --- stdx tests as a separate target (TB pattern) ---
    //
    // stdx is wired as a module via `addImport("stdx", ...)`; tests
    // inside framework/stdx/* can't be run from the main aggregator
    // because Zig rejects importing the same file via both a module
    // path and a direct filesystem path. Solution: a separate test
    // target rooted at framework/stdx/stdx.zig with no stdx-as-module
    // wiring.
    //
    // Mirrors TigerBeetle's `test-stdx` at `tigerbeetle/build.zig:895-903`:
    // separate `b.addTest`, separate install artifact, separate run
    // artifact, both wired into the unit-test pipeline.
    const stdx_test_binary = b.addTest(.{
        .name = "tiger-stdx-test",
        .root_source_file = b.path("src/framework/stdx/stdx.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_build_step.dependOn(&b.addInstallArtifact(stdx_test_binary, .{}).step);
    const run_stdx_tests = b.addRunArtifact(stdx_test_binary);
    run_stdx_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    unit_test_step.dependOn(&run_stdx_tests.step);

    // --- tidy: discipline-as-tests (TB src/tidy.zig port) ---
    //
    // Standalone test target rooted at tidy.zig. Not currently in
    // unit_test_step because the codebase has accumulated TIGER_STYLE
    // drift that tidy surfaces (long lines, defer newlines, banned
    // patterns, dead code). Run via `zig build tidy` for incremental
    // cleanup work; once `zig build tidy` returns green, add tidy.zig
    // to tiger_unit_tests.zig's comptime imports to make it CI-gating.
    const tidy_tests = b.addTest(.{
        .name = "tiger-tidy-test",
        .root_source_file = b.path("src/tidy.zig"),
        .target = target,
        .optimize = optimize,
    });
    tidy_tests.root_module.addImport("stdx", stdx_module);
    const run_tidy_tests = b.addRunArtifact(tidy_tests);
    const tidy_step = b.step("tidy", "Run tidy.zig discipline checks");
    tidy_step.dependOn(&run_tidy_tests.step);

    // --- Cross-language adapter tests (requires npx tsx) ---
    // Protocol vectors + round-trip tests validate TS serde against committed vectors.
    {
        const adapter_test_step = b.step("test-adapter", "Run TypeScript cross-language tests");
        for ([_][]const u8{
            "src/generated/routing_test.ts",
            "packages/ts/test/protocol_test.ts",
            "packages/ts/test/round_trip_test.ts",
            "packages/ts/test/fuzz_test.ts",
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
    //
    // Each benchmark source file is compiled twice:
    //   - smoke: small inputs, silent, assert_budget fires. Part of unit-test.
    //   - real:  large inputs, prints. Part of `zig build bench`.
    //
    // Pipeline-tier benches (state_machine) need sqlite; primitive-tier
    // benches (aegis_checksum, ...) don't. Adding a new bench file:
    // append to `bench_sources` below.
    const BenchSrc = struct { path: []const u8, needs_sqlite: bool };
    const bench_sources = [_]BenchSrc{
        .{ .path = "src/state_machine_benchmark.zig", .needs_sqlite = true },
        .{ .path = "src/aegis_checksum_benchmark.zig", .needs_sqlite = false },
        .{ .path = "src/crc_frame_benchmark.zig", .needs_sqlite = false },
        .{ .path = "src/hmac_session_benchmark.zig", .needs_sqlite = false },
        .{ .path = "src/wal_parse_benchmark.zig", .needs_sqlite = false },
        .{ .path = "src/route_match_benchmark.zig", .needs_sqlite = false },
    };

    const bench_smoke_options = b.addOptions();
    bench_smoke_options.addOption(bool, "benchmark", false);

    const bench_real_options = b.addOptions();
    bench_real_options.addOption(bool, "benchmark", true);

    const bench_step = b.step("bench", "Run micro-benchmarks (real mode)");

    for (bench_sources) |src| {
        const bench_smoke = b.addTest(.{
            .root_source_file = b.path(src.path),
            .target = target,
            .optimize = optimize,
        });
        bench_smoke.root_module.addImport("stdx", stdx_module);
        bench_smoke.root_module.addOptions("build_options", build_options);
        bench_smoke.root_module.addOptions("test_options", bench_smoke_options);
        if (src.needs_sqlite) link_sqlite(bench_smoke);
        const run_bench_smoke = b.addRunArtifact(bench_smoke);
        run_bench_smoke.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
        unit_test_step.dependOn(&run_bench_smoke.step);

        const bench_real = b.addTest(.{
            .root_source_file = b.path(src.path),
            .target = target,
            .optimize = optimize,
        });
        bench_real.root_module.addImport("stdx", stdx_module);
        bench_real.root_module.addOptions("build_options", build_options);
        bench_real.root_module.addOptions("test_options", bench_real_options);
        if (src.needs_sqlite) link_sqlite(bench_real);
        const bench_run = b.addRunArtifact(bench_real);
        bench_run.has_side_effects = true;
        bench_step.dependOn(&bench_run.step);
    }
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
        build_ci_step(b, step_ci, &.{ "scan", "--", "src/handlers/",
            "--routes-zig=src/generated/routes.generated.zig",
            "--manifest=src/generated/manifest.json",
        });
        // Freshness check — committed codegen outputs must match the scanner.
        // The manifest no longer embeds source line numbers (they polluted
        // the diff on every unrelated handler edit), so it is stable under
        // handler-body edits and can be freshness-checked like the routes.
        // A manual scan that clobbers `generated/manifest.json` with a
        // non-canonical source dir will now fail CI loudly.
        const freshness = b.addSystemCommand(&.{
            "git",                "diff",                            "--exit-code",
            "src/generated/routes.generated.zig", "src/generated/manifest.json",
        });
        freshness.setName("freshness check: generated/");
        step_ci.dependOn(&freshness.step);
        // Unit tests.
        build_ci_step(b, step_ci, &.{"unit-test"});
        // Benchmark pipeline probe — runs every primitive + pipeline
        // bench end-to-end on the CI runner. NOT a regression gate
        // (assert_budget fires only in smoke mode, inside unit-test);
        // this confirms the bench pipeline builds and executes on
        // ubuntu-22.04. Phase F recalibrates budgets against output
        // from this exact runner class.
        build_ci_step(b, step_ci, &.{"bench"});
        // Simulation tests.
        build_ci_step(b, step_ci, &.{"test"});
        // Cross-language adapter tests (Level 1: binary protocol boundary).
        // Must run after unit-test which generates the binary vectors.
        build_ci_step(b, step_ci, &.{"test-adapter"});
        // Fuzz smoke — Linux-only for now (replay fuzzer has macOS file IO issues).
        // Fuzz smoke — all fuzzers use SimIO/FuzzIO, no platform-specific syscalls.
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
        // Example project integration test (Level 2: full handler logic).
        // ci.zig builds the focus binary + symlinks it before running examples.
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
