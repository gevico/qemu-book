# Compare TCG thread modes

Status: runnable with a deterministic SMP RISC-V workload.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare correctness and throughput under single-thread TCG and MTTCG while
keeping the guest workload and virtual hardware constant.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and an SMP-capable `RISCV_GUEST_IMAGE`.
- Python 3 and a guest benchmark with a fixed work unit, a completion marker,
  and a stable known-correct result field.

## Files

- `README.md`: the manual.
- `benchmark_modes.py`: identical command runner, timing, serial capture,
  result assertion, and checksums for both TCG thread policies.
- `results/summary.json`: generated commands, validated result fields,
  repetitions, and image/serial SHA-256 values.

## Steps

1. Set `QEMU_SYSTEM_RISCV64`, `RISCV_GUEST_IMAGE`, `EXPECTED_MARKER`,
   `RESULT_REGEX`, and `EXPECTED_RESULT`, then run `./benchmark_modes.py`.
   `RESULT_REGEX` must contain exactly one capture group, for example
   `^RESULT sha256=([0-9a-f]{64})$`.
2. The runner performs five repetitions by default; change `RUNS` only while
   recording the new value.
3. The runner requires the captured result to equal `EXPECTED_RESULT` in every
   repetition and across both modes. Calculate median durations only after
   that assertion passes; whole-serial hashes are retained as artifact
   identity, not used as the correctness field.
4. Relate differences to synchronization in `accel/tcg/` and RISC-V atomics.

## Expected results

Both modes produce the same guest result; MTTCG can expose host parallelism but
may add synchronization costs that depend on the workload.

## Cleanup

Stop each guest cleanly and remove generated result files.

## Troubleshooting

- Do not compare runs with different SMP topology or guest frequency policy.
- If `thread=multi` is unsupported, record the build configuration and skip.
