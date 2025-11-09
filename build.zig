const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const regent = b.dependency(
        "regent",
        .{ .target = target, .optimize = optimize },
    ).module("regent");

    const tattletale = b.addModule("tattletale", .{
        .root_source_file = b.path("tattletale.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "regent",
                .module = regent,
            },
        },
    });

    const tests = b.addTest(.{
        .root_module = b.addModule("test", .{
            .root_source_file = b.path("test/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{
                    .name = "regent",
                    .module = regent,
                },
                .{
                    .name = "tattletale",
                    .module = tattletale,
                },
            },
        }),
    });

    const testArtifact = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&testArtifact.step);
}
