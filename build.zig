const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-spirv-executor",
        .root_source_file = .{ .path = "src/executor.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibC();
    exe.linkSystemLibraryName("OpenCL");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_kernel = b.addTest(.{
        .name = "test",
        .root_source_file = .{ .path = "src/test_kernel.zig" },
        .target = std.zig.CrossTarget.parse(.{
            .arch_os_abi = "spirv64-opencl",
            .cpu_features = "generic+Int64+Int16+Int8",
        }) catch unreachable,
        .optimize = optimize,
    });
    test_kernel.setTestRunner("src/test_runner.zig");
    // TODO: This should be fixed in Zig.
    test_kernel.setExecCmd(&[_]?[]const u8{ "zig-out/bin/zig-spirv-executor", "-v", null });
    test_kernel.step.dependOn(b.getInstallStep());
    // TODO: This should be fixed for the SPIR-V backend.
    test_kernel.bundle_compiler_rt = false;

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&test_kernel.step);
}
