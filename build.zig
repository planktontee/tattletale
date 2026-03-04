const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const regent = b.dependency(
        "regent",
        .{ .target = target, .optimize = optimize },
    ).module("regent");

    const zcasp = b.dependency(
        "zcasp",
        .{ .target = target, .optimize = optimize },
    ).module("zcasp");

    const tattletale = b.addModule("tattletale", .{
        .root_source_file = b.path("tattletale.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "regent",
                .module = regent,
            },
            .{
                .name = "zcasp",
                .module = zcasp,
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

    const exe = b.addExecutable(.{
        .name = "tattletale",
        .root_module = tattletale,
        .use_llvm = true,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
