# Measure TLB behavior

Status: runnable direct-map reference model with fixed-tag source checks. It is
not presented as a live QEMU TLB-miss counter.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare repeated-page, bounded sequential-page, and single-index conflict
patterns against the fast-table index used by the fixed QEMU source, without
confusing the model with a live hardware or emulator performance counter.

## Prerequisites

- Python 3 and `rg`.
- A QEMU `v11.1.0` or `v11.1.0-rc0` tree for the optional source check.

## Files

- `README.md`: experiment design.
- `tlb_index_model.py`: deterministic address patterns and a direct-mapped
  page-tag table.
- `test_tlb_index_model.py`: reuse, warm-up, conflict, and input tests.
- `check-upstream.sh`: checks the index and resize constants at the source tag.
- `run-model.sh`: runs tests and writes an ignored CSV result.

## Steps

1. Run `./run-model.sh`. Optionally set `QEMU_SRC=/path/to/qemu` so the script
   checks `accel/tcg/cputlb.c` and `accel/tcg/tlb-bounds.h` first.
2. Inspect `results/modeled-counts.csv`. Same-page and 64-page patterns warm
   their entries; pages 256 slots apart continually replace one another under
   the default 256-entry model.
3. Change `--entries` and the working-set size. Explain which differences come
   only from the index formula and which would require the real resize window.
4. If extending this into a plugin or source instrument, keep the new observed
   counter separate from these modeled misses. A memory callback count is not
   a TLB-miss count.

## Expected results

The tests pass four cases. With 4096 accesses and 256 entries, the model reports
one miss for same-page access, 64 warm-up misses for a 64-page working set, and
4096 modeled misses for the deliberately conflicting pair. These numbers prove
properties of the stated model, not the complete QEMU SoftMMU.

## Cleanup

Delete only this experiment's `results/` directory.

## Troubleshooting

- A memory callback count is not automatically a TLB miss count.
- Disable unrelated guest activity before interpreting small differences.
- QEMU dynamically resizes the table and also has slow/victim paths; read the
  checked source before mapping the model's numbers onto a real run.
