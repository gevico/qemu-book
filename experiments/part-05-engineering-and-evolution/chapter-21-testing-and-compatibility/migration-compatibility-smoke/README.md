# Run a migration compatibility smoke test

Status: runnable bare-metal counter guest and dependency-free QMP orchestrator
for matching and deliberately mismatched RISC-V TCG pairs.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` under TCG for host portability.

## Purpose

Verify that a matching source/destination pair preserves a small guest's RAM,
CPU execution position, and ability to continue UART output through migration.
The busy-loop counter has no active guest timer and does not certify general
device-internal progress.

## Prerequisites

- A QEMU `v11.1.0-rc0` system binary, RISC-V cross compiler, and Python 3.
- Enough host time for two single-threaded TCG VMs.
- A dedicated result directory. The runner marks directories it creates and
  refuses a non-empty unmarked directory, symlinked log targets, and
  non-socket QMP paths before creating or replacing output.

## Files

- `README.md`: migration and validation plan.
- `guest/`: a volatile 64-bit counter that periodically prints to the UART.
- `build-guest.sh`: bare-metal ELF build for the RISC-V `virt` RAM map.
- `migrate_smoke.py`: source/destination launch, QMP, migration, and cleanup.
- `test_migrate_smoke.py`: strict counter-log parser tests.

## Steps

1. Run `./build-guest.sh`, then
   `./migrate_smoke.py --qemu /path/to/qemu-system-riscv64`.
2. Inspect both serial logs. The script waits for source progress, starts a
   Unix-socket migration, requires `completed` at both ends, and requires the
   destination's migrated counter to advance beyond the source observation.
3. Run the same command with `--expect-mismatch`. It gives the destination
   192 MiB while the source has 128 MiB and requires the stream to fail rather
   than claiming compatibility.
4. Run `python3 -m unittest -v test_migrate_smoke.py`. Keep this parser result
   separate from the live QMP evidence.
5. Compare expanded command lines and `query-migrate` status before attributing
   any failure to VMState. This smoke case intentionally has no disk or network
   device, so it is a lower bound, not broad compatibility certification.

## Expected results

The matching run prints `migration_completed=true` and a strictly larger
destination counter. The mismatched run prints `mismatch_rejected=true`. QMP
and process stderr remain under `results/` for review.

## Cleanup

The script sends QMP `quit` and terminates only its child processes on timeout.
Remove this experiment's `build/` and `results/` directories when finished.

## Troubleshooting

- Keep migration transport failures separate from state compatibility issues.
- Compare expanded command lines before debugging VMState.
- If the source emits no counter, inspect the selected binary, `-bios none`,
  the ELF link address, and the source stderr before touching migration code.
