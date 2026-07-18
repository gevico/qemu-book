# Compare TCG thread modes

Status: runnable with a deterministic SMP RISC-V workload.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare correctness and throughput under single-thread TCG and MTTCG while
keeping the guest workload and virtual hardware constant.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and an SMP-capable `RISCV_GUEST_IMAGE`.
- A guest benchmark with a fixed work unit and correctness checksum.

## Files

- `README.md`: the manual.
- `benchmark_modes.py`: identical command runner, timing, serial capture, and
  checksums for both TCG thread policies.
- `results/summary.json`: generated repetitions and serial SHA-256 values.

## Steps

1. Set `QEMU_SYSTEM_RISCV64`, `RISCV_GUEST_IMAGE`, and an optional
   `EXPECTED_MARKER`, then run `./benchmark_modes.py`.
2. The runner performs five repetitions by default; change `RUNS` only while
   recording the new value.
3. Compare serial SHA-256 values first, then calculate median durations from
   `results/summary.json` and inspect host thread layout separately.
4. Relate differences to synchronization in `accel/tcg/` and RISC-V atomics.

## Expected results

Both modes produce the same guest result; MTTCG can expose host parallelism but
may add synchronization costs that depend on the workload.

## Cleanup

Stop each guest cleanly and remove generated result files.

## Troubleshooting

- Do not compare runs with different SMP topology or guest frequency policy.
- If `thread=multi` is unsupported, record the build configuration and skip.
