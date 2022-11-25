const std = @import("std");

const c = @cImport({
    @cInclude("CL/opencl.h");
});

const spirv = struct {
    const Word = u32;
    const magic: Word = 0x07230203;

    // magic + version + generator + bound + schema
    const header_size = 5;

    // We only really care about this instruction, so no need to pull in the entire spir-v spec here.
    const OpEntryPoint = 15;
    const entrypoint_name_offset = 3;
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn checkCl(status: c.cl_int) !void {
    if (status != c.CL_SUCCESS) {
        // TODO: Error names?
        std.log.err("opencl returned error {}", .{status});
        return error.ClError;
    }
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);

    if (args.len != 2) {
        fail("usage: zig-spirv-test-cmd <spir-v module>", .{});
    }

    const cwd = std.fs.cwd();
    const module_path = args[1];

    const module_bytes = cwd.readFileAllocOptions(
        arena,
        module_path,
        std.math.maxInt(usize),
        1 * 1024 * 1024,
        @alignOf(spirv.Word),
        null,
    ) catch |err| {
        fail("failed to open module '{s}': {s}", .{ module_path, @errorName(err) });
    };

    if (module_bytes.len % @sizeOf(spirv.Word) != 0) {
        fail("file is not a spir-v module - module size is not multiple of spir-v word size", .{});
    }

    const module = std.mem.bytesAsSlice(spirv.Word, module_bytes);

    if (module[0] != spirv.magic) {
        if (@byteSwap(module[0]) != spirv.magic) {
            fail("zig doesn't produce big-endian spir-v binaries", .{});
        }
    }

    // Collect all the entry points from the spir-v binary.
    var entry_points = std.ArrayList([:0]const u8).init(arena);
    var i: usize = spirv.header_size;
    while (i < module.len) {
        const instruction_len = module[i] >> 16;
        defer i += instruction_len;

        const opcode = module[i] & 0xFFFF;
        if (opcode != spirv.OpEntryPoint) {
            // Dont care about this instruction.
            continue;
        }

        // Entry point layout:
        // - opcode and length (1 word)
        // - execution model (1 word)
        // - function reference (1 word)
        // - name (string literal, variable) <-- we want this
        // - interface (variable)
        const name_ptr = std.mem.sliceAsBytes(module[i + spirv.entrypoint_name_offset ..]);
        const name = std.mem.sliceTo(name_ptr, 0);
        try entry_points.append(name_ptr[0 .. name.len :0]);
    }

    std.log.debug("module has {} entry points", .{entry_points.items.len});

    if (entry_points.items.len == 0) {
        // Nothing to test.
        return;
    }

    // TODO: Improve platform/device selection. For now just pick the first available device
    const platform = blk: {
        var platform: c.cl_platform_id = undefined;
        var num_platforms: c.cl_uint = undefined;
        try checkCl(c.clGetPlatformIDs(1, &platform, &num_platforms));

        if (num_platforms == 0) {
            fail("no opencl platform available", .{});
        }

        var name_size: usize = undefined;
        try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, 0, null, &name_size));
        const name = try arena.alloc(u8, name_size);
        try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, name_size, name.ptr, null));
        std.log.debug("using platform '{s}'", .{name});

        break :blk platform;
    };

    const device = blk: {
        var device: c.cl_device_id = undefined;
        var num_devices: c.cl_uint = undefined;
        try checkCl(c.clGetDeviceIDs(platform, c.CL_DEVICE_TYPE_ALL, 1, &device, &num_devices));

        if (num_devices == 0) {
            fail("no opencl devices available", .{});
        }

        var name_size: usize = undefined;
        try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, 0, null, &name_size));
        const name = try arena.alloc(u8, name_size);
        try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, name_size, name.ptr, null));
        std.log.debug("using device '{s}'", .{name});

        break :blk device;
    };

    var status: c.cl_int = undefined;

    const properties = [_]c.cl_context_properties{
        c.CL_CONTEXT_PLATFORM,
        @bitCast(c.cl_context_properties, @ptrToInt(platform)),
        0,
    };

    const context = c.clCreateContext(&properties, 1, &device, null, null, &status);
    try checkCl(status);
    defer _ = c.clReleaseContext(context);

    const queue = c.clCreateCommandQueue(context, device, c.CL_QUEUE_PROFILING_ENABLE, &status);
    try checkCl(status);

    // All spir-v kernels can be launched from the same program.
    // TODO: Check that this function is actually available, and error out otherwise.
    const program = c.clCreateProgramWithIL(
        context,
        @ptrCast(*const anyopaque, module_bytes.ptr),
        module_bytes.len,
        &status,
    );
    try checkCl(status);
    defer _ = c.clReleaseProgram(program);

    try checkCl(c.clBuildProgram(program, 1, &device, null, null, null));

    for (entry_points.items) |name| {
        std.log.debug("running test for kernel '{s}'", .{name});
        const kernel = c.clCreateKernel(program, name.ptr, &status);
        try checkCl(status);
        defer _= c.clReleaseKernel(kernel);

        // TODO: Pass global result buffer.

        var kernel_completed_event: c.cl_event = undefined;
        const global_work_size: usize = 1;
        const local_work_size: usize = 1;
        try checkCl(c.clEnqueueNDRangeKernel(
            queue,
            kernel,
            1,
            null,
            &global_work_size,
            &local_work_size,
            0,
            null,
            &kernel_completed_event,
        ));

        try checkCl(c.clWaitForEvents(1, &kernel_completed_event));

        var start: c.cl_ulong = undefined;
        var stop: c.cl_ulong = undefined;
        _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_START, @sizeOf(c.cl_ulong), &start, null);
        _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_END, @sizeOf(c.cl_ulong), &stop, null);
        std.log.debug("kernel runtime: {}us", .{(stop - start) / std.time.ns_per_us});
    }
}
