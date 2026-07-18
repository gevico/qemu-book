# Sketch a G233 platform

Status: runnable evidence-plan validator; no G233 Machine or device model is
claimed to exist in upstream QEMU.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; proposed primary
architecture RISC-V `riscv64`.

## Purpose

Turn available G233 hardware and firmware evidence into a scoped QEMU machine
plan with explicit unknowns, boot milestones, and component reuse decisions.

## Prerequisites

- Python 3.10 or newer.
- Authoritative public G233 memory map, interrupt, boot, and peripheral data
  before changing any component from `unknown`.
- A firmware image whose redistribution and execution terms are understood.

## Files

- `README.md`: evidence and design procedure.
- `platform.example.json`: intentionally unknown starting inventory.
- `validate_platform.py`: status, evidence, and minimum-component validator.
- `test_validate_platform.py`: positive and negative validation tests.
- `fixtures/invalid-verified.json`: deliberately unsupported claim.

## Steps

1. Run `python3 validate_platform.py platform.example.json`, followed by
   `python3 -m unittest -v`.
2. Copy the example to a local result file. Build an evidence table for harts,
   reset, ROM/RAM, interrupts, timers, UART, storage, and firmware handoff.
3. Mark each field verified, inferred, unknown, or out of scope. The validator
   rejects verified/inferred entries that lack an evidence reference.
4. Compare K230 and `virt` components for semantic reuse, not name similarity.
5. Define staged milestones: reset/serial, firmware, kernel boot, then selected
   devices and migration tests.

## Expected results

The committed unknown inventory passes, while the deliberately unsupported
verified fixture fails. A filled plan remains reviewable only when every
verified or inferred value links to evidence; Machine implementation is a
separate tree-out project.

## Cleanup

Remove `__pycache__/` and local proprietary artifacts; retain only
redistributable evidence and plans according to their licenses.

## Troubleshooting

- If documentation is unavailable, leave the component unknown rather than
  reverse-engineering beyond authorization.
- Similar SoCs can still have incompatible reset and interrupt behavior.
