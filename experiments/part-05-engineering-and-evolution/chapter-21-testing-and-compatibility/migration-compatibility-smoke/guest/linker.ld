/* SPDX-License-Identifier: Apache-2.0 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

SECTIONS
{
    . = 0x80200000;
    .text : { *(.text.init) *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(16);
    . += 16K;
    __stack_top = .;
}
