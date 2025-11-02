const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tattletale = b.addModule("tattletale", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "regent",
                .module = b.dependency(
                    "regent",
                    .{ .target = target, .optimize = optimize },
                ).module("regent"),
            },
        },
    });

    const lib_unit_tests = b.addTest(.{
        .root_module = tattletale,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}
