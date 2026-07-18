# Trace feature history

Status: source-inspection; full history requires a non-shallow clone.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Reconstruct how one RISC-V component reached its current shape and separate
commit facts from inferred engineering motives.

## Prerequisites

- Full official GitLab clone in `QEMU_SRC` with remote
  `https://gitlab.com/qemu-project/qemu`.
- Git and `rg`.

## Files

- `README.md`: history-research procedure.
- `trace_history.sh`: full-history guard plus detailed log and short timeline.
- `results/history.txt` and `results/timeline.txt`: generated Git evidence.

## Steps

1. Set `QEMU_SRC`, choose `FEATURE_PATH` such as `hw/riscv/virt.c` or
   `target/riscv/kvm/kvm-cpu.c`, state one current-design question, and run
   `./trace_history.sh`.
2. Inspect the generated `--follow --stat` history, then run
   `git show --format=fuller COMMIT` for candidates.
3. Use blame only to locate commits, not to infer intent from an author name.
4. Record commit claim, changed constraint, tests, and clearly labeled author
   inference in separate fields.

## Expected results

The ledger forms a dated chain from earlier constraints to current code and
keeps documented rationale separate from interpretation.

## Cleanup

Remove the local ledger; do not rewrite or clean the QEMU source clone.

## Troubleshooting

- Fetch missing history if `--follow` stops at the shallow boundary.
- File renames and code movement require inspecting patches, not just subjects.
