# Model a command queue

Status: runnable host-side protocol model; QEMU device integration remains a
separate tree-out exercise.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; controller and
guest context RISC-V `riscv64`.

## Purpose

Specify a minimal accelerator command queue that makes producer/consumer
ownership, descriptor validation, ordering, completion, and error recovery
observable.

## Prerequisites

- Python 3.10 or newer.
- QEMU device-model knowledge for the optional tree-out implementation.
- A written toy ABI; no claim of compatibility with a real GPU.

## Files

- `README.md`: ABI, execution, and implementation notes.
- `queue_model.py`: bounded queue and vector-add reference behavior.
- `test_queue_model.py`: validation, queue-full, reset, and success tests.
- `results/`: optional local output; ignored by Git.

## Steps

1. Run `python3 -m unittest -v` in this directory.
2. Read `Descriptor`, `_validate()`, `submit()`, `run_one()`, and `reset()` in
   that order; record who owns every sequence at each step.
3. Change the queue depth to one and add a test that submits three commands;
   verify that memory use remains bounded and failed tags receive completions.
4. Use the model as an oracle when defining MMIO registers, DMA descriptors,
   barriers, interrupts, and VMState for a tree-out QEMU device. Do not copy
   Python object layout into a guest ABI.

## Expected results

The five committed tests pass. Invalid commands never enter the pending queue,
queue-full behavior is bounded, vector addition is deterministic, and reset
turns each pending tag into a reset completion.

## Cleanup

Remove `__pycache__/` and local `results/`. Discard any disposable QEMU branch
after preserving reviewed patches.

## Troubleshooting

- Treat every descriptor field as untrusted guest input.
- A queue that works only without wraparound is incomplete.
- This model copies Python sequences; a QEMU device must instead define and
  test DMA mapping, unmapping, cancellation, and migration lifetimes.
