# Inspect H-extension state

Status: source-inspection.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` with the H extension.

## Purpose

Map architectural HS/VS control and status registers to QEMU CPU state,
access checks, reset values, and migration fields.

## Prerequisites

- `QEMU_SRC` and the matching RISC-V privileged-architecture specification.
- `rg` and Git.

## Files

- `README.md`: source/specification comparison procedure.
- `inspect.sh`: fixed-tag constants, storage, CSR, and VMState inventory.
- `results/h-state.txt`: generated evidence locations for the ownership table.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`.
2. Compare the generated constants and stored fields with `hstatus`, `hgatp`,
   `vsstatus`, `vsatp`, interrupt, and delegation state in the specification.
3. Follow the recorded CSR access logic in `target/riscv/tcg/csr.c`.
4. Mark reset and migration coverage using `target/riscv/machine.c`.

## Expected results

The table separates HS-owned controls, virtual supervisor state, delegated
events, and G-stage translation state; not every CSR follows one storage path.

## Cleanup

Remove the local result table and leave the QEMU worktree unchanged.

## Troubleshooting

- Match the specification revision used by QEMU's target release.
- Distinguish an architectural alias from two independent stored fields.
