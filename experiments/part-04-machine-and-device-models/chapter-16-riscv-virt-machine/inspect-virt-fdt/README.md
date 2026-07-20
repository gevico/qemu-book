# Inspect the `virt` FDT

Status: runnable with the Device Tree Compiler.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare QEMU's generated `virt` device tree with the machine's realized CPU,
memory, interrupt, and bus topology.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and `dtc`.
- No guest image is required.

## Files

- `README.md`: the manual.
- `run.sh`: DTB generation, decompilation, and basic node checks.
- `results/virt.dtb` and `results/virt.dts`: generated locally.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect the generated `virt.dtb` and decompiled `virt.dts`.
3. Inventory CPU, memory, CLINT/ACLINT, AIA/PLIC, UART, PCIe, and chosen nodes.
4. Match node construction and addresses to `hw/riscv/virt.c`.

## Expected results

The FDT describes the selected machine configuration and changes when relevant
machine, CPU, memory, or interrupt-controller properties change.

## Cleanup

Remove the generated `results/` directory.

## Troubleshooting

- QEMU exits after dumping the DTB; this is expected for the dump operation.
- Record command-line properties before comparing two device trees.
