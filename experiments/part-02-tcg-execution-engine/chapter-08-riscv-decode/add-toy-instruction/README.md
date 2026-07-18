# Add a toy instruction

Status: reviewable QEMU patch, executable encoding tests, and a bare-metal smoke
guest for a deliberately private opcode.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Exercise the complete decode-to-semantics path with an intentionally private
opcode while keeping production ISA claims out of the experiment.

## Prerequisites

- A disposable QEMU branch, RISC-V cross-toolchain, and debug TCG build.
- A reserved/custom opcode chosen only for local testing.
- Python 3, `rg`, and GNU `timeout`.

## Files

- `README.md`: coding and review plan.
- `qemu-book-toy.patch`: two-file decoder/translator patch for the fixed tag.
- `toy_opcode.py` and `test_toy_opcode.py`: encoder and overlap boundary tests.
- `guest/toy-op.S` and `guest/linker.ld`: positive bare-metal smoke case.
- `run-smoke.sh`: runs the guest only against an explicitly selected patched
  QEMU binary.

## Steps

1. Run `python3 -m unittest -v test_toy_opcode.py`. The chosen pattern is
   `funct7=0x55`, `funct3=0`, opcode `custom-0`; its semantics are
   `rd = rs1 + rs2` at the current XLEN.
2. In a disposable checkout of `v11.1.0-rc0`, run
   `git apply --check /path/to/qemu-book-toy.patch`, then apply it and rebuild
   `qemu-system-riscv64` with TCG enabled.
3. Set `QEMU_SYSTEM_RISCV64` to that binary and run `./run-smoke.sh`. The guest
   encodes `BOOKADD a0,a0,a1` as the literal word `0xaab5050b` and reaches the
   `virt` test finisher only when the result is 42. The run is capped at 20
   seconds by default; use `RUN_TIMEOUT_SECONDS` for a slower host.
4. Flip bit 25 in the guest word. The adjacent `funct7` value must take the
   illegal-instruction path; inspect the trap before restoring the positive
   fixture.
5. Review the patch for decoder overlap, XLEN behavior, translator exits, and
   the missing architectural extension gate. That missing gate is intentional
   here and is one reason the patch is not suitable for upstream submission.

## Expected results

The Python suite passes five cases, `git apply --check` accepts the patch at the
fixed review tag, and the patched-QEMU smoke run exits through the pass
finisher. Adjacent encodings remain outside the private decoder pattern.

## Cleanup

Delete only this experiment's `build/` and `results/` directories, then discard
the disposable QEMU worktree.

## Troubleshooting

- Decoder overlap is a design error; inspect generated-decoder diagnostics.
- Never present the private opcode as an upstream or standardized extension.
- A stock QEMU must trap on the private word. If it succeeds, verify that
  `QEMU_SYSTEM_RISCV64` does not accidentally point at another patched build.
