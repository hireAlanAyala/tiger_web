const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    // --- Simulation tests ---
    const sim_tests = b.addTest(.{
        .root_source_file = b.path("sim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_sim_tests = b.addRunArtifact(sim_tests);
    const test_step = b.step("test", "Run simulation tests");
    test_step.dependOn(&run_sim_tests.step);

    // --- Unit tests for individual modules ---
    const modules = [_][]const u8{
        "message.zig",
        "state_machine.zig",
        "http.zig",
        "marks.zig",
        "schema.zig",
        "tracer.zig",
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
}
