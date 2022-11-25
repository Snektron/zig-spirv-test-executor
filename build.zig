const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zig-spirv-test-cmd", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
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

    const test_kernel = b.addObject("test_kernel.spv", "src/test_kernel.zig");
    test_kernel.setTarget(.{
        .cpu_arch = .spirv64,
        .os_tag = .opencl,
    });

    const test_test_kernel = exe.run();
    test_test_kernel.addArtifactArg(test_kernel);

    const test_step = b.step("test", "Run the test kernel");
    test_step.dependOn(&test_test_kernel.step);
}
