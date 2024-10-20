const std = @import("std");
const Allocator = std.mem.Allocator;
const cl = @import("opencl");
const vk = @import("vulkan");

const c = @cImport({
    @cInclude("spirv-tools/libspirv.h");
});

const poison_error_code = 0xAAAA;

const spirv = struct {
    const Word = u32;
    const magic: Word = 0x07230203;

    const Id = Word;

    // magic + version + generator + bound + schema
    const header_size = 5;

    // We only really care about these instructions, so no need to pull in the entire spir-v spec here.
    const OpSourceExtension = 4;
    const OpName = 5;
    const OpString = 7;
    const OpLine = 8;
    const OpEntryPoint = 15;
    const OpExecutionMode = 16;
    const OpFunction = 54;
    const OpCapability = 17;

    const ExecutionMode = enum(Word) {
        Initializer = 33,
        _,
    };

    const Capability = enum(Word) {
        Shader = 1,
        Kernel = 6,
        _,
    };
};

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = log,
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
        switch (level) {
            .info => std.debug.print(format ++ "\n", args),
            else => {
                const prefix = comptime level.asText();
                std.debug.print(prefix ++ ": " ++ format ++ "\n", args);
            },
        }
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

const Options = struct {
    platform: ?[]const u8,
    device: ?[]const u8,
    reducing: bool,
    verbose: bool,
    module: []const u8,
    disable_workarounds: bool,
};

fn parseArgs(a: Allocator) !Options {
    var args = try std.process.argsWithAllocator(a);
    _ = args.next(); // executable name

    var platform: ?[]const u8 = std.posix.getenv("ZVTX_PLATFORM");
    var device: ?[]const u8 = std.posix.getenv("ZVTX_DEVICE");
    var verbose: bool = if (std.posix.getenv("ZVTX_VERBOSE")) |verbose|
        !std.mem.eql(u8, verbose, "0")
    else
        false;
    var help: bool = false;
    var module: ?[]const u8 = null;
    var reducing: bool = false;
    var disable_workarounds: bool = false;

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
        } else if (std.mem.eql(u8, arg, "--disable-workarounds")) {
            disable_workarounds = true;
        } else if (module == null) {
            module = arg;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }

    if (help) {
        const out = std.io.getStdOut();
        try out.writer().writeAll(
            \\usage: zig-spirv-test-executor [options...] <spir-v module path>
            \\
            \\This program can be used to execute tests in a SPIR-V binary produced by
            \\`zig test`, together with zig-spirv-runner.zig. For example, to run all tests
            \\in a zig file under spir-v, use
            \\
            \\    zig test \
            \\        --test-cmd zig-spirv-test-executor --test-cmd-bin \
            \\        --test-runner src/test_runner.zig \
            \\        file.zig
            \\
            \\Alternatively, this program can also be used to test a standalone executable,
            \\as long as every entry point in the spir-v module to test is a kernel, and
            \\every entrypoint in the module has the signature `fn(result: *u32) void`.
            \\`result` must be set to 1 if the test passes, or left 0 if the test fails.
            \\
            \\Options:
            \\--platform|-p <platform>  OpenCL platform or Vulkan driver name to use. By
            \\                          default, uses the first platform that has any
            \\                          devices available. Note that for OpenCL, the
            \\                          platform must support the 'cl_khr_il_program'
            \\                          extension.
            \\--device|-d <device>      OpenCL or Vulkan device name to use. If --platform
            \\                          is left unspecified, all devices of all platforms
            \\                          are matched. By default, uses the first device of
            \\                          the platform.
            \\--verbose|-v              Turn on verbose logging.
            \\--reducing                Enable 'reducing' mode. This mode makes the executor
            \\                          always return 0 so that compile errors may be
            \\                          reduced with spirv-reduce and ./reduce-segv.sh.
            \\--disable-workarounds     Do not pre-process the module to work around
            \\                          platform-specific bugs.
            \\--help -h                 Show this message and exit.
            \\
            \\Environment variables:
            \\ZVTX_PLATFORM=<platform>  Does the same as --platform <platform>.
            \\ZVTX_DEVICE=<device>      Does the same as --device <device>.
            \\ZVTX_VERBOSE=<value>      Setting this to anything other than 0 does the same
            \\                          as passing --verbose.
        );
        std.process.exit(0);
    }

    return .{
        .platform = platform,
        .device = device,
        .verbose = verbose,
        .reducing = reducing,
        .module = module orelse fail("missing required argument <spir-v module path>", .{}),
        .disable_workarounds = disable_workarounds,
    };
}

const InstructionIterator = struct {
    module: []spirv.Word,
    index: usize = 0,
    offset: usize = spirv.header_size,

    const Instruction = struct {
        opcode: spirv.Word,
        index: usize,
        offset: usize,
        operands: []spirv.Word,
    };

    fn init(module: []spirv.Word) InstructionIterator {
        return .{
            .module = module,
        };
    }

    fn next(self: *InstructionIterator) ?Instruction {
        if (self.offset >= self.module.len) return null;

        const instruction_len = self.module[self.offset] >> 16;
        defer self.offset += instruction_len;
        defer self.index += 1;

        if (instruction_len == 0) {
            fail("instruction at offset {} (line {}) has length 0", .{ self.offset, self.index + 5 });
        }

        return Instruction{
            .opcode = self.module[self.offset] & 0xFFFF,
            .index = self.index,
            .offset = self.offset,
            .operands = self.module[self.offset..][1..instruction_len],
        };
    }
};

const Module = struct {
    const EntryPoint = struct {
        id: spirv.Id,
        name: [:0]u8,
    };

    const ModuleType = enum {
        shader,
        kernel,
    };

    words: []const spirv.Word,
    module_type: ModuleType,
    entry_points: []const EntryPoint,
    error_names: []const []const u8,

    fn load(a: Allocator, path: []const u8) !Module {
        std.log.debug("loading spir-v module '{s}'", .{path});

        const module_bytes = std.fs.cwd().readFileAllocOptions(
            a,
            path,
            std.math.maxInt(usize),
            1 * 1024 * 1024,
            @alignOf(spirv.Word),
            null,
        ) catch |err| {
            fail("failed to open module '{s}': {s}", .{ path, @errorName(err) });
        };

        if (module_bytes.len % @sizeOf(spirv.Word) != 0) {
            fail("file is not a SPIR-V module - module size is not multiple of SPIR-V word size", .{});
        }

        const module = std.mem.bytesAsSlice(spirv.Word, module_bytes);

        if (module[0] != spirv.magic) {
            if (@byteSwap(module[0]) == spirv.magic) {
                fail("zig doesn't produce big-endian SPIR-V binaries", .{});
            }

            fail("invalid SPIR-V magic", .{});
        }

        std.log.debug("scanning module for entry points", .{});

        var entry_points = std.ArrayList(EntryPoint).init(a);
        var maybe_error_names: ?[]const u8 = null;
        var maybe_module_type: ?ModuleType = null;

        {
            var it = InstructionIterator.init(module);
            while (it.next()) |inst| {
                switch (inst.opcode) {
                    spirv.OpCapability => {
                        // OpCapability layout:
                        // 0: capability
                        const capability: spirv.Capability = @enumFromInt(inst.operands[0]);
                        switch (capability) {
                            .Shader => maybe_module_type = .shader,
                            .Kernel => maybe_module_type = .kernel,
                            _ => {},
                        }
                    },
                    spirv.OpSourceExtension => {
                        // OpSourceExtension layout:
                        // 0: extension name (string literal, variable) <-- we want this
                        const extension_ptr = std.mem.sliceAsBytes(inst.operands);
                        const extension = std.mem.sliceTo(extension_ptr, 0);
                        // Check if the extension has the secret zig-generated prefix.
                        if (std.mem.startsWith(u8, extension, "zig_errors:")) {
                            maybe_error_names = extension["zig_errors:".len..];
                        }
                    },
                    spirv.OpEntryPoint => {
                        // OpEntryPoint layout:
                        // 0: execution model (1 word)
                        // 1: function reference (1 word)
                        // 2: name (string literal, variable) <-- we want this
                        // n: interface (variable)
                        const name_ptr = std.mem.sliceAsBytes(inst.operands[2..]);
                        const name = std.mem.sliceTo(name_ptr, 0);
                        try entry_points.append(.{
                            .id = inst.operands[1],
                            .name = name_ptr[0..name.len :0],
                        });
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

            var names = std.ArrayList([]const u8).init(a);
            var it = std.mem.splitScalar(u8, error_names, ':');
            while (it.next()) |unescaped_name| {
                // Zig error names are escaped here in URI-formatting. Unescape them so we can use them.
                const name = try a.alloc(u8, unescaped_name.len);
                try names.append(std.Uri.percentDecodeBackwards(name, unescaped_name));
            }
            break :blk names.items;
        };

        const module_type = maybe_module_type orelse fail("kernel has no OpCapability Kernel and no OpCapability Shader", .{});
        try validate(a, module, module_type);

        return .{
            .words = module,
            .module_type = module_type,
            .entry_points = entry_points.items,
            .error_names = error_names,
        };
    }

    fn errorName(self: Module, error_code: u32) ?[]const u8 {
        return if (error_code < self.error_names.len)
            self.error_names[error_code]
        else
            null;
    }

    fn validate(a: Allocator, module: []u32, module_type: ModuleType) !void {
        const target_env: c_uint = switch (module_type) {
            .shader => c.SPV_ENV_VULKAN_1_3,
            .kernel => c.SPV_ENV_OPENCL_2_2,
        };
        const context = c.spvContextCreate(target_env);
        std.debug.assert(context != null); // Assume the context is always valid.
        defer c.spvContextDestroy(context);

        var diagnostic: c.spv_diagnostic = null;
        defer c.spvDiagnosticDestroy(diagnostic);
        switch (c.spvValidateBinary(context, module.ptr, module.len, &diagnostic)) {
            c.SPV_SUCCESS => return,
            else => |code| if (diagnostic == null) {
                fail("spirv-tool returned error {} without diagnostic", .{code});
            },
        }

        const err_index = diagnostic.*.position.index;
        const msg = diagnostic.*.@"error";

        // Add 5 to the index to get the line number, as there are some comments with
        // spirv-dis.
        std.log.err("validation failed at line {}: {s}", .{ err_index + 5, msg });

        // Attempt to find more details about where this error was generated.
        const Position = struct {
            file_id: spirv.Word,
            line: u32,
            column: u32,
        };

        var maybe_func_id: ?spirv.Word = null;
        var maybe_pos: ?Position = null;
        {
            var it = InstructionIterator.init(module);
            while (it.next()) |inst| {
                if (inst.index >= err_index) break;

                switch (inst.opcode) {
                    spirv.OpFunction => {
                        // 0: result type
                        // 1: result id
                        // 2: function control
                        // 3: function type
                        maybe_func_id = inst.operands[1];
                    },
                    spirv.OpLine => {
                        // 0: file
                        // 1: line
                        // 2: column
                        maybe_pos = Position{
                            .file_id = inst.operands[0],
                            .line = inst.operands[1],
                            .column = inst.operands[2],
                        };
                    },
                    else => {},
                }
            }
        }

        var maybe_func_name: ?[]const u8 = null;
        var maybe_source_file: ?[]const u8 = null;
        {
            var it = InstructionIterator.init(module);
            while (it.next()) |inst| {
                switch (inst.opcode) {
                    spirv.OpName => if (maybe_func_id) |id| {
                        // 0: target
                        // 1: name
                        if (inst.operands[0] == id) {
                            const bytes = std.mem.sliceAsBytes(inst.operands[1..]);
                            maybe_func_name = std.mem.sliceTo(bytes, 0);
                        }
                    },
                    spirv.OpString => if (maybe_pos) |pos| {
                        // 0: target
                        // 1: name
                        if (inst.operands[0] == pos.file_id) {
                            const bytes = std.mem.sliceAsBytes(inst.operands[1..]);
                            maybe_source_file = std.mem.sliceTo(bytes, 0);
                        }
                    },
                    else => {},
                }
            }
        }

        if (maybe_pos) |pos| {
            if (maybe_source_file) |file| {
                std.log.err("at {s}:{}:{}", .{ file, pos.line, pos.column });

                try dumpSourceLine(a, file, pos.line, pos.column);
            } else {
                std.log.err("at <unknown>:{}:{}", .{ pos.line, pos.column });
            }
        }

        if (maybe_func_id) |id| {
            if (maybe_func_name) |name| {
                std.log.err("in function %{} ({s})", .{ id, name });
            } else {
                std.log.err("in function %{} (<unknown>)", .{id});
            }
        }

        std.process.exit(1);
    }

    fn dumpSourceLine(a: Allocator, path: []const u8, line: u32, column: u32) !void {
        const source = std.fs.cwd().readFileAlloc(a, path, std.math.maxInt(usize)) catch |err| {
            std.log.debug("couldn't open source file: {s}", .{@errorName(err)});
            return;
        };

        var it = std.mem.splitScalar(u8, source, '\n');
        var line_index: usize = 0;
        while (it.next()) |text| {
            line_index += 1;
            if (line_index != line)
                continue;

            const padding = try a.alloc(u8, column - 1);
            defer a.free(padding);
            @memset(padding, ' ');

            std.log.err("{s}", .{text});
            std.log.err("{s}^", .{padding});

            break;
        }
    }

    fn fixupKernelNamesForPOCL(self: Module) void {
        std.log.debug("fixing up kernel names for pocl", .{});
        for (self.entry_points) |entry_point| {
            for (entry_point.name) |*char| {
                switch (char.*) {
                    '@', '/' => char.* = ' ',
                    else => {},
                }
            }
        }
    }
};

pub const OpenCL = struct {
    const KnownPlatform = enum {
        intel,
        pocl,
        rusticl,
        unknown,
    };

    platform: cl.Platform,
    device: cl.Device,
    context: cl.Context,
    queue: cl.CommandQueue,
    program: cl.Program,
    err_buf: cl.Buffer(u16),
    known_platform: KnownPlatform,

    fn init(a: Allocator, module: Module, options: Options, root_node: std.Progress.Node) !OpenCL {
        const init_node = root_node.start("Initialize OpenCL", 0);
        defer init_node.end();

        std.log.debug("initializing opencl", .{});
        const platform, const device = try pickPlatformAndDevice(a, options);
        const platform_name = try platform.getName(a);
        std.log.debug("using platform '{s}'", .{platform_name});
        std.log.debug("using device '{s}'", .{try device.getName(a)});

        const known_platform: KnownPlatform = if (std.mem.eql(u8, "Intel(R) OpenCL", platform_name))
            .intel
        else if (std.mem.eql(u8, "Portable Computing Language", platform_name))
            .pocl
        else if (std.mem.eql(u8, "rusticl", platform_name))
            .rusticl
        else
            .unknown;

        if (known_platform != .unknown) {
            std.log.debug("detected known platform: {s}", .{@tagName(known_platform)});
        }

        if (!options.disable_workarounds and known_platform == .pocl) {
            module.fixupKernelNamesForPOCL();
        }

        const context = try cl.Context.create(&.{device}, .{ .platform = platform });
        errdefer context.release();

        const queue = try cl.CommandQueue.create(context, device, .{ .profiling = true });
        errdefer queue.release();

        // All spir-v kernels can be launched from the same program.
        // TODO: Check that this function is actually available, and error out otherwise.
        const program = try cl.Program.createWithIL(context, std.mem.sliceAsBytes(module.words));
        errdefer program.release();

        std.log.debug("compiling spir-v kernels", .{});
        program.build(&.{device}, "") catch |err| switch (err) {
            error.BuildProgramFailure => {
                const build_log = try program.getBuildLog(a, device);
                std.log.err("Failed to build program. Error log: \n{s}\n", .{build_log});
                std.process.exit(1);
            },
            else => return err,
        };
        std.log.debug("program built successfully", .{});

        const err_buf = try cl.Buffer(u16).create(context, .{ .read_write = true }, 1);
        errdefer err_buf.release();

        return .{
            .platform = platform,
            .device = device,
            .context = context,
            .queue = queue,
            .program = program,
            .err_buf = err_buf,
            .known_platform = known_platform,
        };
    }

    fn deinit(self: *OpenCL) void {
        self.err_buf.release();
        self.program.release();
        self.queue.release();
        self.context.release();
        self.* = undefined;
    }

    fn runTest(self: *OpenCL, name: [:0]const u8) !struct { u16, u64 } {
        const kernel = try cl.Kernel.create(self.program, name);
        defer kernel.release();

        // Poison the error code buffer with known garbage so
        // that we know if the kernel didn't write

        const write_complete = try self.queue.enqueueWriteBuffer(
            u16,
            self.err_buf,
            false,
            0,
            &.{poison_error_code},
            &.{},
        );

        try kernel.setArg(cl.Buffer(u16), 0, self.err_buf);
        const kernel_complete = try self.queue.enqueueNDRangeKernel(
            kernel,
            null,
            &.{1},
            &.{1},
            &.{write_complete},
        );
        defer kernel_complete.release();

        var result: u16 = undefined;
        const read_complete = try self.queue.enqueueReadBuffer(
            u16,
            self.err_buf,
            false,
            0,
            (&result)[0..1],
            &.{kernel_complete},
        );

        try cl.waitForEvents(&.{read_complete});

        const start = try kernel_complete.commandStartTime();
        const stop = try kernel_complete.commandEndTime();

        return .{ result, stop - start };
    }

    fn pickDevice(a: Allocator, platform: cl.Platform, query: ?[]const u8) !cl.Device {
        const available_devices = try platform.getDevices(a, cl.DeviceType.all);
        if (available_devices.len == 0) {
            return error.NoDevices;
        }

        if (query) |device_query| {
            for (available_devices) |device| {
                const name = try device.getName(a);
                if (std.mem.indexOf(u8, name, device_query) != null) {
                    if (!try deviceSupportsSpirv(a, device)) {
                        fail("device '{s}' does not support spir-v ingestion", .{name});
                    }
                    return device;
                }
            }

            return error.NoSuchDevice;
        } else {
            for (available_devices) |device| {
                if (try deviceSupportsSpirv(a, device)) {
                    return device;
                }
            }

            return error.NoSpirvSupport;
        }
    }

    fn pickPlatformAndDevice(
        a: Allocator,
        options: Options,
    ) !struct { cl.Platform, cl.Device } {
        const available_platforms = try cl.getPlatforms(a);
        std.log.debug("{} platform(s) available", .{available_platforms.len});

        if (available_platforms.len == 0) {
            fail("no opencl platform available", .{});
        }

        if (options.platform) |platform_query| {
            const platform, const name = for (available_platforms) |platform| {
                const name = try platform.getName(a);
                if (std.mem.indexOf(u8, name, platform_query) != null) {
                    break .{ platform, name };
                }
            } else {
                fail("no such opencl platform '{s}'", .{platform_query});
            };

            const device = pickDevice(a, platform, options.device) catch |err| switch (err) {
                error.NoDevices => fail("no opencl devices available for platform '{s}'", .{name}),
                error.NoSuchDevice => fail("platform '{s}' has no devices that match '{s}'", .{ name, options.device.? }),
                error.NoSpirvSupport => fail("platform '{s}' has no devices that support SPIR-V ingestion", .{name}),
                else => return err,
            };
            return .{ platform, device };
        } else if (options.device) |device_query| {
            // Loop through all platforms to find one which matches the device
            var device_found_but_doesnt_have_spirv: ?cl.Platform = null;
            for (available_platforms) |platform| {
                const device = pickDevice(a, platform, device_query) catch |err| switch (err) {
                    error.NoDevices, error.NoSuchDevice => continue,
                    error.NoSpirvSupport => {
                        // There could be other platforms that have this device, so continue,
                        // but record that we found at least one that matched this name.
                        device_found_but_doesnt_have_spirv = platform;
                        continue;
                    },
                    else => return err,
                };

                return .{ platform, device };
            }

            if (device_found_but_doesnt_have_spirv) |platform| {
                const name = try platform.getName(a);
                fail("platform '{s}' has a device that matches '{s}', but it doesn't support SPIR-V ingestion", .{ name, device_query });
            } else {
                fail("no platform has opencl device '{s}'", .{device_query});
            }
        } else {
            for (available_platforms) |platform| {
                const device = pickDevice(a, platform, null) catch |err| switch (err) {
                    error.NoDevices, error.NoSpirvSupport => continue,
                    error.NoSuchDevice => unreachable,
                    else => return err,
                };
                return .{ platform, device };
            } else {
                fail("no opencl platform that has any devices which support SPIR-V ingestion", .{});
            }
        }
    }

    fn deviceSupportsSpirv(a: Allocator, device: cl.Device) !bool {
        // TODO: Check for OpenCL 3.0 before accessing this function?
        const ils = try device.getILsWithVersion(a);

        for (ils) |il| {
            // TODO: Minimum version?
            if (std.mem.eql(u8, il.getName(), "SPIR-V")) {
                std.log.debug("Support for SPIR-V version {}.{}.{} detected", .{
                    il.version.major,
                    il.version.minor,
                    il.version.patch,
                });
                return true;
            }
        }

        return false;
    }
};

const Vulkan = struct {
    const apis: []const vk.ApiInfo = &.{
        vk.features.version_1_0,
        vk.features.version_1_1,
        vk.features.version_1_2,
    };

    const required_layers = [_][*:0]const u8{
        "VK_LAYER_KHRONOS_validation",
    };

    const BaseDispatch = vk.BaseWrapper(apis);
    const Instance = vk.InstanceProxy(apis);
    const Device = vk.DeviceProxy(apis);

    const PushConstantBuffer = extern struct {
        err_buf: vk.DeviceAddress,
    };

    const Kernel = struct {
        name: []const u8,
        pipeline_layout: vk.PipelineLayout,
        pipeline: vk.Pipeline,
    };

    lib: std.DynLib,
    vkb: BaseDispatch,
    instance: Instance,

    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    dev: Device,
    compute_queue_family: u32,
    compute_queue: vk.Queue,
    compute_queue_props: vk.QueueFamilyProperties,

    cmd_pool: vk.CommandPool,
    cmd_buf: vk.CommandBuffer,

    kernels: []Kernel,

    err_buf: vk.Buffer,
    err_buf_mem: vk.DeviceMemory,
    err_buf_addr: vk.DeviceAddress,
    err_ptr: *u16,

    query_pool: vk.QueryPool,

    fn init(a: Allocator, module: Module, options: Options, root_node: std.Progress.Node) !Vulkan {
        const init_node = root_node.start("Initialize Vulkan", 1);
        defer init_node.end();

        std.log.debug("initializing vulkan", .{});

        var self: Vulkan = undefined;

        self.lib = try std.DynLib.open("libvulkan.so.1");
        errdefer self.lib.close();

        const vk_get_instance_proc_addr = self.lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
            fail("libvulkan.so.1 doesn't provide vkGetInstanceProcAddr", .{});
        };
        self.vkb = try BaseDispatch.load(vk_get_instance_proc_addr);

        const instance = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = "zig spir-v test executor",
                .application_version = vk.makeApiVersion(0, 0, 0, 0),
                .p_engine_name = "super cool engine",
                .engine_version = vk.makeApiVersion(0, 0, 0, 0),
                .api_version = vk.API_VERSION_1_3,
            },
            .enabled_layer_count = required_layers.len,
            .pp_enabled_layer_names = &required_layers,
        }, null);

        const vki = try a.create(Instance.Wrapper);
        vki.* = try Instance.Wrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        const pdevs = try self.instance.enumeratePhysicalDevicesAlloc(a);
        std.log.debug("{} device(s) are available", .{pdevs.len});
        if (pdevs.len == 0) {
            fail("no vulkan devices available", .{});
        }

        const features10: vk.PhysicalDeviceFeatures = .{
            .shader_int_16 = vk.TRUE,
            .shader_int_64 = vk.TRUE,
            .shader_float_64 = vk.TRUE,
        };

        var features11: vk.PhysicalDeviceVulkan11Features = .{
            .storage_push_constant_16 = vk.TRUE,
        };

        var features12: vk.PhysicalDeviceVulkan12Features = .{
            .p_next = @ptrCast(&features11),
            .buffer_device_address = vk.TRUE,
            .shader_float_16 = vk.TRUE,
            .shader_int_8 = vk.TRUE,
        };

        for (pdevs) |pdev| {
            var props12: vk.PhysicalDeviceVulkan12Properties = undefined;
            props12.s_type = .physical_device_vulkan_1_2_properties;
            props12.p_next = null;

            var props2: vk.PhysicalDeviceProperties2 = .{
                .p_next = @ptrCast(&props12),
                .properties = undefined,
            };

            self.instance.getPhysicalDeviceProperties2(pdev, &props2);

            const name = std.mem.sliceTo(&props2.properties.device_name, 0);
            const driver = std.mem.sliceTo(&props12.driver_name, 0);

            if (options.device) |device_query| {
                if (std.mem.indexOf(u8, name, device_query) == null) {
                    continue;
                }
            }

            if (options.platform) |platform_query| {
                if (std.mem.indexOf(u8, driver, platform_query) == null) {
                    continue;
                }
            }

            if (!checkPhysicalDeviceFeatures(self.instance, pdev, features10, features11, features12)) {
                fail("device '{s}' does not support buffer device address", .{name});
            }

            self.pdev = pdev;
            self.props = props2.properties;
            break;
        } else {
            fail("there are no devices that support buffer device address or the specified device/platform", .{});
        }

        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        std.log.debug("using vulkan device: '{s}'", .{std.mem.sliceTo(&self.props.device_name, 0)});

        const families = try self.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, a);
        for (families, 0..) |props, i| {
            if (props.queue_flags.compute_bit) {
                self.compute_queue_family = @intCast(i);
                self.compute_queue_props = props;
                break;
            }
        } else {
            std.log.err("every vulkan device should have at least one compute queue", .{});
            std.log.err("please get yourself a better gpu driver", .{});
            fail("no compute queue", .{});
        }

        const dev = try self.instance.createDevice(self.pdev, &.{
            .p_next = @ptrCast(&features12),
            .queue_create_info_count = 1,
            .p_queue_create_infos = &.{
                .{
                    .queue_family_index = self.compute_queue_family,
                    .queue_count = 1,
                    .p_queue_priorities = &.{1},
                },
            },
            .p_enabled_features = &features10,
        }, null);

        const vkd = try a.create(Device.Wrapper);
        vkd.* = try Device.Wrapper.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr);
        self.dev = Device.init(dev, vkd);
        errdefer self.dev.destroyDevice(null);

        self.compute_queue = self.dev.getDeviceQueue(self.compute_queue_family, 0);

        self.cmd_pool = try self.dev.createCommandPool(&.{
            .flags = .{},
            .queue_family_index = self.compute_queue_family,
        }, null);
        errdefer self.dev.destroyCommandPool(self.cmd_pool, null);

        var cmd_bufs: [1]vk.CommandBuffer = undefined;
        try self.dev.allocateCommandBuffers(&.{
            .command_pool = self.cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, &cmd_bufs);
        self.cmd_buf = cmd_bufs[0];

        std.log.debug("compiling shaders", .{});
        const shader = try self.dev.createShaderModule(&.{
            .code_size = module.words.len * @sizeOf(spirv.Word),
            .p_code = module.words.ptr,
        }, null);
        defer self.dev.destroyShaderModule(shader, null);

        self.kernels = try a.alloc(Kernel, module.entry_points.len);
        for (self.kernels) |*k| k.* = .{
            .name = undefined,
            .pipeline_layout = .null_handle,
            .pipeline = .null_handle,
        };
        errdefer self.deinitKernels();

        const kernels_node = root_node.start("Compiling Kernels", module.entry_points.len);
        for (module.entry_points, 0..) |entry_point, i| {
            const msg = try std.fmt.allocPrint(a, "compiling kernel '{s}'", .{entry_point.name});
            const init_kernel_node = kernels_node.start(msg, 0);
            defer init_kernel_node.end();
            // std.log.debug("[{}/{}] compiling kernel {s}", .{i + 1, module.entry_points.len, name});
            self.kernels[i] = try self.initKernel(entry_point.name, shader);
        }
        kernels_node.end();

        self.err_buf = try self.dev.createBuffer(&.{
            .size = @sizeOf(u16),
            .usage = .{
                .transfer_dst_bit = true,
                .storage_buffer_bit = true,
                .shader_device_address_bit = true,
            },
            .sharing_mode = .exclusive,
        }, null);
        errdefer self.dev.destroyBuffer(self.err_buf, null);

        const mem_reqs = self.dev.getBufferMemoryRequirements(self.err_buf);
        self.err_buf_mem = try self.allocate(mem_reqs, .{
            .host_visible_bit = true,
            .host_coherent_bit = true,
            .device_local_bit = true,
        }, true);
        errdefer self.dev.freeMemory(self.err_buf_mem, null);
        try self.dev.bindBufferMemory(self.err_buf, self.err_buf_mem, 0);

        self.err_buf_addr = self.dev.getBufferDeviceAddress(&.{
            .buffer = self.err_buf,
        });

        std.log.debug("error buffer device address: 0x{x:0>16}", .{self.err_buf_addr});

        self.err_ptr = @ptrCast(@alignCast(try self.dev.mapMemory(self.err_buf_mem, 0, @sizeOf(u16), .{})));

        self.query_pool = try self.dev.createQueryPool(&.{
            .query_type = .timestamp,
            .query_count = 2, // start and end
        }, null);

        return self;
    }

    fn deinit(self: *Vulkan) void {
        self.dev.destroyQueryPool(self.query_pool, null);
        self.dev.unmapMemory(self.err_buf_mem);
        self.dev.freeMemory(self.err_buf_mem, null);
        self.dev.destroyBuffer(self.err_buf, null);
        self.deinitKernels();
        self.dev.destroyCommandPool(self.cmd_pool, null);
        self.dev.destroyDevice(null);
        self.instance.destroyInstance(null);
        self.lib.close();
        self.* = undefined;
    }

    fn deinitKernels(self: *Vulkan) void {
        for (self.kernels) |k| {
            self.dev.destroyPipelineLayout(k.pipeline_layout, null);
            self.dev.destroyPipeline(k.pipeline, null);
        }
    }

    fn checkPhysicalDeviceFeatures(
        instance: Instance,
        pdev: vk.PhysicalDevice,
        expected_features10: vk.PhysicalDeviceFeatures,
        expected_features11: vk.PhysicalDeviceVulkan11Features,
        expected_features12: vk.PhysicalDeviceVulkan12Features,
    ) bool {
        var features12: vk.PhysicalDeviceVulkan12Features = .{};
        var features11: vk.PhysicalDeviceVulkan11Features = .{
            .p_next = @ptrCast(&features12),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{
            .p_next = @ptrCast(&features11),
            .features = .{},
        };
        instance.getPhysicalDeviceFeatures2(pdev, &features2);
        const features10 = &features2.features;

        inline for (
            .{ vk.PhysicalDeviceFeatures, vk.PhysicalDeviceVulkan11Features, vk.PhysicalDeviceVulkan12Features },
            .{ &expected_features10, &expected_features11, &expected_features12 },
            .{ features10, &features11, &features12 },
        ) |T, expected, actual| {
            inline for (std.meta.fields(T)) |field| {
                if (field.type == vk.Bool32 and @field(expected, field.name) == vk.TRUE and @field(actual, field.name) == vk.FALSE) {
                    return false;
                }
            }
        }

        return true;
    }

    fn initKernel(self: *Vulkan, name: [:0]const u8, shader: vk.ShaderModule) !Kernel {
        // TODO: Push constant range and stuff
        const pipeline_layout = try self.dev.createPipelineLayout(&.{
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &.{
                .{
                    .stage_flags = .{ .compute_bit = true },
                    .offset = 0,
                    .size = @sizeOf(PushConstantBuffer),
                },
            },
        }, null);

        var pipelines: [1]vk.Pipeline = undefined;
        _ = try self.dev.createComputePipelines(
            .null_handle,
            1,
            &.{
                .{
                    .stage = .{
                        .stage = .{ .compute_bit = true },
                        .module = shader,
                        .p_name = name,
                    },
                    .layout = pipeline_layout,
                    .base_pipeline_handle = .null_handle,
                    .base_pipeline_index = 0,
                },
            },
            null,
            &pipelines,
        );

        return .{
            .name = name,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipelines[0],
        };
    }

    pub fn findMemoryTypeIndex(self: *Vulkan, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: *Vulkan, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags, allocate_device_address: bool) !vk.DeviceMemory {
        const allocate_flags_info: vk.MemoryAllocateFlagsInfo = .{
            .flags = .{
                .device_address_bit = true,
            },
            .device_mask = 0x0,
        };

        return try self.dev.allocateMemory(&.{
            .p_next = if (allocate_device_address) &allocate_flags_info else null,
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }

    fn runTest(self: *Vulkan, name: [:0]const u8) !struct { u16, u64 } {
        self.err_ptr.* = poison_error_code;

        // TODO: Improve this
        const kernel = for (self.kernels) |k| {
            if (std.mem.eql(u8, k.name, name)) {
                break k;
            }
        } else unreachable;

        try self.dev.resetCommandPool(self.cmd_pool, .{});
        try self.dev.beginCommandBuffer(self.cmd_buf, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.dev.cmdResetQueryPool(self.cmd_buf, self.query_pool, 0, 2);

        self.dev.cmdWriteTimestamp(self.cmd_buf, .{ .compute_shader_bit = true }, self.query_pool, 0);
        self.dev.cmdBindPipeline(self.cmd_buf, .compute, kernel.pipeline);
        const push_constants: PushConstantBuffer = .{
            .err_buf = self.err_buf_addr,
        };
        self.dev.cmdPushConstants(
            self.cmd_buf,
            kernel.pipeline_layout,
            .{ .compute_bit = true },
            0,
            @sizeOf(PushConstantBuffer),
            @ptrCast(&push_constants),
        );
        self.dev.cmdDispatch(self.cmd_buf, 1, 1, 1);
        self.dev.cmdWriteTimestamp(self.cmd_buf, .{ .compute_shader_bit = true }, self.query_pool, 1);

        try self.dev.endCommandBuffer(self.cmd_buf);
        try self.dev.queueSubmit(self.compute_queue, 1, &.{
            .{
                .command_buffer_count = 1,
                .p_command_buffers = &.{self.cmd_buf},
            },
        }, .null_handle);

        try self.dev.queueWaitIdle(self.compute_queue);

        var query_results: [2]u64 = undefined;
        _ = try self.dev.getQueryPoolResults(
            self.query_pool,
            0,
            2,
            @sizeOf([2]u64),
            &query_results,
            @sizeOf(u64),
            .{ .@"64_bit" = true },
        );

        if (self.compute_queue_props.timestamp_valid_bits != 64) {
            query_results[0] &= (@as(u64, 1) << @intCast(self.compute_queue_props.timestamp_valid_bits)) - 1;
            query_results[1] &= (@as(u64, 1) << @intCast(self.compute_queue_props.timestamp_valid_bits)) - 1;
        }

        const runtime = @as(f32, @floatFromInt((query_results[1] - query_results[0]))) * self.props.limits.timestamp_period;

        const error_code = self.err_ptr.*;

        return .{ error_code, @intFromFloat(runtime) };
    }
};

fn runTests(api: anytype, module: Module, root_node: std.Progress.Node) !bool {
    const test_root_node = root_node.start("Test", module.entry_points.len);
    const have_tty = std.io.getStdErr().isTty();

    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var skip_count: usize = 0;

    for (module.entry_points, 0..) |entry_point, i| {
        const test_node = test_root_node.start(entry_point.name, 0);
        defer test_node.end();

        const log_prefix = "[{d}/{d}] {s}...";
        const log_prefix_args = .{ i + 1, module.entry_points.len, entry_point.name };

        if (!have_tty) {
            std.log.info(log_prefix, log_prefix_args);
        }

        const error_code, const runtime = api.runTest(entry_point.name) catch |err| {
            std.log.info(log_prefix ++ "FAIL (API error: {s})", log_prefix_args ++ .{@errorName(err)});
            fail_count += 1;
            continue;
        };

        const error_name = module.errorName(error_code) orelse "unknown error";
        if (error_code == 0) {
            ok_count += 1;
        } else if (std.mem.eql(u8, error_name, "SkipZigTest")) {
            skip_count += 1;
            std.log.info(log_prefix ++ "SKIP", log_prefix_args);
        } else {
            fail_count += 1;
            if (error_code == poison_error_code) {
                std.log.info(log_prefix ++ "FAIL (Kernel didn't write to error code pointer)", log_prefix_args);
            } else {
                std.log.info(log_prefix ++ "FAIL ({s} {})", log_prefix_args ++ .{ error_name, error_code });
            }
        }

        if (log_verbose) {
            std.log.info(log_prefix ++ "runtime: {} ns", log_prefix_args ++ .{runtime});
        }
    }

    test_root_node.end();

    if (ok_count == module.entry_points.len) {
        std.log.info("All {} tests passed.", .{ok_count});
    } else {
        std.log.info("{} passed; {} skipped; {} failed.", .{ ok_count, skip_count, fail_count });
    }

    return fail_count != 0;
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const options = try parseArgs(a);
    if (options.verbose) {
        log_verbose = true;
    }

    const module = try Module.load(a, options.module);
    std.log.debug("module type {s}", .{@tagName(module.module_type)});
    std.log.debug("module has {} entry point(s)", .{module.entry_points.len});
    std.log.debug("module has {} error code(s)", .{module.error_names.len});

    if (module.entry_points.len == 0) {
        // Nothing to test.
        return 0;
    }

    const root_node = std.Progress.start(.{
        .estimated_total_items = 2,
    });

    const has_fails = switch (module.module_type) {
        .kernel => blk: {
            std.log.debug("running module under opencl", .{});
            var opencl = try OpenCL.init(a, module, options, root_node);
            defer opencl.deinit();
            break :blk try runTests(&opencl, module, root_node);
        },
        .shader => blk: {
            std.log.debug("running module under vulkan", .{});
            var vulkan = try Vulkan.init(a, module, options, root_node);
            defer vulkan.deinit();
            break :blk try runTests(&vulkan, module, root_node);
        },
    };

    return @intFromBool(!options.reducing and has_fails);
}
