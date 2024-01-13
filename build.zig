const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-spirv-executor",
        .root_source_file = .{ .path = "src/executor.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("OpenCL");
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
        .root_source_file = .{ .path = "src/test_kernel.zig" },
        // .target = std.zig.CrossTarget.parse(.{
        //     .arch_os_abi = "spirv64-opencl",
        //     .cpu_features = "generic+Int64+Int16+Int8+Float64",
        // }) catch unreachable,
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .spirv64,
            .os_tag = .opencl,
            .cpu_features_add = std.Target.spirv.featureSet(&.{.Int64, .Int16, .Int8, .Float64}),
        }),
        .optimize = optimize,
        .test_runner = "src/test_runner.zig",
        .use_llvm = false,
    });
    // TODO: This should be fixed in Zig.
    test_kernel.setExecCmd(&[_]?[]const u8{ "zig-out/bin/zig-spirv-executor", "-v", null });
    test_kernel.step.dependOn(b.getInstallStep());
    // TODO: This should be fixed for the SPIR-V backend.
    test_kernel.bundle_compiler_rt = false;
    test_kernel.step.dependOn(&exe.step);

    const run_test = b.addRunArtifact(test_kernel);

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&run_test.step);
}
