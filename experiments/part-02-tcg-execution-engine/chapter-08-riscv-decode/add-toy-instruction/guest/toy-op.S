/* SPDX-License-Identifier: Apache-2.0 */

    .section .text.init
    .globl _start
_start:
    li a0, 40
    li a1, 2

    /* BOOKADD a0, a0, a1: private custom-0 encoding from this experiment. */
    .word 0xaab5050b

    li t0, 42
    bne a0, t0, failed

    li t1, 0x00100000
    li t2, 0x5555
    sw t2, 0(t1)

failed:
    li t1, 0x00100000
    li t2, 0x3333
    sw t2, 0(t1)

1:
    wfi
    j 1b
