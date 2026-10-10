words: []u32,
module_type: ModuleType,
entry_points: []const EntryPoint,
error_names: []const []const u8,

const EntryPoint = struct { id: u32, name: [:0]u8 };
const ModuleType = enum { shader, kernel };

pub fn load(io: std.Io, arena: std.mem.Allocator, file: std.Io.File) !SpirvModule {
    var reader = file.readerStreaming(io, &.{});
    const bytes = try reader.interface.allocRemainingAlignedSentinel(arena, .unlimited, .of(u32), null);
    if (bytes.len % 4 != 0) return error.InvalidSpirv;

    const words = std.mem.bytesAsSlice(u32, bytes);
    if (words.len < 5) return error.InvalidSpirv;
    if (words[0] == @byteSwap(spirv.SpvMagicNumber)) {
        for (words) |*word| word.* = @byteSwap(word.*);
    }
    if (words[0] != spirv.SpvMagicNumber) return error.InvalidSpirv;

    var entries: std.ArrayList(EntryPoint) = .empty;
    defer entries.deinit(arena);
    var module_type: ?ModuleType = null;
    var error_names: ?[]const u8 = null;
    var instructions: InstructionIterator = .{ .words = words };
    while (try instructions.next()) |inst| {
        switch (inst.opcode) {
            spirv.SpvOpCapability => switch (inst.operands[0]) {
                spirv.SpvCapabilityShader => module_type = .shader,
                spirv.SpvCapabilityKernel => module_type = .kernel,
                else => {},
            },
            spirv.SpvOpSourceExtension => {
                const extension = try inst.string(0);
                if (std.mem.startsWith(u8, extension, "zig_errors:")) error_names = extension["zig_errors:".len..];
            },
            spirv.SpvOpEntryPoint => {
                const name = try inst.string(2);
                if (std.mem.startsWith(u8, name, "test ")) try entries.append(arena, .{ .id = inst.operands[1], .name = name });
            },
            else => {},
        }
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    if (error_names) |errors| {
        var it = std.mem.splitScalar(u8, errors, ':');
        while (it.next()) |escaped| {
            const name = try arena.alloc(u8, escaped.len);
            try names.append(arena, std.Uri.percentDecodeBackwards(name, escaped));
        }
    }

    const module: SpirvModule = .{
        .words = words,
        .module_type = module_type orelse return error.MissingCapability,
        .entry_points = try arena.dupe(EntryPoint, entries.items),
        .error_names = try arena.dupe([]const u8, names.items),
    };
    try module.validate(io, arena);
    return module;
}

const InstructionIterator = struct {
    words: []u32,
    offset: usize = 5,
    index: usize = 0,

    const Instruction = struct {
        opcode: u16,
        operands: []u32,
        index: usize,

        fn string(inst: Instruction, offset: usize) ![:0]u8 {
            const bytes = std.mem.sliceAsBytes(inst.operands[offset..]);
            const end = std.mem.findScalar(u8, bytes, 0) orelse return error.InvalidSpirv;
            return bytes[0..end :0];
        }
    };

    fn next(it: *InstructionIterator) !?Instruction {
        if (it.offset == it.words.len) return null;
        const first = it.words[it.offset];
        const len = first >> 16;
        const opcode: u16 = @truncate(first);
        const minimum: u32 = switch (opcode) {
            spirv.SpvOpCapability, spirv.SpvOpSourceExtension => 2,
            spirv.SpvOpName, spirv.SpvOpString => 3,
            spirv.SpvOpEntryPoint, spirv.SpvOpLine => 4,
            spirv.SpvOpFunction => 5,
            else => 1,
        };
        if (len < minimum or len > it.words.len - it.offset) return error.InvalidSpirv;
        const inst: Instruction = .{
            .opcode = opcode,
            .operands = it.words[it.offset..][1..len],
            .index = it.index,
        };
        switch (opcode) {
            spirv.SpvOpSourceExtension => _ = try inst.string(0),
            spirv.SpvOpName, spirv.SpvOpString => _ = try inst.string(1),
            spirv.SpvOpEntryPoint => _ = try inst.string(2),
            else => {},
        }
        it.offset += len;
        it.index += 1;
        return inst;
    }
};

fn validate(module: SpirvModule, io: std.Io, arena: std.mem.Allocator) !void {
    const context = tools.spvContextCreate(switch (module.module_type) {
        .shader => tools.SPV_ENV_VULKAN_1_3,
        .kernel => tools.SPV_ENV_OPENCL_2_2,
    }) orelse return error.OutOfMemory;
    defer tools.spvContextDestroy(context);

    var diagnostic: tools.spv_diagnostic = null;
    defer tools.spvDiagnosticDestroy(diagnostic);

    if (tools.spvValidateBinary(
        context,
        module.words.ptr,
        module.words.len,
        &diagnostic,
    ) == tools.SPV_SUCCESS) {
        return;
    }

    _ = tools.spvDiagnosticPrint(diagnostic);

    var location: Location = .{};
    var instructions: InstructionIterator = .{ .words = module.words };
    while (try instructions.next()) |inst| {
        if (inst.index >= diagnostic.*.position.index) break;
        switch (inst.opcode) {
            spirv.SpvOpFunction => location.function_id = inst.operands[1],
            spirv.SpvOpFunctionEnd => {
                location.function_id = 0;
                location.file_id = 0;
            },
            spirv.SpvOpNoLine => location.file_id = 0,
            spirv.SpvOpLine => {
                location.file_id = inst.operands[0];
                location.line = inst.operands[1];
                location.column = inst.operands[2];
            },
            else => {},
        }
    }

    instructions = .{ .words = module.words };
    while (try instructions.next()) |inst| {
        switch (inst.opcode) {
            spirv.SpvOpName => if (inst.operands[0] == location.function_id) {
                location.function = try inst.string(1);
            },
            spirv.SpvOpString => if (inst.operands[0] == location.file_id) {
                location.file = try inst.string(1);
            },
            else => {},
        }
    }

    if (location.file) |file| {
        std.debug.print("at {s}:{}:{}\n", .{ file, location.line, location.column });
        if (std.Io.Dir.cwd().readFileAlloc(io, file, arena, .unlimited)) |source| {
            defer arena.free(source);
            var it = std.mem.splitScalar(u8, source, '\n');
            var index: usize = 1;
            while (it.next()) |text| : (index += 1) {
                if (index != location.line) continue;
                const padding = try arena.alloc(u8, location.column -| 1);
                defer arena.free(padding);
                @memset(padding, ' ');
                std.debug.print("{s}\n{s}^\n", .{ text, padding });
                break;
            }
        } else |_| {}
    }

    if (location.function) |name| {
        std.debug.print("in function %{d} ({s})\n", .{ location.function_id, name });
    }

    return error.InvalidSpirv;
}

const Location = struct {
    function_id: u32 = 0,
    file_id: u32 = 0,
    line: u32 = 0,
    column: u32 = 0,
    function: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub fn errorName(module: SpirvModule, error_code: u32) ?[]const u8 {
    return if (error_code < module.error_names.len)
        module.error_names[error_code]
    else
        null;
}

const std = @import("std");
const spirv = @import("spirv");
const tools = @import("spirv-tools");
const SpirvModule = @This();
