const std = @import("std");

// Note: Intel's CPU OpenCL seems to have some issues with certain test names
test "basic" {

}

test "failing" {
    return error.Failing;
}
