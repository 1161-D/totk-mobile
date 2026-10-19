// Exercise the same stack switch as the shared ARM64 entry point.
.text
.globl _dm_thread_enter
.p2align 2
_dm_thread_enter:
    mov sp, x2
    mov x29, #0
    mov x16, x0
    mov x0, x1
    adr x30, 1f
    br x16
1:  bl _dm_thread_returned
    brk #0
