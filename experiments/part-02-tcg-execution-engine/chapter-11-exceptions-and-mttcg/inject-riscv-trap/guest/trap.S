/* SPDX-License-Identifier: Apache-2.0 */

    .equ UART_TX, 0x10000000
    .equ TEST_FINISHER, 0x00100000
    .equ FINISHER_PASS, 0x5555
    .equ FINISHER_FAIL, 0x3333
    .equ CAUSE_ILLEGAL_INSTRUCTION, 2

    .section .text.init
    .globl _start
_start:
    la t0, trap_handler
    csrw mtvec, t0

    la t0, trap_seen
    sd zero, 0(t0)

    .globl illegal_site
illegal_site:
    .word 0xffffffff

    la t0, trap_seen
    ld t1, 0(t0)
    li t2, 1
    bne t1, t2, failed

    la t0, saved_mcause
    ld t1, 0(t0)
    li t2, CAUSE_ILLEGAL_INSTRUCTION
    bne t1, t2, failed

    la t0, saved_mepc
    ld t1, 0(t0)
    la t2, illegal_site
    bne t1, t2, failed

    li t0, UART_TX
    li t1, 't'
    sb t1, 0(t0)
    li t1, 'r'
    sb t1, 0(t0)
    li t1, 'a'
    sb t1, 0(t0)
    li t1, 'p'
    sb t1, 0(t0)
    li t1, ':'
    sb t1, 0(t0)
    li t1, '2'
    sb t1, 0(t0)
    li t1, '\n'
    sb t1, 0(t0)

    li t0, TEST_FINISHER
    li t1, FINISHER_PASS
    sw t1, 0(t0)

failed:
    li t0, TEST_FINISHER
    li t1, FINISHER_FAIL
    sw t1, 0(t0)

1:
    wfi
    j 1b

    .balign 4
trap_handler:
    csrr t0, mcause
    csrr t1, mepc
    csrr t2, mtval

    la t3, saved_mcause
    sd t0, 0(t3)
    la t3, saved_mepc
    sd t1, 0(t3)
    la t3, saved_mtval
    sd t2, 0(t3)
    la t3, trap_seen
    li t4, 1
    sd t4, 0(t3)

    addi t1, t1, 4
    csrw mepc, t1
    mret

    .section .bss
    .balign 8
trap_seen:
    .dword 0
saved_mcause:
    .dword 0
saved_mepc:
    .dword 0
saved_mtval:
    .dword 0
