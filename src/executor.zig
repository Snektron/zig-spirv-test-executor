const std = @import("std");
const Allocator = std.mem.Allocator;
const cl = @import("opencl.zig");

const c = @cImport({
    @cInclude("spirv-tools/libspirv.h");
});

const poison_error_code = 0xAAAA;

const spirv = struct {
    const Word = u32;
    const magic: Word = 0x07230203;

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

    const ExecutionMode = enum(Word) {
        Initializer = 33,
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

const KnownPlatform = enum {
    intel,
    pocl,
    rusticl,
    unknown,
};

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
            \\--platform|-p <platform>  OpenCL platform name to use. By default, uses the
            \\                          first platform that has any devices available.
            \\                          Note that the platform must support the
            \\                          'cl_khr_il_program' extension.
            \\--device|-d <device>      OpenCL device name to use. If --platform is left
            \\                          unspecified, all devices of all platforms are
            \\                          matched. By default, uses the first device of the
            \\                          platform.
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

fn launchTestKernel(
    queue: cl.CommandQueue,
    program: cl.Program,
    err_buf: cl.Buffer(u16),
    name: [*:0]const u8,
) !struct { u16, cl.ulong } {
    const kernel = try cl.Kernel.create(program, name);
    defer kernel.release();

    // Poison the error code buffer with known garbage so
    // that we know if the kernel didn't write

    const write_complete = try queue.enqueueWriteBuffer(
        u16,
        err_buf,
        false,
        0,
        &.{poison_error_code},
        &.{},
    );

    try kernel.setArg(cl.Buffer(u16), 0, &err_buf);
    const kernel_complete = try queue.enqueueNDRangeKernel(
        kernel,
        null,
        &.{1},
        &.{1},
        &.{write_complete},
    );
    defer kernel_complete.release();

    var result: u16 = undefined;
    const read_complete = try queue.enqueueReadBuffer(
        u16,
        err_buf,
        false,
        0,
        (&result)[0..1],
        &.{kernel_complete},
    );

    try cl.waitForEvents(&.{read_complete});

    const start = try kernel_complete.commandStartTime();
    const stop = try kernel_complete.commandEndTime();
    const runtime = (stop - start) / std.time.ns_per_us;

    return .{ result, runtime };
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

fn validateModule(a: Allocator, module: []u32) !void {
    const context = c.spvContextCreate(c.SPV_ENV_UNIVERSAL_1_5); // TODO: Use OpenCL environments?
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

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const options = try parseArgs(a);
    if (options.verbose) {
        log_verbose = true;
    }

    const root_node = std.Progress.start(.{
        .estimated_total_items = 3,
    });
    const have_tty = std.io.getStdErr().isTty();

    const init_opencl_node = root_node.start("Initializing OpenCL", 0);
    std.log.debug("initializing OpenCL", .{});

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
    init_opencl_node.end();

    const load_node = root_node.start("Loading SPIR-V module", 0);
    std.log.debug("loading spir-v module '{s}'", .{options.module});

    const module_bytes = std.fs.cwd().readFileAllocOptions(
        a,
        options.module,
        std.math.maxInt(usize),
        1 * 1024 * 1024,
        @alignOf(spirv.Word),
        null,
    ) catch |err| {
        fail("failed to open module '{s}': {s}", .{ options.module, @errorName(err) });
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

    try validateModule(a, module);

    std.log.debug("scanning module for entry points", .{});

    // Collect all the entry points from the spir-v binary.
    // Collect some information from the SPIR-V module:
    // - Entry points (OpEntryPoint)
    // - Error names (OpSourceExtension that starts with zig_errors:).

    var entry_points = std.AutoArrayHashMap(spirv.Word, [:0]const u8).init(a);
    var initializers = std.ArrayList(spirv.Word).init(a);
    var maybe_error_names: ?[]const u8 = null;
    {
        var it = InstructionIterator.init(module);
        while (it.next()) |inst| {
            switch (inst.opcode) {
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
                    if (std.mem.eql(u8, name, "main")) continue;

                    if (!options.disable_workarounds and known_platform == .pocl) {
                        for (name) |*char| {
                            switch (char.*) {
                                '@', '/' => char.* = ' ',
                                else => {},
                            }
                        }
                    }
                    try entry_points.put(inst.operands[1], name_ptr[0..name.len :0]);
                },
                spirv.OpExecutionMode => {
                    // OpExecutionMode layout:
                    // 0: entry point (1 word)
                    // 1: modes... (n words)
                    const id = inst.operands[0];
                    for (inst.operands[1..]) |mode| {
                        if (@as(spirv.ExecutionMode, @enumFromInt(mode)) == .Initializer) {
                            try initializers.append(id);
                            break;
                        }
                    }
                },
                else => {},
            }
        }

        // Make sure that we wont try to execute the initializer as kernel.
        for (initializers.items) |id| {
            _ = entry_points.swapRemove(id);
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

    std.log.debug("module has {} entry point(s)", .{entry_points.count()});
    std.log.debug("module has {} initializer(s)", .{initializers.items.len});
    std.log.debug("module has {} error code(s)", .{error_names.len});

    if (entry_points.count() == 0) {
        // Nothing to test.
        return 0;
    }

    const context = try cl.Context.create(&.{device}, .{ .platform = platform });
    defer context.release();

    const queue = try cl.CommandQueue.create(context, device, .{ .profiling = true });
    defer queue.release();

    // All spir-v kernels can be launched from the same program.
    // TODO: Check that this function is actually available, and error out otherwise.
    const program = try cl.Program.createWithIL(context, module_bytes);
    defer program.release();

    load_node.end();

    const compile_node = root_node.start("Compiling SPIR-V kernels", 0);
    std.log.debug("compiling spir-v kernels", .{});
    program.build(&.{device}, "") catch |err| switch (err) {
        error.BuildProgramFailure => {
            const build_log = try program.getBuildLog(a, device);
            std.log.err("Failed to build program. Error log: \n{s}\n", .{build_log});
        },
        else => return err,
    };
    compile_node.end();

    std.log.debug("program built successfully", .{});

    const buf = try cl.Buffer(u16).create(context, .{ .read_write = true }, 1);
    defer buf.release();

    var ok_count: usize = 0;
    var fail_count: usize = 0;
    var skip_count: usize = 0;
    const total_count = entry_points.count();

    const test_root_node = root_node.start("Test", total_count);

    for (entry_points.values(), 0..) |name, i| {
        const test_node = test_root_node.start(name, 0);
        defer test_node.end();

        const log_prefix = "[{d}/{d}] {s}...";
        const log_prefix_args = .{ i + 1, total_count, name };

        if (!have_tty) {
            std.log.info(log_prefix, log_prefix_args);
        }

        const error_code, const runtime = launchTestKernel(queue, program, buf, name) catch |err| {
            if (have_tty) {
                std.log.info(log_prefix ++ "FAIL (OpenCL: {s})", log_prefix_args ++ .{ @errorName(err) });
            }
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
            std.log.info(log_prefix ++ "runtime: {}us", log_prefix_args ++ .{ runtime });
        }
    }

    test_root_node.end();

    if (ok_count == entry_points.count()) {
        std.log.info("All {} tests passed.", .{ok_count});
    } else {
        std.log.info("{} passed; {} skipped; {} failed.", .{ ok_count, skip_count, fail_count });
    }

    return @intFromBool(!options.reducing and fail_count != 0);
}
