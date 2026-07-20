# Map PCIe topology

Status: runnable.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Relate QEMU's PCIe object/bus topology to the ECAM and MMIO windows exposed by
the RISC-V `virt` machine.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` with monitor support.
- A guest with `lspci` is optional for the guest-enumeration branch.

## Files

- `README.md`: monitor and source procedure.
- `run.sh`: paused `virtio-net-pci` topology capture without a guest.
- `results/pci-map.txt`: generated PCI, qtree, and mtree views.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect the captured `info pci`, `info qtree`, and `info mtree -f` output.
3. Record bus/device/function, BARs, ECAM, and host-bridge windows.
4. If a guest is available, compare `lspci -vv`; then inspect
   `hw/riscv/virt.c` and its PCI host implementation.

## Expected results

The logical PCI bus tree, configuration space, and CPU-visible MMIO windows
are related but distinct representations of the same realized fabric.

## Cleanup

Shut down or quit QEMU and remove local results.

## Troubleshooting

- Device BAR allocation can change with the complete device set.
- Record whether firmware or the guest assigned resources.
