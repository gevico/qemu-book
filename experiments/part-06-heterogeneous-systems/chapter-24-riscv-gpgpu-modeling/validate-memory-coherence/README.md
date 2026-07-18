# Validate memory coherence

Status: runnable host-side visibility model; a RISC-V guest/device litmus test
remains an extension.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Test which CPU writes an accelerator may observe, which device writes the CPU
may observe, and where the toy ABI requires RISC-V fences or device barriers.

## Prerequisites

- Python 3.10 or newer.
- The command-queue reference model in the sibling project.
- A written memory-ordering contract for coherent and non-coherent modes.

## Files

- `README.md`: model limits and litmus-test procedure.
- `coherence_model.py`: visibility-order enumerator for payload and doorbell.
- `test_coherence_model.py`: ordered and unordered outcome checks.
- `results/`: local guest/device observations; ignored by Git.

## Steps

1. Run `python3 coherence_model.py`, then `python3 -m unittest -v`.
2. Explain why the no-fence model permits both `0` and `42`, while the release
   constraint leaves only `42` when the doorbell becomes visible.
3. Translate the written contract into a RISC-V guest test. Run the no-barrier
   variant only as a negative control; absence of a stale observation does not
   prove the sequence portable.
4. Add the ABI-required RISC-V fence or device synchronization and repeat with
   trace points. Test reset, completion, and interrupt ordering separately.

## Expected results

The committed model prints `[0, 42]` without ordering and `[42]` with the
release constraint; both tests pass. Hardware or QEMU runs remain observations
to compare with the contract, not a replacement for the RISC-V memory model.

## Cleanup

Remove `__pycache__/`, guest/device build products, and local `results/` logs.

## Troubleshooting

- QEMU scheduling is not a substitute for a formal memory-ordering contract.
- Separate cache coherence, DMA mapping, and interrupt ordering questions.
- The Python enumerator is intentionally smaller than RVWMO; do not cite it as
  proof that a particular physical implementation must expose a stale value.
