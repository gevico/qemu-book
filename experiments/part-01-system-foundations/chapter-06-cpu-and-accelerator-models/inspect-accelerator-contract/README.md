# Inspect the accelerator contract

Status: source-inspection.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Trace the common accelerator operations to their TCG and KVM implementations
and identify where RISC-V-specific state enters each path.

## Prerequisites

- A QEMU source tree in `QEMU_SRC`.
- `rg` and Git.

## Files

- `README.md`: the complete source-inspection manual.
- `inspect.sh`: records common, backend, and RISC-V entry-point matches.
- `results/contract.txt`: a local callback comparison table.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`.
2. Locate `AccelOpsClass` in `results/contract.txt` and list its CPU lifecycle
   callbacks.
3. Follow one recorded callback into `target/riscv/tcg/` and one into
   `target/riscv/kvm/`.
4. Record shared policy, backend mechanism, and architecture-specific state in
   separate columns.

## Expected results

The table shows a common orchestration boundary with materially different
backend mechanisms, not a single engine selected by one Boolean.

## Cleanup

Remove `results/contract.txt`; leave the source tree unchanged.

## Troubleshooting

- Use type definitions rather than filename similarity to establish callbacks.
- Record conditional compilation when a callback is absent from a build.
