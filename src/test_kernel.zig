const std = @import("std");

export fn why(err: *addrspace(.global) u16) callconv(.Kernel) void {
    err.* = 1;
}

test "basic" {

}

test "failing" {
    return error.Failing;
}
