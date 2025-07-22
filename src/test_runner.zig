const std = @import("std");
const builtin = @import("builtin");

// The testing infrastructure uses function pointers to expose the tests via
// `builtin.test_functions`. However, these are currently not lowered for the SPIR-V
// backend.
// Instead, all testing functions are temporarily lowered to separate kernels, which
// the executor fetches directly from the SPIR-V module.
// This test runner must still be used in order to prevent Zig from using the default
// test runner.

comptime {
    if (builtin.zig_backend != .stage2_spirv) {
        @compileError("this test runner is only intended for spir-v");
    }
}
