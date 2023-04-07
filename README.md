# Zig SPIR-V Test runner

WIP: An OpenCL program to run Zig test statements for the SPIR-V target. Requires a SPIR-V-capable OpenCL implementation, such as Rusticl, POCL, OpenCLOn12, or Intel's OpenCL runtime.

## Idea

Zig provides 2 ways to alter the testing process: by the testing runner, and by the test cmd. To provide SPIR-V tests we need to use both these partss: a custom test runner generates a SPIR-V binary that contains entry points for the tests, and a custom test cmd can then be used to interpret these files and launch the test kernels in them.

### Testing method

Zig tests are assumed to be single-threaded. Therefore we simply launch each test as a compute kernel with a single thread active, as to emulate a single-threaded process on a GPU. TODO is some way to allow overriding these settings, but that is currently out of scope.

## Flake

Included in the repository is a nix flake that sets up an environment with Intel's CPU OpenCL runtime and Mesa's Rusticl runtime.

## Running tests

Something like
```
$ zig test src/test_kernel.zig --test-runner src/test_runner.zig -fno-compiler-rt -target spirv64-opencl -mcpu generic+Int64+Int16+Int8 --test-cmd zig-out/bin/zig-spirv-executor --test-cmd --platform --test-cmd Intel --test-cmd-bin
```
