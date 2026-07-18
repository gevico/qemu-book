# Map memory regions

Status: runnable.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Recover the realized RISC-V `virt` physical address map and connect each range
to its owning `MemoryRegion`.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and a human monitor.
- The `virt` machine source in `QEMU_SRC`.

## Files

- `README.md`: the manual.
- `run.sh`: captures a flattened monitor memory tree.
- `results/mtree.txt`: generated monitor output.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect the saved `info mtree -f` output.
3. Mark RAM, boot ROM, UART, interrupt controller, PCIe, and platform-bus
   ranges.
4. Match the addresses to the map table and initialization in
   `hw/riscv/virt.c`.

## Expected results

The flattened view shows a dispatch map assembled from nested regions; it is
not merely a copy of one C array.

## Cleanup

Quit QEMU and remove `results/`.

## Troubleshooting

- Use monitor `help info mtree` to check option support.
- Machine properties can add or remove regions, so record the full command.
