/* SPDX-License-Identifier: Apache-2.0 */

    .section .text.init
    .globl _start
    .type _start, @function
_start:
    la sp, __stack_top
    la t0, counter
    li s0, 0

    .globl loop
loop:
    addi s0, s0, 1

    .globl store_counter
store_counter:
    sd s0, 0(t0)
    j loop
    .size _start, . - _start

    .section .bss
    .balign 8
    .globl counter
counter:
    .dword 0
    .space 4096
__stack_top:
