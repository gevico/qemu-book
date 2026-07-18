# Inject a RISC-V trap

Status: runnable bare-metal RISC-V M-mode trap fixture for TCG.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Cause one synchronous exception and verify RISC-V trap state, privilege
transition, handler entry, and return under TCG.

## Prerequisites

- RISC-V cross-toolchain, TCG-enabled QEMU, and GNU `timeout`.
- `rg`; generated build and trace files remain under ignored directories.

## Files

- `README.md`: design and validation procedure.
- `guest/trap.S`: vector setup, a fixed illegal word, state capture, and checks.
- `guest/linker.ld`: RISC-V `virt` RAM layout.
- `run.sh`: build, disassembly, TCG trace, and result assertions.

## Steps

1. Run `./run.sh`, overriding `RISCV_CC`, `RISCV_OBJDUMP`, or
   `QEMU_SYSTEM_RISCV64` when needed. The guest run is capped at 20 seconds by
   default; use `RUN_TIMEOUT_SECONDS` for a slower host.
2. Inspect `results/trap.disassembly`: `illegal_site` is the 32-bit word
   `0xffffffff`, not an assembler-dependent mnemonic.
3. Inspect `results/trap.log` and `results/serial.log`. The handler records
   `mcause`, `mepc`, and `mtval`; it accepts `mtval` without requiring a value
   that the architecture permits implementations to vary.
4. Compare handler entry with `target/riscv/tcg/cpu_helper.c` at the fixed tag.
   Then remove the `addi t1,t1,4` only for a bounded diagnostic run and explain
   why the unchanged `mepc` traps repeatedly.

## Expected results

The guest prints `trap:2` and exits through the pass finisher. It does so only
after checking `mcause=2`, checking that `mepc` equals `illegal_site`, advancing
`mepc` by four, and returning with `mret`.

## Cleanup

Delete only this experiment's `build/` and `results/` directories.

## Troubleshooting

- Confirm instruction alignment before diagnosing a different trap cause.
- A handler that returns to unchanged `mepc` will intentionally trap again.
- If the toolchain relaxes or inserts unexpected code, use the committed
  disassembly check before interpreting the trace.
