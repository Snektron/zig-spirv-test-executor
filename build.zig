const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const spirv_tools_dep = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize });
    const spirv_headers = b.dependency("spirv_headers", .{});
    const opencl = b.dependency("opencl", .{ .target = target, .optimize = optimize }).module("opencl");

    const vulkan = b.dependency("vulkan_zig", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    const spirv_tools = b.addTranslateC(.{
        .root_source_file = spirv_tools_dep.path("include/spirv-tools/libspirv.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const spirv = b.addTranslateC(.{
        .root_source_file = spirv_headers.path("include/spirv/unified1/spirv.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();

    const exe = b.addExecutable(.{
        .name = "zig-spirv-test-executor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "opencl", .module = opencl },
                .{ .name = "vulkan", .module = vulkan },
                .{ .name = "spirv-tools", .module = spirv_tools },
                .{ .name = "spirv", .module = spirv },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("SPIRV-Tools-shared", .{});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_kernel = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_kernel.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .spirv64,
                .os_tag = .opencl,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.spirv.cpu.opencl_v2 },
                .cpu_features_add = std.Target.spirv.featureSet(&.{
                    .int64,
                    .float64,
                    .generic_pointer,
                }),
            }),
            .optimize = optimize,
        }),
        .use_llvm = false,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
    });

    const run_test = b.addRunArtifact(exe);
    run_test.addFileArg(test_kernel.getEmittedBin());
    run_test.addPassthruArgs();

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&run_test.step);
}
