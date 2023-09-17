const std = @import("std");

test "basic" {}

test "fail" {
    return error.Fail;
}

test "skip" {
    return error.SkipZigTest;
}
