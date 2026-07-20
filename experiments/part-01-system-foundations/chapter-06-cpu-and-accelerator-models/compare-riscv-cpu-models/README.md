# Compare RISC-V CPU models

Status: runnable.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare named, generic, and host-backed RISC-V CPU models without assuming
that an extension string completely defines runtime behavior.

## Prerequisites

- `QEMU_SYSTEM_RISCV64`.
- KVM `host` model checks require a RISC-V KVM host.

## Files

- `README.md`: the manual.
- `run.sh`: model inventory and paused-register capture for available models.
- `results/cpu-models.txt`: generated model/property inventory.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect `results/cpu-models.txt`, then compare the saved register views for
   `rv64` and `max` when both are available.
3. Query expansion/property data for `rv64` with QMP or inspect
   `target/riscv/cpu.c`; monitor registers alone do not enumerate extensions.
4. On RISC-V KVM only, inspect `-cpu host`; otherwise mark it skipped.

## Expected results

CPU models constrain exposed architectural features, while accelerator support
can further restrict which state is executable or configurable.

## Cleanup

Quit each paused machine and remove `results/`.

## Troubleshooting

- CPU syntax evolves; use `-cpu help` from the tested binary.
- Do not compare a KVM-only host model with TCG as if both were supported.
