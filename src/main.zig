const std = @import("std");
const Vulkan = @import("Vulkan.zig");
const OpenCl = @import("OpenCl.zig");
const SpirvModule = @import("SpirvModule.zig");

pub const poison_error_code = 0xAAAA;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var options = try parseArgs(init);
    if (options.listen) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdout_buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
        var writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
        var server: std.zig.Server = .{ .in = &reader.interface, .out = &writer.interface };
        try server.serveStringMessage(.zig_version, @import("builtin").zig_version_string);

        const module = blk: {
            if (options.module) |path| {
                const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
                defer file.close(init.io);
                break :blk try SpirvModule.load(init.io, arena, file);
            }

            const header = try server.receiveMessage();
            if (header.tag == .exit and header.bytes_len == 0) return 0;
            if (header.tag != .args or header.bytes_len > 1024 * 1024) return error.InvalidProtocolMessage;
            var body: std.Io.Reader = .fixed(try server.in.readAllocAll(arena, header.bytes_len));
            var file: ?std.Io.File = null;
            while (body.bufferedLen() != 0) {
                const tag = try body.takeEnum(std.zig.Client.Message.Arg, .little);
                switch (tag) {
                    .input_file => {
                        if (file != null) return error.InvalidProtocolMessage;
                        file = .{
                            .handle = std.mem.bytesToValue(
                                std.Io.File.Handle,
                                try body.take(@sizeOf(std.Io.File.Handle)),
                            ),
                            .flags = .{ .nonblocking = false },
                        };
                    },
                    .string => {
                        const arg = try body.takeSentinel(0);
                        if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "-p")) {
                            if (try body.takeEnum(std.zig.Client.Message.Arg, .little) != .string)
                                return error.InvalidProtocolMessage;
                            options.platform = try body.takeSentinel(0);
                        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
                            if (try body.takeEnum(std.zig.Client.Message.Arg, .little) != .string)
                                return error.InvalidProtocolMessage;
                            options.device = try body.takeSentinel(0);
                        } else if (std.mem.eql(u8, arg, "--disable-workarounds")) {
                            options.disable_workarounds = true;
                        } else return error.UnsupportedProtocolArgument;
                    },
                    else => return error.UnsupportedProtocolArgument,
                }
            }

            const input = file orelse return error.MissingModule;
            defer input.close(init.io);
            break :blk try SpirvModule.load(init.io, arena, input);
        };

        const names = try arena.alloc(u32, module.entry_points.len);
        const expected_panic_msgs = try arena.alloc(u32, module.entry_points.len);
        @memset(expected_panic_msgs, 0);

        var strings: std.ArrayList(u8) = .empty;
        try strings.append(arena, 0);
        for (module.entry_points, names) |entry, *name| {
            name.* = @intCast(strings.items.len);
            try strings.appendSlice(arena, entry.name);
            try strings.append(arena, 0);
        }

        switch (module.module_type) {
            inline .kernel, .shader => |module_type| {
                const Api = switch (module_type) {
                    .kernel => OpenCl,
                    .shader => Vulkan,
                };
                var api: ?Api = null;
                defer if (api) |*runner| runner.deinit();
                const root_node = std.Progress.start(init.io, .{});
                defer root_node.end();

                while (true) {
                    const header = try server.receiveMessage();
                    switch (header.tag) {
                        .exit => {
                            if (header.bytes_len != 0) return error.InvalidProtocolMessage;
                            return 0;
                        },
                        .query_test_metadata => {
                            if (header.bytes_len != 0) return error.InvalidProtocolMessage;
                            try server.serveTestMetadata(.{
                                .names = names,
                                .expected_panic_msgs = expected_panic_msgs,
                                .string_bytes = strings.items,
                            });
                        },
                        .run_test => {
                            if (header.bytes_len != @sizeOf(u32)) return error.InvalidProtocolMessage;
                            const index = try server.receiveBody_u32();
                            if (index >= module.entry_points.len) return error.InvalidTestIndex;
                            try server.serveStringMessage(.test_started, &.{});
                            if (api == null) api = try Api.init(arena, module, options, root_node);
                            const Status = std.zig.Server.Message.TestResults.Status;
                            const status: Status = if (api.?.runTest(if (Api == Vulkan) index else module.entry_points[index].name)) |error_code| blk: {
                                if (error_code == 0) break :blk .pass;

                                const name = module.errorName(error_code) orelse "unknown error";
                                if (std.mem.eql(u8, name, "SkipZigTest")) break :blk .skip;

                                if (error_code == poison_error_code) {
                                    std.debug.print("test left the result buffer unchanged (poison value)", .{});
                                } else if (module.errorName(error_code)) |error_name| {
                                    std.debug.print("{s}", .{error_name});
                                } else {
                                    std.debug.print("unknown error code: {d}", .{error_code});
                                }

                                break :blk .fail;
                            } else |err| blk: {
                                std.debug.print("{s}", .{@errorName(err)});
                                break :blk .fail;
                            };
                            try server.serveTestResults(.{
                                .index = index,
                                .flags = .{ .status = status, .fuzz = false, .log_err_count = 0, .leak_count = 0 },
                            });
                        },
                        else => return error.UnsupportedProtocolMessage,
                    }
                }
            },
        }
    }

    const file = try std.Io.Dir.cwd().openFile(init.io, options.module.?, .{});
    defer file.close(init.io);
    const module = try SpirvModule.load(init.io, arena, file);

    // Nothing to test.
    if (module.entry_points.len == 0) return 0;

    const root_node = std.Progress.start(init.io, .{ .estimated_total_items = 2 });
    defer root_node.end();
    switch (module.module_type) {
        inline .kernel, .shader => |module_type| {
            const Api = switch (module_type) {
                .kernel => OpenCl,
                .shader => Vulkan,
            };
            var runner = try Api.init(arena, module, options, root_node);
            defer runner.deinit();

            const test_root_node = root_node.start("Test", module.entry_points.len);

            var ok_count: usize = 0;
            var fail_count: usize = 0;
            var skip_count: usize = 0;

            for (module.entry_points, 0..) |entry_point, index| {
                const test_node = test_root_node.start(entry_point.name, 0);
                defer test_node.end();

                const error_code = runner.runTest(if (Api == Vulkan) index else entry_point.name) catch |err| {
                    std.log.err("{s}: {s}\n", .{ entry_point.name, @errorName(err) });
                    fail_count += 1;
                    continue;
                };

                const error_name = module.errorName(error_code) orelse "unknown error";
                if (error_code == 0) {
                    ok_count += 1;
                } else if (std.mem.eql(u8, error_name, "SkipZigTest")) {
                    skip_count += 1;
                } else {
                    if (error_code == poison_error_code) {
                        std.log.err("{s}: test left the result buffer unchanged (poison value)\n", .{entry_point.name});
                    } else {
                        std.log.err("{s}: {s} (code {d})\n", .{ entry_point.name, error_name, error_code });
                    }
                    fail_count += 1;
                }
            }

            test_root_node.end();

            return @intFromBool(fail_count != 0);
        },
    }
}

pub const Options = struct {
    platform: ?[]const u8,
    device: ?[]const u8,
    module: ?[]const u8,
    disable_workarounds: bool,
    listen: bool = false,
};

fn parseArgs(init: std.process.Init) !Options {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.arena.allocator());
    _ = args.next();

    const environ = init.environ_map;
    var platform: ?[]const u8 = environ.get("ZVTX_PLATFORM");
    var device: ?[]const u8 = environ.get("ZVTX_DEVICE");
    var help: bool = false;
    var module: ?[]const u8 = null;
    var disable_workarounds: bool = false;
    var listen = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "-p")) {
            platform = args.next() orelse std.process.fatal("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
            device = args.next() orelse std.process.fatal("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (std.mem.eql(u8, arg, "--disable-workarounds")) {
            disable_workarounds = true;
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            listen = true;
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            // unused
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            // unused
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.process.fatal("unknown option '{s}'", .{arg});
        } else if (module == null) {
            module = arg;
        } else {
            std.process.fatal("unknown option '{s}'", .{arg});
        }
    }

    if (help) {
        const out: std.Io.File = .stdout();
        var writer = out.writer(init.io, &.{});
        try writer.interface.writeAll(
            \\Usage: zig-spirv-test-executor [options...] <spir-v module path>
            \\
            \\Run Zig SPIR-V test entry points through OpenCL or Vulkan. For example:
            \\
            \\zig test file.zig \
            \\    -target spirv64-opencl-none -mcpu opencl_v2+int64+float64+generic_pointer \
            \\    -fno-llvm --test-runner src/test_runner.zig \
            \\    --test-cmd zig-out/bin/zig-spirv-test-executor --test-cmd-bin
            \\
            \\Only entry points whose names start with "test " are executed.
            \\OpenCL entry points receive a result pointer as argument 0. Vulkan compute
            \\entry points use a u32 storage buffer at descriptor set 0, binding 0.
            \\Write 0 for success or a nonzero error code for failure. Zig error metadata
            \\identifies named errors and SkipZigTest. OpenCL uses one work-item.
            \\Vulkan dispatches one workgroup.
            \\
            \\Options (names are matched by case-sensitive substring):
            \\--platform | -p <platform> OpenCL platform name or Vulkan driver name.
            \\--device | -d <device>     OpenCL or Vulkan device name. Without --platform,
            \\                           OpenCL searches across platforms.
            \\                           Defaults to the first SPIR-V-capable OpenCL device
            \\                           or the first Vulkan device; Vulkan checks its
            \\                           required features before running.
            \\--disable-workarounds      Do not pre-process the module to work around
            \\                           platform-specific bugs.
            \\--listen=-                 Serve Zig's binary test protocol on stdin/stdout.
            \\--seed=<u32>               Build runner's seed (unused).
            \\--cache-dir=<path>         Build runner's cache path (unused).
            \\--help -h                  Show this message and exit.
            \\
            \\Environment variables:
            \\ZVTX_PLATFORM=<platform>  Does the same as --platform <platform>.
            \\ZVTX_DEVICE=<device>      Does the same as --device <device>.
            \\
        );
        std.process.exit(0);
    }

    if (!listen and module == null) {
        std.process.fatal("missing required argument <spir-v module path>", .{});
    }

    return .{
        .platform = platform,
        .device = device,
        .module = module,
        .disable_workarounds = disable_workarounds,
        .listen = listen,
    };
}
