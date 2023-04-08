const std = @import("std");

export fn why(err: *addrspace(.global) u16) callconv(.Kernel) void {
    err.* = 1;
}

test "basic" {}

test "fail" {
    return error.Fail;
}

test "skip" {
    return error.SkipZigTest;
}
