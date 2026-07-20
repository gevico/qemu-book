# Observe TB lifecycle

Status: runnable with a small RISC-V payload.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Observe when a RISC-V basic execution region becomes a translation block and
which exits can be directly chained.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and a deterministic image in `RISCV_GUEST_IMAGE`.
- Enough disk space for a bounded TCG log.

## Files

- `README.md`: the manual.
- `run.sh`: two bounded collections with normal and one-instruction TBs.
- `results/normal.log` and `results/one-insn.log`: generated TCG logs.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`, then run `./run.sh`.
2. Confirm `in_asm`, `exec`, and `nochain` in `results/log-items.txt`.
3. Compare `normal.log` with the run using
   `-accel tcg,one-insn-per-tb=on`; record TB boundaries and exits.
4. Map observations to `accel/tcg/cpu-exec.c` and `accel/tcg/translate-all.c`.

## Expected results

Normal TBs contain multiple guest instructions until a boundary condition;
forcing one instruction per TB exposes additional lookup/dispatch overhead.

## Cleanup

Let both bounded runs return, then remove this project's generated
`results/normal.log`, `results/one-insn.log`, or the complete `results/`
directory if the logs are too large to retain.

## Troubleshooting

- Logging names are build-defined, so always begin with `-d help`.
- Reduce the payload or add a timeout when the log grows too quickly.
