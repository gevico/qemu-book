# Compare host code

Status: runnable only when two host-architecture builds or CI artifacts are
available.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` guest.

## Purpose

Compare host code generated for the same RISC-V TB on two TCG hosts while
holding source revision, guest image, and QEMU options constant.

## Prerequisites

- Equivalent QEMU builds on two host architectures, with RISC-V 64 as the
  reference host and x86-64 or AArch64 as the necessary backend contrast.
- The same checksum-verified `RISCV_GUEST_IMAGE` on both hosts.
- The matching QEMU source and build trees in `QEMU_SRC` and `QEMU_BUILD`.
- Git, GNU `timeout`, and `shasum`.

## Files

- `README.md`: collection and comparison manual.
- `collect.sh`: host-labelled source/build identity, exact command, checksums,
  and bounded TCG log.
- `results/HOST/tcg.log`: locally generated per-host output.

## Steps

1. Set `QEMU_SRC`, `QEMU_BUILD`, `QEMU_SYSTEM_RISCV64`, and the same
   `RISCV_GUEST_IMAGE` on both hosts; set a safe `HOST_LABEL`, then run
   `./collect.sh`.
2. Require equal `commit=` values in both `source-report.txt` files and equal
   guest-image hashes before comparing the TCG logs. The QEMU binary hashes
   identify the two artifacts and normally differ across host architectures.
   Compare the recorded build-metadata hashes or explain configuration
   differences; a matching source commit alone does not prove equivalent
   builds.
3. Select the same guest PC range and compare IR before comparing host code.
4. Start from `tcg/riscv64/` as the reference backend, then attribute the
   contrast to the matching `tcg/HOST/` constraints and emitters.

## Expected results

Guest semantics and high-level IR remain comparable while register allocation,
instruction selection, and calling sequences differ by host backend.

## Cleanup

Remove generated host logs; do not delete shared guest images.

## Troubleshooting

- A different QEMU commit, guest checksum, or material build option invalidates
  the comparison.
- Normalize addresses only after preserving the unmodified raw logs.
