# Inspect QOM tree

Status: runnable.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare QOM's type hierarchy with the containment tree of a realized RISC-V
`virt` machine.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` with a human monitor.
- No guest image is required.

## Files

- `README.md`: the manual.
- `run.sh`: captures `info qom-tree` and `qom-list /machine` non-interactively.
- `results/qom-tree.txt`: optional saved output.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect `/machine`, `/machine/soc`, and CPU objects in
   `results/qom-tree.txt`.
3. Repeat interactively with `qom-list PATH` and `qom-get PATH PROPERTY` for
   one concrete object.
4. Find its `TypeInfo` registration in the RISC-V or core source.

## Expected results

Containment paths identify object instances, while `TypeInfo` inheritance
describes class behavior; the two trees answer different questions.

## Cleanup

Run `quit`; remove captured output if it is no longer needed.

## Troubleshooting

- Monitor command availability can vary; run `help qom-list` first.
- Quote paths containing punctuation when using a QMP client.
