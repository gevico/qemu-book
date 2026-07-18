# Model two-stage translation

Status: runnable host-side responsibility and fault model; a real HS/VS guest
fixture remains an optional extension.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` with the H extension.

## Purpose

Calculate one guest virtual to guest physical to host physical translation and
identify where faults are attributed at each stage.

## Prerequisites

- Python 3.10 or newer.
- RISC-V H-extension specification and a QEMU TCG build exposing H for the
  optional guest validation.

## Files

- `README.md`: address, ownership, and fault procedure.
- `two_stage_model.py`: mapping composition and indirect-fault model.
- `test_two_stage_model.py`: success, permission, and three fault tests.

## Steps

1. Run `python3 -m unittest -v` and read `translate()` in execution order.
2. Change the G-stage leaf to read-only and confirm that final permissions are
   the intersection of VS-stage and G-stage permissions.
3. Remove the VS mapping, G-stage leaf, and G-stage backing for the VS PTE in
   turn. Explain why the exception class and `indirect` flag differ.
4. Extend the model with a hand-calculated Sv39x4 fixture, predict `scause`,
   `stval`, `htval`, and `htinst`, then validate the cases under QEMU TCG.

## Expected results

Four committed tests pass. The model distinguishes a VS page fault, a direct
G-stage guest-page fault, and a G-stage fault while fetching a VS PTE; it also
intersects permissions. Exact CSR values still require the optional TCG guest.

## Cleanup

Remove `__pycache__/`, generated page tables, guest builds, and traces.

## Troubleshooting

- G-stage address decomposition is not identical to an ordinary Sv39 walk.
- Record access type because read, write, and execute permissions differ.
- This mapping model is not an Sv39/Sv48 implementation and does not replace
  the RISC-V privileged specification.
