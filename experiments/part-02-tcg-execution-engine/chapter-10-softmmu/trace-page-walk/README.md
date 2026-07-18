# Trace a page walk

Status: executable Sv39 walk model with fixed-tag source checks.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Follow one RISC-V virtual access from a TCG load/store through TLB lookup,
page-table walking, permission checks, and physical dispatch.

## Prerequisites

- `QEMU_SRC` and knowledge of the guest's `satp` mode and page tables.
- Python 3 and `rg`.

## Files

- `README.md`: source-walk procedure.
- `sv39_walk.py` and `test_sv39_walk.py`: non-mutating three-level walk model.
- `check-upstream.sh`: checks the corresponding RISC-V QEMU paths.

## Steps

1. Set `QEMU_SRC` and run `./check-upstream.sh`.
2. Run `python3 -m unittest -v test_sv39_walk.py`.
3. Follow the modeled VPN indices, PTE addresses, permissions, A/D policy, and
   final physical address alongside `target/riscv/tcg/cpu_helper.c`.
4. Change one PTE flag and predict the exact `PageFault` boundary before
   rerunning the tests. The model is one-stage Sv39 only.

## Expected results

Three tests cover a three-level 4 KiB mapping, dirty-bit enforcement, and the
architecturally invalid write-without-read encoding. Agreement with QEMU is
established by reviewing the checked source, not by claiming the model is QEMU.

## Cleanup

Remove local calculations and optional traces; leave the source tree unchanged.

## Troubleshooting

- Record `satp`, privilege, `SUM`, and `MXR`; missing state changes the result.
- Do not mix first-stage translation with H-extension two-stage translation.
