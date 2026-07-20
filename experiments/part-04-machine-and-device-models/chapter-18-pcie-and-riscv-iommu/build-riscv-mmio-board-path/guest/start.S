/* SPDX-License-Identifier: Apache-2.0 */

    .section .text.init
    .globl _start
    .type _start, @function
_start:
    la sp, __stack_top
    call main
1:
    wfi
    j 1b
    .size _start, . - _start

    .section .bss
    .balign 16
    .space 4096
__stack_top:
