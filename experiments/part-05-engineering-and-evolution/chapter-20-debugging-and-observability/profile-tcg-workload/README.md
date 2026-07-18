# Profile a TCG workload

Status: runnable on a host with a sampling profiler.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` guest under TCG.

## Purpose

Identify host time spent in translation, SoftMMU, dispatch, and generated code
for one fixed RISC-V workload without treating a flame graph as design intent.

## Prerequisites

- Debug-symbol QEMU build and a host profiler such as Linux `perf`.
- A deterministic `RISCV_GUEST_IMAGE` workload with fixed work units.

## Files

- `README.md`: collection and interpretation procedure.
- `profile.sh`: three bounded Linux perf collections with unchanged QEMU args.
- `results/`: local profiler data, reports, and source metadata.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`; record the workload's
   correctness checksum separately, then run `./profile.sh`.
2. The script samples the bounded TCG process three times without changing the
   guest command.
3. Separate generated-code samples from named QEMU functions where supported.
4. Map hot named functions to translation, execution, and memory paths; repeat
   three times before interpreting proportions.

## Expected results

The profile identifies workload-specific hot paths and run-to-run variance;
it does not by itself explain why a path was designed that way.

## Cleanup

Stop the guest and remove profiler data under `results/`.

## Troubleshooting

- Missing symbols make attribution unreliable; verify the debug build first.
- Profiler permissions should be fixed by policy, not by disabling host safety.
