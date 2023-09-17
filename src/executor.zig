const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("CL/opencl.h");
});

const spirv = struct {
    const Word = u32;
    const magic: Word = 0x07230203;

    // magic + version + generator + bound + schema
    const header_size = 5;

    // We only really care about these instructions, so no need to pull in the entire spir-v spec here.
    const OpSourceExtension = 4;
    const OpEntryPoint = 15;
};

pub const std_options = struct {
    pub const log_level = .debug;
    pub const logFn = log;
};

var log_verbose: bool = false;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (@intFromEnum(level) <= @intFromEnum(std.log.Level.info) or log_verbose) {
        const prefix = comptime level.asText();
        std.debug.print(prefix ++ ": " ++ format ++ "\n", args);
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn checkCl(status: c.cl_int) !void {
    return switch (status) {
        c.CL_SUCCESS => {},
        c.CL_DEVICE_NOT_FOUND => error.DeviceNotFound,
        c.CL_DEVICE_NOT_AVAILABLE => error.DeviceNotAvailable,
        c.CL_COMPILER_NOT_AVAILABLE => error.CompilerNotAvailable,
        c.CL_MEM_OBJECT_ALLOCATION_FAILURE => error.MemObjectAllocationFailure,
        c.CL_OUT_OF_RESOURCES => error.OutOfResources,
        c.CL_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        c.CL_PROFILING_INFO_NOT_AVAILABLE => error.ProfilingInfoNotAvailable,
        c.CL_MEM_COPY_OVERLAP => error.MemCopyOverlap,
        c.CL_IMAGE_FORMAT_MISMATCH => error.ImageFormatMismatch,
        c.CL_IMAGE_FORMAT_NOT_SUPPORTED => error.ImageFormatNotSupported,
        c.CL_BUILD_PROGRAM_FAILURE => error.BuildProgramFailure,
        c.CL_MAP_FAILURE => error.MapFailure,
        c.CL_MISALIGNED_SUB_BUFFER_OFFSET => error.MisalignedSubBufferOffset,
        c.CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST => error.ExecStatusErrorForEventsInWaitList,
        c.CL_COMPILE_PROGRAM_FAILURE => error.CompileProgramFailure,
        c.CL_LINKER_NOT_AVAILABLE => error.LinkerNotAvailable,
        c.CL_LINK_PROGRAM_FAILURE => error.LinkProgramFailure,
        c.CL_DEVICE_PARTITION_FAILED => error.DevicePartitionFailed,
        c.CL_KERNEL_ARG_INFO_NOT_AVAILABLE => error.KernelArgInfoNotAvailable,
        c.CL_INVALID_VALUE => error.InvalidValue,
        c.CL_INVALID_DEVICE_TYPE => error.InvalidDeviceType,
        c.CL_INVALID_PLATFORM => error.InvalidPlatform,
        c.CL_INVALID_DEVICE => error.InvalidDevice,
        c.CL_INVALID_CONTEXT => error.InvalidContext,
        c.CL_INVALID_QUEUE_PROPERTIES => error.InvalidQueueProperties,
        c.CL_INVALID_COMMAND_QUEUE => error.InvalidCommandQueue,
        c.CL_INVALID_HOST_PTR => error.InvalidHostPtr,
        c.CL_INVALID_MEM_OBJECT => error.InvalidMemObject,
        c.CL_INVALID_IMAGE_FORMAT_DESCRIPTOR => error.InvalidImageFormatDescriptor,
        c.CL_INVALID_IMAGE_SIZE => error.InvalidImageSize,
        c.CL_INVALID_SAMPLER => error.InvalidSampler,
        c.CL_INVALID_BINARY => error.InvalidBinary,
        c.CL_INVALID_BUILD_OPTIONS => error.InvalidBuildOptions,
        c.CL_INVALID_PROGRAM => error.InvalidProgram,
        c.CL_INVALID_PROGRAM_EXECUTABLE => error.InvalidProgramExecutable,
        c.CL_INVALID_KERNEL_NAME => error.InvalidKernelName,
        c.CL_INVALID_KERNEL_DEFINITION => error.InvalidKernelDefinition,
        c.CL_INVALID_KERNEL => error.InvalidKernel,
        c.CL_INVALID_ARG_INDEX => error.InvalidArgIndex,
        c.CL_INVALID_ARG_VALUE => error.InvalidArgValue,
        c.CL_INVALID_ARG_SIZE => error.InvalidArgSize,
        c.CL_INVALID_KERNEL_ARGS => error.InvalidKernelArgs,
        c.CL_INVALID_WORK_DIMENSION => error.InvalidWorkDimension,
        c.CL_INVALID_WORK_GROUP_SIZE => error.InvalidWorkGroupSize,
        c.CL_INVALID_WORK_ITEM_SIZE => error.InvalidWorkItemSize,
        c.CL_INVALID_GLOBAL_OFFSET => error.InvalidGlobalOffset,
        c.CL_INVALID_EVENT_WAIT_LIST => error.InvalidEventWaitList,
        c.CL_INVALID_EVENT => error.InvalidEvent,
        c.CL_INVALID_OPERATION => error.InvalidOperation,
        c.CL_INVALID_GL_OBJECT => error.InvalidGlObject,
        c.CL_INVALID_BUFFER_SIZE => error.InvalidBufferSize,
        c.CL_INVALID_MIP_LEVEL => error.InvalidMipLevel,
        c.CL_INVALID_GLOBAL_WORK_SIZE => error.InvalidGlobalWorkSize,
        c.CL_INVALID_PROPERTY => error.InvalidProperty,
        c.CL_INVALID_IMAGE_DESCRIPTOR => error.InvalidImageDescriptor,
        c.CL_INVALID_COMPILER_OPTIONS => error.InvalidCompilerOptions,
        c.CL_INVALID_LINKER_OPTIONS => error.InvalidLinkerOptions,
        c.CL_INVALID_DEVICE_PARTITION_COUNT => error.InvalidDevicePartitionCount,
        c.CL_INVALID_PIPE_SIZE => error.InvalidPipeSize,
        c.CL_INVALID_DEVICE_QUEUE => error.InvalidDeviceQueue,
        c.CL_INVALID_SPEC_ID => error.InvalidSpecId,
        c.CL_MAX_SIZE_RESTRICTION_EXCEEDED => error.MaxSizeRestrictionExceeded,
        else => error.Unknown,
    };
}

const Options = struct {
    platform: ?[]const u8,
    device: ?[]const u8,
    reducing: bool,
    verbose: bool,
    module: []const u8,
    pocl_workaround: bool,
};

fn parseArgs(arena: Allocator) !Options {
    var args = try std.process.argsWithAllocator(arena);
    _ = args.next(); // executable name

    var platform: ?[]const u8 = std.os.getenv("ZVX_PLATFORM");
    var device: ?[]const u8 = std.os.getenv("ZVX_DEVICE");
    var verbose: bool = std.os.getenv("ZVX_VERBOSE") != null;
    var help: bool = false;
    var module: ?[]const u8 = null;
    var reducing: bool = false;
    var pocl_workaround: bool = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "-p")) {
            platform = args.next() orelse fail("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
            device = args.next() orelse fail("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--reducing")) {
            reducing = true;
        } else if (std.mem.eql(u8, arg, "--pocl-workaround-names")) {
            pocl_workaround = true;
        } else if (module == null) {
            module = arg;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }

    if (help) {
        const out = std.io.getStdOut();
        try out.writer().writeAll(
            \\usage: zig-spirv-executor [options...] <spir-v module path>
            \\
            \\This program can be used to execute tests in a SPIR-V binary produced by
            \\`zig test`, together with zig-spirv-runner.zig. For example, to run all tests
            \\in a zig file under spir-v, use
            \\
            \\    zig test \
            \\        --test-cmd zig-spirv-executor --test-cmd-bin \
            \\        --test-runner src/test_runner.zig \
            \\        file.zig
            \\
            \\Alternatively, this program can also be used to test a standalone executable,
            \\as long as every entry point in the spir-v module to test is a kernel, and
            \\every entrypoint in the module has the signature `fn(result: *u32) void`.
            \\`result` must be set to 1 if the test passes, or left 0 if the test fails.
            \\
            \\Options:
            \\--platform -p <platform>  OpenCL platform name to use. By default, uses the
            \\                          first platform that has any devices available.
            \\                          Note that the platform must support the
            \\                          'cl_khr_il_program' extension.
            \\--device -d <device>      OpenCL device name to use. If --platform is left
            \\                          unspecified, all devices of all platforms are
            \\                          matched. By default, uses the first device of the
            \\                          platform.
            \\--verbose -v              Turn on verbose logging.
            \\--reducing                Enable 'reducing' mode. This mode makes the executor
            \\                          always return 0 so that compile errors may be
            \\                          reduced with spirv-reduce and ./reduce-segv.sh.
            \\--pocl-workaround-names   Work around a crash in POCL if the entry point contains
            \\                          special characters. This renames those entry points so
            \\                          that they no longer crash.
            \\--help -h                 Show this message and exit.
            \\
        );
        std.process.exit(0);
    }

    return .{
        .platform = platform,
        .device = device,
        .verbose = verbose,
        .reducing = reducing,
        .module = module orelse fail("missing required argument <spir-v module path>", .{}),
        .pocl_workaround = pocl_workaround,
    };
}

fn platformName(arena: Allocator, platform: c.cl_platform_id) ![]const u8 {
    var name_size: usize = undefined;
    try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, 0, null, &name_size));
    const name = try arena.alloc(u8, name_size);
    try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, name_size, name.ptr, null));
    return name;
}

fn platformDevices(arena: Allocator, platform: c.cl_platform_id) ![]const c.cl_device_id {
    var num_devices: c.cl_uint = undefined;
    switch (c.clGetDeviceIDs(platform, c.CL_DEVICE_TYPE_ALL, 0, null, &num_devices)) {
        c.CL_DEVICE_NOT_FOUND => return &.{},
        else => |err| try checkCl(err),
    }
    const devices = try arena.alloc(c.cl_device_id, num_devices);
    try checkCl(c.clGetDeviceIDs(platform, c.CL_DEVICE_TYPE_ALL, num_devices, devices.ptr, null));
    return devices;
}

fn deviceSupportsSpirv(arena: Allocator, device: c.cl_device_id) !bool {
    // TODO: Check for OpenCL 3.0 before accessing this function?
    var ils_size: usize = undefined;
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_ILS_WITH_VERSION, 0, null, &ils_size));
    const ils = try arena.alloc(c.cl_name_version, ils_size / @sizeOf(c.cl_name_version));
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_ILS_WITH_VERSION, ils_size, ils.ptr, null));

    for (ils) |il| {
        const name_len = std.mem.indexOfScalar(u8, &il.name, 0).?;
        const name = il.name[0..name_len];

        // TODO: Minimum version?
        if (std.mem.eql(u8, name, "SPIR-V")) {
            std.log.debug("Support for SPIR-V version {}.{}.{} detected", .{
                c.CL_VERSION_MAJOR(il.version),
                c.CL_VERSION_MINOR(il.version),
                c.CL_VERSION_PATCH(il.version),
            });
            return true;
        }
    }

    return false;
}

fn deviceName(arena: Allocator, device: c.cl_device_id) ![]const u8 {
    var name_size: usize = undefined;
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, 0, null, &name_size));
    const name = try arena.alloc(u8, name_size);
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, name_size, name.ptr, null));
    return name;
}

fn pickDevice(arena: Allocator, platform: c.cl_platform_id, query: ?[]const u8) !c.cl_device_id {
    const devices = try platformDevices(arena, platform);
    if (devices.len == 0) {
        return error.NoDevices;
    }

    if (query) |device_query| {
        for (devices) |device_id| {
            const device_name = try deviceName(arena, device_id);
            if (std.mem.indexOf(u8, device_name, device_query) != null) {
                if (!try deviceSupportsSpirv(arena, device_id)) {
                    fail("device '{s}' does not support spir-v ingestion", .{device_name});
                }
                return device_id;
            }
        }

        return error.NoSuchDevice;
    } else {
        for (devices) |device_id| {
            if (try deviceSupportsSpirv(arena, device_id)) {
                return device_id;
            }
        }

        return error.NoSpirvSupport;
    }
}

fn pickPlatformAndDevice(
    arena: Allocator,
    options: Options,
    platform: *c.cl_platform_id,
    device: *c.cl_device_id,
) !void {
    var num_platforms: c.cl_uint = undefined;
    try checkCl(c.clGetPlatformIDs(0, null, &num_platforms));
    std.log.debug("{} platform(s) available", .{num_platforms});

    if (num_platforms == 0) {
        fail("no opencl platform available", .{});
    }

    var platforms = try arena.alloc(c.cl_platform_id, num_platforms);
    try checkCl(c.clGetPlatformIDs(num_platforms, platforms.ptr, null));

    if (options.platform) |platform_query| {
        const platform_name = for (platforms) |platform_id| {
            const name = try platformName(arena, platform_id);
            if (std.mem.indexOf(u8, name, platform_query) != null) {
                platform.* = platform_id;
                break name;
            }
        } else {
            fail("no such opencl platform '{s}'", .{platform_query});
        };

        std.log.debug("using platform '{s}'", .{platform_name});

        device.* = pickDevice(arena, platform.*, options.device) catch |err| switch (err) {
            error.NoDevices => fail("no opencl devices available for platform", .{}),
            error.NoSuchDevice => fail("no such opencl device: '{s}'", .{options.device.?}),
            error.NoSpirvSupport => fail("platform has no devices that support spir-v", .{}),
            else => return err,
        };
    } else if (options.device) |device_query| {
        // Loop through all platforms to find one which matches the device
        for (platforms) |platform_id| {
            device.* = pickDevice(arena, platform_id, device_query) catch |err| switch (err) {
                error.NoDevices, error.NoSuchDevice => continue,
                error.NoSpirvSupport => unreachable,
                else => return err,
            };

            platform.* = platform_id;
            std.log.debug("using platform '{s}'", .{try platformName(arena, platform_id)});
            break;
        } else {
            fail("no such opencl device '{s}'", .{device_query});
        }
    } else {
        for (platforms) |platform_id| {
            device.* = pickDevice(arena, platform_id, null) catch |err| switch (err) {
                error.NoDevices, error.NoSpirvSupport => continue,
                error.NoSuchDevice => unreachable,
                else => return err,
            };
            platform.* = platform_id;
            std.log.debug("using platform '{s}'", .{try platformName(arena, platform_id)});
            break;
        } else {
            fail("no opencl platform that has any devices which support spir-v ingestion", .{});
        }
    }

    std.log.debug("using device '{s}'", .{try deviceName(arena, device.*)});
}

fn launchTestKernel(
    queue: c.cl_command_queue,
    program: c.cl_program,
    err_buf: c.cl_mem,
    name: []const u8,
    runtime: *c.cl_ulong,
) !u16 {
    var event: c.cl_event = null;
    defer _ = c.clReleaseEvent(event);

    var status: c.cl_int = undefined;
    const kernel = c.clCreateKernel(program, name.ptr, &status);
    try checkCl(status);
    defer _ = c.clReleaseKernel(kernel);

    try checkCl(c.clSetKernelArg(
        kernel,
        0,
        @sizeOf(c.cl_mem),
        @ptrCast(&err_buf),
    ));

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
        &event,
    ));

    var result: u16 = undefined;
    try checkCl(c.clEnqueueReadBuffer(
        queue,
        err_buf,
        c.CL_TRUE,
        0,
        @sizeOf(u16),
        &result,
        1,
        @as(*[1]c.cl_event, &event),
        null,
    ));

    var start: c.cl_ulong = undefined;
    var stop: c.cl_ulong = undefined;
    _ = c.clGetEventProfilingInfo(event, c.CL_PROFILING_COMMAND_START, @sizeOf(c.cl_ulong), &start, null);
    _ = c.clGetEventProfilingInfo(event, c.CL_PROFILING_COMMAND_END, @sizeOf(c.cl_ulong), &stop, null);
    runtime.* = (stop - start) / std.time.ns_per_us;

    return result;
}

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const options = try parseArgs(arena);
    if (options.verbose) {
        log_verbose = true;
    }

    std.log.debug("loading spir-v module '{s}'", .{options.module});

    const module_bytes = std.fs.cwd().readFileAllocOptions(
        arena,
        options.module,
        std.math.maxInt(usize),
        1 * 1024 * 1024,
        @alignOf(spirv.Word),
        null,
    ) catch |err| {
        fail("failed to open module '{s}': {s}", .{ options.module, @errorName(err) });
    };

    if (module_bytes.len % @sizeOf(spirv.Word) != 0) {
        fail("file is not a spir-v module - module size is not multiple of spir-v word size", .{});
    }

    const module = std.mem.bytesAsSlice(spirv.Word, module_bytes);

    if (module[0] != spirv.magic) {
        if (@byteSwap(module[0]) == spirv.magic) {
            fail("zig doesn't produce big-endian spir-v binaries", .{});
        }

        fail("invalid spir-v magic", .{});
    }

    std.log.debug("scanning module for entry points", .{});

    // Collect all the entry points from the spir-v binary.
    // Collect some information from the SPIR-V module:
    // - Entry points (OpEntryPoint)
    // - Error names (OpSourceExtension that starts with zig_errors:).
    var entry_points = std.ArrayList([:0]const u8).init(arena);
    var maybe_error_names: ?[]const u8 = null;
    {
        var i: usize = spirv.header_size;
        while (i < module.len) {
            const instruction_len = module[i] >> 16;
            defer i += instruction_len;

            const opcode = module[i] & 0xFFFF;
            if (instruction_len == 0) {
                std.log.err("instruction with opcode {} at offset {} has length 0", .{ opcode, i });
                return 1;
            }

            switch (opcode) {
                spirv.OpSourceExtension => {
                    // OpSourceExtension layout:
                    // - opcode and length (1 word)
                    // - extension name (string literal, variable) <-- we want this
                    const extension_ptr = std.mem.sliceAsBytes(module[i + 1 ..]);
                    const extension = std.mem.sliceTo(extension_ptr, 0);
                    // Check if the extension has the secret zig-generated prefix.
                    if (std.mem.startsWith(u8, extension, "zig_errors:")) {
                        maybe_error_names = extension["zig_errors:".len..];
                    }
                },
                spirv.OpEntryPoint => {
                    // Entry point layout:
                    // - opcode and length (1 word)
                    // - execution model (1 word)
                    // - function reference (1 word)
                    // - name (string literal, variable) <-- we want this
                    // - interface (variable)
                    const name_ptr = std.mem.sliceAsBytes(module[i + 3 ..]);
                    const name = std.mem.sliceTo(name_ptr, 0);
                    if (options.pocl_workaround) {
                        for (name) |*char| {
                            switch (char.*) {
                                '@', '/' => char.* = ' ',
                                else => {},
                            }
                        }
                    }
                    try entry_points.append(name_ptr[0..name.len :0]);
                },
                else => {},
            }
        }
    }

    const error_names = blk: {
        const error_names = maybe_error_names orelse {
            std.log.warn("module does not have OpSourceExtension with Zig error codes", .{});
            std.log.warn("this does not look like a Zig test module", .{});
            std.log.warn("executing anyway...", .{});
            break :blk &[_][]const u8{};
        };

        var names = std.ArrayList([]const u8).init(arena);
        var it = std.mem.split(u8, error_names, ":");
        while (it.next()) |unescaped_name| {
            // Zig error names are escaped here in URI-formatting. Unescape them so we can use them.
            const name = try std.Uri.unescapeString(arena, unescaped_name);
            try names.append(name);
        }
        break :blk names.items;
    };

    std.log.debug("module has {} entry point(s)", .{entry_points.items.len});

    if (entry_points.items.len == 0) {
        // Nothing to test.
        return 0;
    }

    var platform: c.cl_platform_id = undefined;
    var device: c.cl_device_id = undefined;
    try pickPlatformAndDevice(arena, options, &platform, &device);

    var status: c.cl_int = undefined;

    const properties = [_]c.cl_context_properties{
        c.CL_CONTEXT_PLATFORM,
        @bitCast(@intFromPtr(platform)),
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
        @ptrCast(module_bytes.ptr),
        module_bytes.len,
        &status,
    );
    try checkCl(status);
    defer _ = c.clReleaseProgram(program);

    std.log.debug("building program", .{});
    status = c.clBuildProgram(program, 1, &device, null, null, null);
    if (status == c.CL_BUILD_PROGRAM_FAILURE) {
        var build_log_size: usize = undefined;
        try checkCl(c.clGetProgramBuildInfo(
            program,
            device,
            c.CL_PROGRAM_BUILD_LOG,
            0,
            null,
            &build_log_size,
        ));
        const build_log = try arena.alloc(u8, build_log_size);
        try checkCl(c.clGetProgramBuildInfo(
            program,
            device,
            c.CL_PROGRAM_BUILD_LOG,
            build_log_size,
            build_log.ptr,
            null,
        ));
        std.log.err("Failed to build program. Error log: \n{s}\n", .{build_log});
    }
    try checkCl(status);
    std.log.debug("program built successfully", .{});

    const buf = c.clCreateBuffer(
        context,
        c.CL_MEM_READ_WRITE,
        @sizeOf(u16),
        null,
        &status,
    );
    try checkCl(status);

    var progress = std.Progress{};
    const root_node = progress.start("Test", entry_points.items.len);

    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var skip_count: usize = 0;
    for (entry_points.items) |name| {
        var test_node = root_node.start(name, 0);
        test_node.activate();
        defer test_node.end();
        progress.refresh();

        var runtime: c_ulong = undefined;
        const error_code = launchTestKernel(queue, program, buf, name, &runtime) catch |err| {
            progress.log("FAIL (OpenCL: {s})\n", .{@errorName(err)});
            fail_count += 1;
            continue;
        };

        const error_name = if (error_code < error_names.len)
            error_names[error_code]
        else
            "unknown error";
        if (error_code == 0) {
            ok_count += 1;
        } else if (std.mem.eql(u8, error_name, "SkipZigTest")) {
            skip_count += 1;
            progress.log("SKIP\n", .{});
        } else {
            fail_count += 1;
            progress.log("FAIL ({s})\n", .{error_name});
        }

        if (log_verbose) {
            progress.log("runtime: {}us\n", .{runtime});
        }
    }

    root_node.end();

    if (ok_count == entry_points.items.len) {
        std.debug.print("All {} tests passed.\n", .{ok_count});
    } else {
        std.debug.print("{} passed; {} skipped; {} failed.\n", .{ ok_count, skip_count, fail_count });
    }

    return @intFromBool(!options.reducing and fail_count != 0);
}
