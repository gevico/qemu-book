# Dump TCG IR

Status: runnable with a small RISC-V payload.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Separate guest instruction semantics, TCG IR optimization, and host-machine
instruction selection for one short RISC-V code sequence.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`.
- A disassembler for the current host architecture.

## Files

- `README.md`: the manual.
- `run.sh`: bounded one-instruction-TB IR and host-code collection.
- `results/tcg.log`: generated translation dump.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`, then run `./run.sh`.
2. Inspect `results/tcg.log`, which requests guest assembly, pre-optimization
   IR, optimized IR, and output assembly in a bounded run.
3. Isolate one TB and annotate guest instructions, IR temporaries, removed
   operations, and host instructions.
4. Check relevant optimizer and backend paths under `tcg/`.

## Expected results

One guest operation may expand into several IR operations, optimization removes
or folds some of them, and the backend selects host-specific instructions.

## Cleanup

Stop QEMU and remove large log files under `results/`.

## Troubleshooting

- Use a tiny payload and `-one-insn-per-tb` if TB boundaries are ambiguous.
- Host disassembly naturally differs from RISC-V guest assembly.
