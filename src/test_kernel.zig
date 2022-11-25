export fn kernel() callconv(.C) void {
    asm volatile(
        \\OpEntryPoint Kernel %entry "main"
        :: [entry] "" (kernel)
    );
}
