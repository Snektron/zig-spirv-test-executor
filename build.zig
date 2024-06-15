const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opencl = b.dependency("opencl", .{
        .target = target,
        .optimize = optimize,
    }).module("opencl");

    const exe = b.addExecutable(.{
        .name = "zig-spirv-test-executor",
        .root_source_file = b.path("src/executor.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe.root_module.addImport("opencl", opencl);
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
            .cpu_features_add = std.Target.spirv.featureSet(&.{ .Int64, .Int16, .Int8, .Float64, .Float16 }),
        }),
        .optimize = optimize,
        // .test_runner = b.path("src/test_runner.zig"),
        .use_llvm = false,
    });

    test_kernel.test_server_mode = false;
    const run_test = b.addRunArtifact(test_kernel);

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&run_test.step);
}
