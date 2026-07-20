# Inspect one-reg state

Status: source-inspection.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Classify which RISC-V CPU registers QEMU gets or sets through KVM's one-reg
interface and when synchronization occurs.

## Prerequisites

- `QEMU_SRC`, Git, and the Linux RISC-V KVM UAPI headers in that tree.
- Basic knowledge of QEMU run-state transitions.

## Files

- `README.md`: source-inspection procedure.
- `inspect.sh`: UAPI groups, QEMU one-reg operations, and lifecycle anchors.
- `results/one-reg-table.txt`: generated state-classification evidence.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`.
2. Inventory the reported register IDs from
   `linux-headers/asm-riscv/kvm.h` and follow get/set operations in
   `target/riscv/kvm/kvm-cpu.c`.
3. Classify core, CSR, timer, vector, and optional extension state.
4. Mark initialization, reset, pre-run, post-run, and migration sync points.

## Expected results

The table shows groups with capability-dependent presence and lifecycle-specific
synchronization rather than an unconditional copy of one CPU structure.

## Cleanup

Remove the local table; do not edit vendored Linux headers.

## Troubleshooting

- Separate QEMU's copied UAPI header from the running host kernel's ABI.
- An unsupported register group must be recorded, not silently omitted.
