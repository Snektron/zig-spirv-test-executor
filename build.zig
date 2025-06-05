const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opencl = b.dependency("opencl", .{
        .target = target,
        .optimize = optimize,
    }).module("opencl");

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");

    const vk_gen = b.dependency("vulkan_zig", .{}).artifact("vulkan-zig-generator");
    const vk_gen_cmd = b.addRunArtifact(vk_gen);
    vk_gen_cmd.addFileArg(registry);

    const exe = b.addExecutable(.{
        .name = "zig-spirv-test-executor",
        .root_source_file = b.path("src/executor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addImport("opencl", opencl);
    exe.root_module.addAnonymousImport("vulkan", .{
        .root_source_file = vk_gen_cmd.addOutputFileArg("vk.zig"),
    });
    exe.linkSystemLibrary("SPIRV-Tools-shared");
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_kernel = b.addTest(.{
        .name = "test",
        .root_source_file = b.path("src/test_kernel.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .spirv64,
            .os_tag = .opencl,
            .abi = .gnu,
            .cpu_features_add = std.Target.spirv.featureSet(&.{ .int64, .float64, .float16 }),
        }),
        .optimize = optimize,
        .use_llvm = false,
    });

    const run_test = b.addRunArtifact(test_kernel);

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&run_test.step);
}
