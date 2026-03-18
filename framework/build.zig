const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("tiger_framework", .{
        .root_source_file = b.path("lib.zig"),
        .target = target,
        .optimize = optimize,
    });
}
