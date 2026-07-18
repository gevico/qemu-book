# Experiment title

Status: planned | runnable | source-inspection

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

State one question that the experiment answers and one claim it can falsify.

## Prerequisites

- A QEMU source tree in `QEMU_SRC`.
- A RISC-V-enabled build in `QEMU_BUILD`, when execution is required.
- List all guest images, toolchains, kernel capabilities, and optional tools.

## Files

- `README.md`: this manual.
- List committed scripts, fixtures, and expected outputs. Mark missing planned
  files explicitly.

## Steps

1. Validate the source and record the exact revision.
2. Run one controlled command at a time.
3. Save output under an untracked `results/` directory.
4. Compare the observation with the source path named by the manual.

## Expected results

Describe invariant structure rather than brittle line numbers or timing values.
State how TCG and KVM results may differ.

## Cleanup

Remove only files created under this project and stop only the QEMU process
started by the experiment.

## Troubleshooting

- If a file moved after `v11.1.0-rc0`, use `git log --follow` and record the
  replacement path.
- If KVM is unavailable, mark the KVM branch skipped; do not present TCG output
  as hardware-virtualization output.
