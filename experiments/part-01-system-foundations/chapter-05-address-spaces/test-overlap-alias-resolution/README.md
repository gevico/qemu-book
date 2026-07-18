# Test overlap and alias resolution

Status: executable dispatch model with fixed-tag source checks.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Predict which region receives an access when aliases or subregions overlap,
then verify the prediction against QEMU's memory topology rules.

## Prerequisites

- `QEMU_SRC`, `rg`, and the output of the preceding memory-map lab.
- A disposable worktree only if implementing the optional test.

## Files

- `README.md`: source study and model procedure.
- `region_model.py` and `test_region_model.py`: priority, enable, and alias
  offset cases.
- `check-upstream.sh`: validates the corresponding ordering expressions.

## Steps

1. Set `QEMU_SRC` and run `./check-upstream.sh`.
2. Run `python3 -m unittest -v test_region_model.py`, then
   `python3 region_model.py`.
3. Draw the committed topology, predict each address, and compare it with the
   output before changing priority or enable state.
4. Treat the Python code as an explicit ordering model, not a replacement for
   QEMU's FlatView renderer or a complete MemoryRegion implementation.

## Expected results

Four focused tests pass. Higher priority wins, later insertion breaks an equal
priority tie in the modeled list, disabled regions do not dispatch, and aliases
translate their local offset.

## Cleanup

Remove local diagrams/results and discard only optional exercise changes.

## Troubleshooting

- Distinguish an alias from an overlapping independent region.
- Re-run the reasoning after toggling a region's enabled state.
