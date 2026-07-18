# Prototype an AI accelerator

Status: runnable host-side functional oracle; no upstream QEMU accelerator or
cycle-accurate hardware model is claimed.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` system context.

## Purpose

Specify a minimal inference-accelerator ABI and implement it in reviewable
stages without conflating functional emulation with cycle-accurate hardware.

## Prerequisites

- Python 3.10 or newer.
- QEMU qdev, MemoryRegion, IRQ, DMA, reset, and migration knowledge for the
  optional tree-out implementation.
- A toy public tensor operation and explicitly licensed test vectors.

## Files

- `README.md`: staged specification and implementation plan.
- `accelerator_model.py`: bounded matrix-multiply queue and reset oracle.
- `test_accelerator_model.py`: shape, buffer, queue, reset, and result tests.

## Steps

1. Run `python3 -m unittest -v` and inspect the 2-by-2 reference result.
2. Review `_validate()` before `execute_one()`. Explain which checks must occur
   before a QEMU device multiplies dimensions or maps guest memory.
3. Specify identification, feature, queue, tensor-shape, completion, error, and
   reset registers with explicit size and overflow limits.
4. Implement identification/reset first, then one synchronous operation, then
   queued DMA and interrupts as separate tree-out patches.
5. Add malformed-input, bounds, endian, reset-in-flight, migration, and happy-
   path qtests at the corresponding stage. Compare every behavior with the
   oracle and written ABI, and record deliberate omissions
   such as timing or proprietary numeric formats.

## Expected results

The five committed tests pass: the oracle computes `(19, 22, 43, 50)`, rejects
bad shapes and buffers, bounds the queue, and completes pending tags on reset.
QEMU integration remains a separately reviewed experiment.

## Cleanup

Remove `__pycache__/`, generated builds, and the disposable QEMU branch after
preserving reviewed, licensed patches.

## Troubleshooting

- Treat dimensions and guest addresses as untrusted values before arithmetic.
- Do not add timing claims that the functional model cannot validate.
- Python integers do not overflow; a C or Rust device must use checked
  arithmetic before deriving byte counts or DMA ranges.
