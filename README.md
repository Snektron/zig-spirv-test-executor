# Zig SPIR-V Test Executor

This is a program to run Zig tests for the SPIR-V target. This is currently mainly used for the compiler behavior tests, and only supports the OpenCL environment. A SPIR-V-capable OpenCL implementation is required, such as Rusticl, POCL, or Intels

Requires Zig `0.17.0-dev.857+2b2b85c5f` or newer.

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
    -target spirv64-opencl-none \
    -mcpu generic+int64+float64+float16 \
    -fno-llvm \
    --test-cmd zig-out/bin/zig-spirv-test-executor \
    --test-cmd --platform \
    --test-cmd Intel \
    --test-cmd-bin
```

## Bulk test triage

`update-tests.py` runs a whole directory of Zig tests under SPIR-V and records which ones pass. It works in two phases: a first run inserts a `SkipZigTest` guard for every test (so they are all skipped by default), and a run with `--recheck` re-runs the guarded tests and removes the guard from the ones that now pass.

```
python3 update-tests.py <path-to-zig> <test-dir-or-file> \
    --recheck --platform Portable --timeout 60 -j 2
```

The test sources must match the compiler version, otherwise failures are dominated by unrelated language/std changes rather than real SPIR-V gaps.

Notes:
- `-j/--jobs` limits parallel workers. The default uses all cores, which oversubscribes CPU-based drivers (e.g. POCL) badly enough that tests time out; lower it (`-j 2`, even `-j 1`) for stable results.
- `--no-fp16` drops `float16` from the target features for drivers without `cl_khr_fp16`, such as POCL.
- `--todo` prints how many tests still need work; `--recheck` re-evaluates already-generated guards.

## Nix dependencies

The system dependencies above are available in nixpkgs as:

- `spirv-tools` - headers and `libSPIRV-Tools-shared` for module validation.
- `ocl-icd` - the OpenCL ICD loader (`libOpenCL`).
- `opencl-headers` - the OpenCL headers.

At runtime the loader dispatches to whichever ICD is registered (e.g. POCL or Mesa/Rusticl); that ICD must support SPIR-V ingestion (`cl_khr_il_program`). The 0.17 update has been verified end-to-end against POCL (CPU); it has not been re-tested against Mesa/Rusticl.
