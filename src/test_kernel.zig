const std = @import("std");
const builtin = @import("builtin");

test "basic" {}

test "skip" {
    return error.SkipZigTest;
}

test "workgroup builtins" {
    if (builtin.zig_backend != .stage2_spirv) return error.SkipZigTest;
    try std.testing.expectEqual(0, @workGroupId(0));
    try std.testing.expectEqual(1, @workGroupSize(0));
    try std.testing.expectEqual(0, @workItemId(0));
}
