const std = @import("std");

test "basic" {}

test "skip" {
    return error.SkipZigTest;
}

test "workgroup builtins" {
    try std.testing.expectEqual(0, @workGroupId(0));
    try std.testing.expectEqual(1, @workGroupSize(0));
    try std.testing.expectEqual(0, @workItemId(0));
}
