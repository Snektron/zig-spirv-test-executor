# Zig SPIR-V Test runner

WIP: An OpenCL program to run Zig test statements for the SPIR-V target. Requires a SPIR-V-capable OpenCL implementation, such as Rusticl, POCL, or OpenCLOn12.

## Idea

Zig provides 2 ways to alter the testing process: by the testing runner, and by the test cmd. To provide SPIR-V tests we need to use both these partss: a custom test runner generates a SPIR-V binary that contains entry points for the tests, and a custom test cmd can then be used to interpret these files and launch the test kernels in them.

### Testing method

Zig tests are assumed to be single-threaded. Therefore we simply launch each test as a compute kernel with a single thread active, as to emulate a single-threaded process on a GPU. TODO is some way to allow overriding these settings, but that is currently out of scope.
