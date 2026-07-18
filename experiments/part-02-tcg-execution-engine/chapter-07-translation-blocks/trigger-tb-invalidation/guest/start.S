/* SPDX-License-Identifier: Apache-2.0 */

    .section .text.init
    .globl _start
_start:
    la sp, __stack_top
    call guest_main
1:
    wfi
    j 1b
