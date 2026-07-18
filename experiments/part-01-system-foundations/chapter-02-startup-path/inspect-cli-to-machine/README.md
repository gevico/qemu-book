# Inspect CLI to machine

Status: source-inspection.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Build an evidence-backed call-path map from process entry and option parsing to
RISC-V `virt` machine realization.

## Prerequisites

- A clean QEMU worktree in `QEMU_SRC`.
- `rg` and Git.

## Files

- `README.md`: the manual.
- `inspect.sh`: records fixed source locations and baseline metadata.
- `results/startup-map.txt`: a local call-path note.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`.
2. Review the `qemu_init`, machine construction, and RISC-V registration
   sections in `results/startup-map.txt`.
3. Follow the recorded call sites rather than treating matches as runtime
   ordering by themselves.
4. Record callers, lifecycle phase, and one option whose effect is deferred.

## Expected results

The map crosses generic startup code before selecting and realizing a RISC-V
machine; parsing an option is not equivalent to constructing its object.

## Cleanup

Remove only `results/startup-map.txt`; the QEMU worktree remains unchanged.

## Troubleshooting

- If symbols moved, use `git grep` and `git log --follow -- system/vl.c`.
- Do not infer runtime order from file order alone; verify call sites.
