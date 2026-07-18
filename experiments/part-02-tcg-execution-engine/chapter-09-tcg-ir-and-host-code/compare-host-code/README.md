# Compare host code

Status: runnable only when two host-architecture builds or CI artifacts are
available.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` guest.

## Purpose

Compare host code generated for the same RISC-V TB on two TCG hosts while
holding source revision, guest image, and QEMU options constant.

## Prerequisites

- Equivalent QEMU builds on two host architectures, such as x86-64 and AArch64.
- The same checksum-verified `RISCV_GUEST_IMAGE` on both hosts.

## Files

- `README.md`: collection and comparison manual.
- `collect.sh`: host-labelled checksums, build identity, and bounded TCG log.
- `results/HOST/tcg.log`: locally generated per-host output.

## Steps

1. Set identical `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE` inputs on both
   hosts, set a safe `HOST_LABEL`, and run `./collect.sh`.
2. Compare the saved SHA-256 files and QEMU versions before the TCG logs.
3. Select the same guest PC range and compare IR before comparing host code.
4. Attribute differences to backend constraints using `tcg/HOST/` source.

## Expected results

Guest semantics and high-level IR remain comparable while register allocation,
instruction selection, and calling sequences differ by host backend.

## Cleanup

Remove generated host logs; do not delete shared guest images.

## Troubleshooting

- A different QEMU commit or guest checksum invalidates the comparison.
- Normalize addresses only after preserving the unmodified raw logs.
