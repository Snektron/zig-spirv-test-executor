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
err_ptr: *u32,
desc_pool: vk.DescriptorPool,
desc_set_layout: vk.DescriptorSetLayout,
desc_set: vk.DescriptorSet,
query_pool: vk.QueryPool,

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
};
const required_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};

const BaseDispatch = vk.BaseWrapper;
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;
const Kernel = struct {
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
};

pub fn init(
    arena: std.mem.Allocator,
    module: SpirvModule,
    options: executor.Options,
    root_node: std.Progress.Node,
) !Vulkan {
    const init_node = root_node.start("Initialize Vulkan", 1);
    defer init_node.end();

    var runner: Vulkan = undefined;

    runner.lib = try std.DynLib.open("libvulkan.so.1");
    errdefer runner.lib.close();

    const vk_get_instance_proc_addr = runner.lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
        std.process.fatal("libvulkan.so.1 doesn't provide vkGetInstanceProcAddr", .{});
    };
    runner.vkb = BaseDispatch.load(vk_get_instance_proc_addr);

    const instance = try runner.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "zig spir-v test executor",
            .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .p_engine_name = "super cool engine",
            .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
            .api_version = @bitCast(vk.API_VERSION_1_3),
        },
        .enabled_layer_count = required_layers.len,
        .pp_enabled_layer_names = &required_layers,
    }, null);

    const vki = try arena.create(Instance.Wrapper);
    vki.* = Instance.Wrapper.load(instance, runner.vkb.dispatch.vkGetInstanceProcAddr.?);
    runner.instance = Instance.init(instance, vki);
    errdefer runner.instance.destroyInstance(null);

    const pdevs = try runner.instance.enumeratePhysicalDevicesAlloc(arena);

    if (pdevs.len == 0) {
        std.process.fatal("no vulkan devices available", .{});
    }

    const features10: vk.PhysicalDeviceFeatures = .{
        .shader_int_16 = .true,
        .shader_int_64 = .true,
        .shader_float_64 = .true,
    };

    var features11: vk.PhysicalDeviceVulkan11Features = .{
        .variable_pointers = .true,
        .variable_pointers_storage_buffer = .true,
    };

    var features12: vk.PhysicalDeviceVulkan12Features = .{
        .p_next = @ptrCast(&features11),
        .buffer_device_address = .true,
        .shader_float_16 = .true,
        .shader_int_8 = .true,
    };

    for (pdevs) |pdev| {
        var props12: vk.PhysicalDeviceVulkan12Properties = undefined;
        props12.s_type = .physical_device_vulkan_1_2_properties;
        props12.p_next = null;

        var props2: vk.PhysicalDeviceProperties2 = .{
            .p_next = @ptrCast(&props12),
            .properties = undefined,
        };

        runner.instance.getPhysicalDeviceProperties2(pdev, &props2);

        const name = std.mem.sliceTo(&props2.properties.device_name, 0);
        const driver = std.mem.sliceTo(&props12.driver_name, 0);

        if (options.device) |device_query| {
            if (std.mem.find(u8, name, device_query) == null) {
                continue;
            }
        }

        if (options.platform) |platform_query| {
            if (std.mem.find(u8, driver, platform_query) == null) {
                continue;
            }
        }

        var supported_features12: vk.PhysicalDeviceVulkan12Features = .{};
        var supported_features11: vk.PhysicalDeviceVulkan11Features = .{
            .p_next = @ptrCast(&supported_features12),
        };
        var features2: vk.PhysicalDeviceFeatures2 = .{
            .p_next = @ptrCast(&supported_features11),
            .features = .{},
        };
        runner.instance.getPhysicalDeviceFeatures2(pdev, &features2);
        const supported_features10 = &features2.features;

        inline for (
            .{ vk.PhysicalDeviceFeatures, vk.PhysicalDeviceVulkan11Features, vk.PhysicalDeviceVulkan12Features },
            .{ &features10, &features11, &features12 },
            .{ supported_features10, &supported_features11, &supported_features12 },
        ) |T, expected, actual| {
            inline for (comptime std.meta.fieldNames(T)) |field_name| {
                if (@FieldType(T, field_name) == vk.Bool32 and @field(expected, field_name) == .true and @field(actual, field_name) == .false) {
                    std.process.fatal("device '{s}' does not support the required features", .{name});
                }
            }
        }

        runner.pdev = pdev;
        runner.props = props2.properties;
        break;
    } else {
        std.debug.print(
            \\there are no devices that support buffer device address or the specified device/platform
            \\available vulkan devices:
            \\
        , .{});
        for (pdevs) |pdev| {
            var props12: vk.PhysicalDeviceVulkan12Properties = undefined;
            props12.s_type = .physical_device_vulkan_1_2_properties;
            props12.p_next = null;

            var props2: vk.PhysicalDeviceProperties2 = .{
                .p_next = @ptrCast(&props12),
                .properties = undefined,
            };

            runner.instance.getPhysicalDeviceProperties2(pdev, &props2);

            std.debug.print("  device '{s}' (driver '{s}')\n", .{
                std.mem.sliceTo(&props2.properties.device_name, 0),
                std.mem.sliceTo(&props12.driver_name, 0),
            });
        }
        std.process.exit(1);
    }

    runner.mem_props = runner.instance.getPhysicalDeviceMemoryProperties(runner.pdev);
    init_node.setName(try std.fmt.allocPrint(arena, "Initialize Vulkan ({s})", .{std.mem.sliceTo(&runner.props.device_name, 0)}));
    const families = try runner.instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(runner.pdev, arena);
    for (families, 0..) |props, i| {
        if (props.queue_flags.compute) {
            runner.compute_queue_family = @intCast(i);
            runner.compute_queue_props = props;
            break;
        }
    } else {
        std.process.fatal("no compute queue", .{});
    }

    const dev = try runner.instance.createDevice(runner.pdev, &.{
        .p_next = @ptrCast(&features12),
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{
            .{
                .queue_family_index = runner.compute_queue_family,
                .queue_count = 1,
                .p_queue_priorities = &.{1},
            },
        },
        .p_enabled_features = &features10,
    }, null);

    const vkd = try arena.create(Device.Wrapper);
    vkd.* = Device.Wrapper.load(dev, runner.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    runner.dev = Device.init(dev, vkd);
    errdefer runner.dev.destroyDevice(null);

    runner.compute_queue = runner.dev.getDeviceQueue(runner.compute_queue_family, 0);

    runner.cmd_pool = try runner.dev.createCommandPool(&.{
        .flags = .{},
        .queue_family_index = runner.compute_queue_family,
    }, null);
    errdefer runner.dev.destroyCommandPool(runner.cmd_pool, null);

    var cmd_bufs: [1]vk.CommandBuffer = undefined;
    try runner.dev.allocateCommandBuffers(&.{
        .command_pool = runner.cmd_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, &cmd_bufs);
    runner.cmd_buf = cmd_bufs[0];

    const shader = try runner.dev.createShaderModule(&.{
        .code_size = module.words.len * @sizeOf(u32),
        .p_code = module.words.ptr,
    }, null);
    defer runner.dev.destroyShaderModule(shader, null);

    runner.kernels = try arena.alloc(Kernel, module.entry_points.len);
    for (runner.kernels) |*k| k.* = .{
        .pipeline_layout = .null_handle,
        .pipeline = .null_handle,
    };
    errdefer runner.deinitKernels();

    runner.err_buf = try runner.dev.createBuffer(&.{
        .size = @sizeOf(u32),
        .usage = .{
            .transfer_dst = true,
            .storage_buffer = true,
        },
        .sharing_mode = .exclusive,
    }, null);
    errdefer runner.dev.destroyBuffer(runner.err_buf, null);

    const mem_reqs = runner.dev.getBufferMemoryRequirements(runner.err_buf);
    const memory_flags: vk.MemoryPropertyFlags = .{
        .host_visible = true,
        .host_coherent = true,
        .device_local = true,
    };
    const memory_type_index: u32 = for (runner.mem_props.memory_types[0..runner.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (mem_reqs.memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(memory_flags)) {
            break @intCast(i);
        }
    } else return error.NoSuitableMemoryType;

    runner.err_buf_mem = try runner.dev.allocateMemory(&.{
        .p_next = &vk.MemoryAllocateFlagsInfo{ .flags = .{ .device_address = true }, .device_mask = 0 },
        .allocation_size = mem_reqs.size,
        .memory_type_index = memory_type_index,
    }, null);
    errdefer runner.dev.freeMemory(runner.err_buf_mem, null);
    try runner.dev.bindBufferMemory(runner.err_buf, runner.err_buf_mem, 0);

    runner.err_ptr = @ptrCast(@alignCast(try runner.dev.mapMemory(runner.err_buf_mem, 0, @sizeOf(u32), .{})));

    runner.desc_pool = try runner.dev.createDescriptorPool(&.{
        .pool_size_count = @intCast(1),
        .p_pool_sizes = &.{.{ .type = .storage_buffer, .descriptor_count = 1 }},
        .max_sets = 1,
    }, null);
    runner.desc_set_layout = try runner.dev.createDescriptorSetLayout(
        &.{
            .binding_count = 1,
            .p_bindings = &.{.{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .compute = true },
            }},
        },
        null,
    );
    try runner.dev.allocateDescriptorSets(
        &.{
            .descriptor_pool = runner.desc_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&runner.desc_set_layout),
        },
        @ptrCast(&runner.desc_set),
    );
    runner.dev.updateDescriptorSets(&.{
        .{
            .dst_set = runner.desc_set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = &.{.{
                .buffer = runner.err_buf,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }},
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        },
    }, null);

    const kernels_node = root_node.start("Compiling Kernels", module.entry_points.len);
    for (module.entry_points, 0..) |entry_point, i| {
        const msg = try std.fmt.allocPrint(arena, "compiling kernel '{s}'", .{entry_point.name});
        const init_kernel_node = kernels_node.start(msg, 0);
        defer init_kernel_node.end();
        const pipeline_layout = try runner.dev.createPipelineLayout(&.{
            .p_set_layouts = &.{runner.desc_set_layout},
            .set_layout_count = 1,
        }, null);

        errdefer runner.dev.destroyPipelineLayout(pipeline_layout, null);

        var pipelines: [1]vk.Pipeline = undefined;
        _ = try runner.dev.createComputePipelines(
            .null_handle,
            &.{
                .{
                    .stage = .{
                        .stage = .{ .compute = true },
                        .module = shader,
                        .p_name = entry_point.name,
                    },
                    .layout = pipeline_layout,
                    .base_pipeline_handle = .null_handle,
                    .base_pipeline_index = 0,
                },
            },
            null,
            &pipelines,
        );
        runner.kernels[i] = .{
            .pipeline_layout = pipeline_layout,
            .pipeline = pipelines[0],
        };
    }
    kernels_node.end();

    runner.query_pool = try runner.dev.createQueryPool(&.{
        .query_type = .timestamp,
        .query_count = 2, // start and end
    }, null);

    return runner;
}

pub fn deinit(runner: *Vulkan) void {
    runner.dev.destroyQueryPool(runner.query_pool, null);
    runner.dev.unmapMemory(runner.err_buf_mem);
    runner.dev.freeMemory(runner.err_buf_mem, null);
    runner.dev.destroyBuffer(runner.err_buf, null);
    runner.dev.destroyDescriptorSetLayout(runner.desc_set_layout, null);
    runner.dev.destroyDescriptorPool(runner.desc_pool, null);
    runner.deinitKernels();
    runner.dev.destroyCommandPool(runner.cmd_pool, null);
    runner.dev.destroyDevice(null);
    runner.instance.destroyInstance(null);
    runner.lib.close();
    runner.* = undefined;
}

fn deinitKernels(runner: *Vulkan) void {
    for (runner.kernels) |k| {
        runner.dev.destroyPipelineLayout(k.pipeline_layout, null);
        runner.dev.destroyPipeline(k.pipeline, null);
    }
}

pub fn runTest(runner: *Vulkan, index: usize) !u32 {
    const kernel = runner.kernels[index];

    runner.err_ptr.* = executor.poison_error_code;
    try runner.dev.resetCommandPool(runner.cmd_pool, .{});
    try runner.dev.beginCommandBuffer(runner.cmd_buf, &.{ .flags = .{ .one_time_submit = true } });
    runner.dev.cmdResetQueryPool(runner.cmd_buf, runner.query_pool, 0, 2);
    runner.dev.cmdWriteTimestamp(runner.cmd_buf, .{ .compute_shader = true }, runner.query_pool, 0);
    runner.dev.cmdBindPipeline(runner.cmd_buf, .compute, kernel.pipeline);
    runner.dev.cmdBindDescriptorSets(
        runner.cmd_buf,
        .compute,
        kernel.pipeline_layout,
        0,
        &.{runner.desc_set},
        null,
    );
    runner.dev.cmdDispatch(runner.cmd_buf, 1, 1, 1);
    runner.dev.cmdWriteTimestamp(runner.cmd_buf, .{ .compute_shader = true }, runner.query_pool, 1);

    try runner.dev.endCommandBuffer(runner.cmd_buf);
    try runner.dev.queueSubmit(runner.compute_queue, &.{
        .{
            .command_buffer_count = 1,
            .p_command_buffers = &.{runner.cmd_buf},
        },
    }, .null_handle);

    try runner.dev.queueWaitIdle(runner.compute_queue);

    var query_results: [2]u64 = undefined;
    _ = try runner.dev.getQueryPoolResults(
        runner.query_pool,
        0,
        2,
        @sizeOf([2]u64),
        &query_results,
        @sizeOf(u64),
        .{ .@"64" = true },
    );

    if (runner.compute_queue_props.timestamp_valid_bits != 64) {
        query_results[0] &= (@as(u64, 1) << @intCast(runner.compute_queue_props.timestamp_valid_bits)) - 1;
        query_results[1] &= (@as(u64, 1) << @intCast(runner.compute_queue_props.timestamp_valid_bits)) - 1;
    }

    return runner.err_ptr.*;
}

const std = @import("std");
const vk = @import("vulkan");
const executor = @import("main.zig");
const SpirvModule = @import("SpirvModule.zig");
const Vulkan = @This();
