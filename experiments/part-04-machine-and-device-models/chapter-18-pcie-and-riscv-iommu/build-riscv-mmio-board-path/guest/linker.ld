/* SPDX-License-Identifier: Apache-2.0 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    /* With -bios none, the RISC-V virt reset stub jumps to DRAM base. */
    . = 0x80000000;
    .text : { *(.text.init) *(.text*) } :text
    .rodata : { *(.rodata*) } :text
    . = ALIGN(4096);
    .data : { *(.data*) } :data
    .bss : { *(.bss*) *(COMMON) } :data
}
