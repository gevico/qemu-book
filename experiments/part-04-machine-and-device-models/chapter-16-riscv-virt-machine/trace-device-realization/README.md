# Trace device realization

Status: source-inspection with runnable monitor observation.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Follow the RISC-V `virt` UART from object creation through properties,
realization, MMIO mapping, IRQ connection, and runtime containment.

## Prerequisites

- `QEMU_SRC` and `QEMU_SYSTEM_RISCV64`.
- A human monitor; no guest payload is required.

## Files

- `README.md`: source and runtime procedure.
- `inspect.sh`: UART source anchors plus QOM and memory monitor views.
- `results/uart-source.txt` and `results/uart-runtime.txt`: generated evidence.

## Steps

1. Set `QEMU_SRC` and `QEMU_SYSTEM_RISCV64`, then run `./inspect.sh`.
2. Follow the recorded qdev/sysbus helpers to the UART device implementation.
3. Inspect the captured `info qom-tree` and `info mtree -f` views.
4. Match object path, MMIO range, IRQ endpoint, and property values.

## Expected results

The device becomes guest-visible only after several distinct lifecycle and
wiring operations; containment alone does not map MMIO or connect an IRQ.

## Cleanup

Quit QEMU and remove local notes.

## Troubleshooting

- The UART implementation filename may be generic rather than RISC-V-specific.
- Verify the machine-selected device type before following its callbacks.
