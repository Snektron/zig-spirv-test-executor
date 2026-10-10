platform: cl.Platform,
device: cl.Device,
context: cl.Context,
queue: cl.CommandQueue,
program: cl.Program,
err_buf: cl.Buffer(u32),
known_platform: KnownPlatform,

const KnownPlatform = enum {
    intel,
    pocl,
    rusticl,
    unknown,
};

pub fn init(
    arena: std.mem.Allocator,
    module: SpirvModule,
    options: executor.Options,
    root_node: std.Progress.Node,
) !OpenCl {
    const init_node = root_node.start("Initialize OpenCl", 0);
    defer init_node.end();

    const platform, const device = try pickPlatformAndDevice(arena, options);
    const platform_name = try platform.getName(arena);

    init_node.setName(try std.fmt.allocPrint(arena, "Initialize OpenCL ({s})", .{try device.getName(arena)}));

    const known_platform: KnownPlatform = if (std.mem.eql(u8, "Intel(R) OpenCl", platform_name))
        .intel
    else if (std.mem.eql(u8, "Portable Computing Language", platform_name))
        .pocl
    else if (std.mem.eql(u8, "rusticl", platform_name))
        .rusticl
    else
        .unknown;

    if (!options.disable_workarounds and known_platform == .pocl) {
        for (module.entry_points) |entry| {
            for (entry.name) |*char| {
                switch (char.*) {
                    '@', '/' => char.* = ' ',
                    else => {},
                }
            }
        }
    }

    const context = try cl.Context.create(&.{device}, .{ .platform = platform });
    errdefer context.release();

    const queue = try cl.CommandQueue.create(context, device, .{ .profiling = true });
    errdefer queue.release();

    // Each test entry point is launched from this program.
    // TODO: Check that this function is actually available, and error out otherwise.
    const program = try cl.Program.createWithIL(context, std.mem.sliceAsBytes(module.words));
    errdefer program.release();

    program.build(&.{device}, "") catch |err| switch (err) {
        error.BuildProgramFailure => {
            const build_log = try program.getBuildLog(arena, device);
            std.debug.print("Failed to build program. Error log: \n{s}\n", .{build_log});
            std.process.exit(1);
        },
        else => return err,
    };

    const err_buf = try cl.Buffer(u32).create(context, .{ .read_write = true }, 1);
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

pub fn deinit(runner: *OpenCl) void {
    runner.err_buf.release();
    runner.program.release();
    runner.queue.release();
    runner.context.release();
    runner.* = undefined;
}

pub fn runTest(runner: *OpenCl, name: [:0]const u8) !u32 {
    const kernel = try cl.Kernel.create(runner.program, name);
    defer kernel.release();

    // Mark the result buffer so an unchanged value can be detected.
    const write_complete = try runner.queue.enqueueWriteBuffer(
        u32,
        runner.err_buf,
        false,
        0,
        &.{executor.poison_error_code},
        &.{},
    );

    try kernel.setArg(cl.Buffer(u32), 0, runner.err_buf);
    const kernel_complete = try runner.queue.enqueueNDRangeKernel(
        kernel,
        null,
        &.{1},
        &.{1},
        &.{write_complete},
    );
    defer kernel_complete.release();

    var result: u32 = undefined;
    const read_complete = try runner.queue.enqueueReadBuffer(
        u32,
        runner.err_buf,
        false,
        0,
        (&result)[0..1],
        &.{kernel_complete},
    );

    try cl.waitForEvents(&.{read_complete});

    return result;
}

fn failWithAvailableTargets(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n", args);
    const available_platforms = cl.getPlatforms(arena) catch std.process.exit(1);
    std.debug.print("available opencl platforms and devices:\n", .{});
    for (available_platforms) |platform| {
        const platform_name = platform.getName(arena) catch "<unknown>";
        std.debug.print("  platform '{s}'\n", .{platform_name});
        const devices = platform.getDevices(arena, cl.DeviceType.all) catch continue;
        if (devices.len == 0) {
            std.debug.print("    (no devices)\n", .{});
            continue;
        }
        for (devices) |device| {
            const device_name = device.getName(arena) catch "<unknown>";
            const supports_spirv = deviceSupportsSpirv(arena, device) catch false;
            std.debug.print("    device '{s}'{s}\n", .{
                device_name,
                if (supports_spirv) "" else " (no SPIR-V ingestion)",
            });
        }
    }
    std.process.exit(1);
}

fn pickDevice(arena: std.mem.Allocator, platform: cl.Platform, query: ?[]const u8) !cl.Device {
    const available_devices = try platform.getDevices(arena, cl.DeviceType.all);
    if (available_devices.len == 0) {
        return error.NoDevices;
    }

    if (query) |device_query| {
        for (available_devices) |device| {
            const name = try device.getName(arena);
            if (std.mem.find(u8, name, device_query) != null) {
                if (!try deviceSupportsSpirv(arena, device)) {
                    failWithAvailableTargets(arena, "device '{s}' does not support spir-v ingestion", .{name});
                }
                return device;
            }
        }

        return error.NoSuchDevice;
    } else {
        for (available_devices) |device| {
            if (try deviceSupportsSpirv(arena, device)) {
                return device;
            }
        }

        return error.NoSpirvSupport;
    }
}

fn pickPlatformAndDevice(
    arena: std.mem.Allocator,
    options: executor.Options,
) !struct { cl.Platform, cl.Device } {
    const available_platforms = try cl.getPlatforms(arena);

    if (available_platforms.len == 0) {
        std.process.fatal("no opencl platform available", .{});
    }

    if (options.platform) |platform_query| {
        const platform, const name = for (available_platforms) |platform| {
            const name = try platform.getName(arena);
            if (std.mem.find(u8, name, platform_query) != null) {
                break .{ platform, name };
            }
        } else {
            failWithAvailableTargets(arena, "no such opencl platform '{s}'", .{platform_query});
        };

        const device = pickDevice(arena, platform, options.device) catch |err| switch (err) {
            error.NoDevices => failWithAvailableTargets(arena, "no opencl devices available for platform '{s}'", .{name}),
            error.NoSuchDevice => failWithAvailableTargets(arena, "platform '{s}' has no devices that match '{s}'", .{ name, options.device.? }),
            error.NoSpirvSupport => failWithAvailableTargets(arena, "platform '{s}' has no devices that support SPIR-V ingestion", .{name}),
            else => return err,
        };
        return .{ platform, device };
    } else if (options.device) |device_query| {
        // Loop through all platforms to find one which matches the device
        var device_found_but_doesnt_have_spirv: ?cl.Platform = null;
        for (available_platforms) |platform| {
            const device = pickDevice(arena, platform, device_query) catch |err| switch (err) {
                error.NoDevices, error.NoSuchDevice => continue,
                error.NoSpirvSupport => {
                    device_found_but_doesnt_have_spirv = platform;
                    continue;
                },
                else => return err,
            };

            return .{ platform, device };
        }

        if (device_found_but_doesnt_have_spirv) |platform| {
            const name = try platform.getName(arena);
            failWithAvailableTargets(arena, "platform '{s}' has a device that matches '{s}', but it doesn't support SPIR-V ingestion", .{ name, device_query });
        } else {
            failWithAvailableTargets(arena, "no platform has opencl device '{s}'", .{device_query});
        }
    } else {
        for (available_platforms) |platform| {
            const device = pickDevice(arena, platform, null) catch |err| switch (err) {
                error.NoDevices, error.NoSpirvSupport => continue,
                error.NoSuchDevice => unreachable,
                else => return err,
            };
            return .{ platform, device };
        } else {
            failWithAvailableTargets(arena, "no opencl platform that has any devices which support SPIR-V ingestion", .{});
        }
    }
}

fn deviceSupportsSpirv(arena: std.mem.Allocator, device: cl.Device) !bool {
    // This query requires OpenCL 3.0 or cl_khr_extended_versioning.
    // Probe it directly because the bindings treat CL_INVALID_VALUE as unreachable.
    var ils_size: usize = 0;
    if (cl.c.clGetDeviceInfo(device.id, cl.c.CL_DEVICE_ILS_WITH_VERSION, 0, null, &ils_size) == cl.c.CL_SUCCESS) {
        const ils = try device.getILsWithVersion(arena);

        for (ils) |il| {
            // TODO: Minimum version?
            if (std.mem.eql(u8, il.getName(), "SPIR-V")) {
                return true;
            }
        }

        return false;
    }

    var il_version_size: usize = 0;
    if (cl.c.clGetDeviceInfo(device.id, cl.c.CL_DEVICE_IL_VERSION, 0, null, &il_version_size) != cl.c.CL_SUCCESS or il_version_size == 0) {
        return false;
    }

    const il_version = try arena.alloc(u8, il_version_size);
    defer arena.free(il_version);
    if (cl.c.clGetDeviceInfo(device.id, cl.c.CL_DEVICE_IL_VERSION, il_version.len, il_version.ptr, null) != cl.c.CL_SUCCESS) {
        return false;
    }

    return std.mem.find(u8, il_version, "SPIR-V") != null;
}

const std = @import("std");
const cl = @import("opencl");
const spirv_tools = @import("spirv-tools");
const SpirvModule = @import("SpirvModule.zig");
const executor = @import("main.zig");
const OpenCl = @This();
