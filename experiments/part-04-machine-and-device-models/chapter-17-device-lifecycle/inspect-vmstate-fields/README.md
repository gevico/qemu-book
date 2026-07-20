# Inspect VMState fields

Status: source-inspection.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Audit one `virt` device's `VMStateDescription` and justify which fields are
migrated, reconstructed, versioned, or deliberately omitted.

## Prerequisites

- `QEMU_SRC`, `rg`, and basic knowledge of the selected device.
- Use the UART or interrupt controller instantiated by `hw/riscv/virt.c`.

## Files

- `README.md`: audit procedure.
- `inspect.sh`: UART structure, reset, VMState, hook, and version inventory.
- `results/vmstate-audit.txt`: generated field evidence.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh` to locate the UART state structure,
   reset path, and `VMStateDescription`.
2. Classify guest-visible registers, derived values, host handles, timers, and
   links.
3. Record version IDs, subsections, pre/post hooks, and validation callbacks.
4. Explain each omitted field using reset/reconstruction and compatibility
   evidence, not guesswork.

## Expected results

Guest-visible durable state is represented explicitly or reconstructed by a
documented hook; host-only resources are not serialized as raw handles.

## Cleanup

Remove the local audit; leave the source tree unchanged.

## Troubleshooting

- A field can be migrated indirectly through a subsection or parent object.
- Search by structure member as well as by device type name.
