const std = @import("std");

test "basic" {}

test "skip" {
    return error.SkipZigTest;
}
