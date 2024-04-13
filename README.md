# Zig SPIR-V Test Executor

This is a program to run Zig tests for the SPIR-V target. This is currently mainly used for the compiler behavior tests, and only supports the OpenCL environment. A SPIR-V-capable OpenCL implementation is required, such as Rusticl, POCL, or Intels

## Building

In order to build the executor, we need a few system dependencies:
- The [OpenCL Headers](https://github.com/KhronosGroup/OpenCL-Headers)
- An OpenCL implementation. Its usually the best to link against an ICD loader so that the actual backend that is used may be swapped out at runtime, such as the [Khronos OpenCL ICD Loader](https://github.com/KhronosGroup/OpenCL-ICD-Loader).
- [SPIRV-Tools](https://github.com/KhronosGroup/SPIRV-Tools) is required for extra validation of the module.

After obtaining these dependencies, simply run `zig build` to build the project.

## Running tests

To actually run tests, use something like the following:
```
$ zig test src/test_kernel.zig \
    --test-runner src/test_runner.zig \
    -target spirv64-opencl-gnu \
    -mcpu generic+Int64+Int16+Int8+Float64+Float16 \
    -fno-llvm \
    --test-cmd zig-out/bin/zig-spirv-test-executor \
    --test-cmd --platform \
    --test-cmd Intel \
    --test-cmd-bin
```

## Flake

The devshell in `flake.nix` sets up an environment with a bunch of OpenCL capable drivers, such as a slim debug build of recent Mesa, Intel's CPU OpenCL runtime, and POCL 5.0.
