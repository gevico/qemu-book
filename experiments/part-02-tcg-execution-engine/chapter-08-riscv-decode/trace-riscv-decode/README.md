# Trace RISC-V decode

Status: source-inspection with an optional GDB trace.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Follow one ordinary RISC-V instruction from generated decode tables through a
`trans_*` function to emitted TCG operations.

## Prerequisites

- `QEMU_SRC`, `rg`, and a debug build for the optional breakpoint trace.
- Basic familiarity with RISC-V instruction fields.

## Files

- `README.md`: the complete source-walk procedure.
- `inspect.sh`: fixed-tag ADDI pattern, translator, and inclusion map.
- `results/decode-path.txt`: generated evidence map.

## Steps

1. Set `QEMU_SRC` and run `./inspect.sh`.
2. Use `results/decode-path.txt` to find the `addi` pattern and matching
   `trans_addi` function.
3. Follow operand extraction, legality checks, and TCG emission from those
   source anchors.
4. Optionally break on the translator in a debug build and translate a minimal
   payload containing the instruction.

## Expected results

The path separates bit-pattern recognition, architectural legality, and
semantic emission instead of implementing all three in one switch statement.

## Cleanup

Remove local notes and detach the debugger without modifying the source tree.

## Troubleshooting

- Generated decoder files may live in the build tree; start from `.decode`.
- Disable optimization if a translator breakpoint is eliminated or inlined.
