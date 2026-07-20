# Map thread topology

Status: runnable on a host that can list per-process threads.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Observe which host threads exist for a paused SMP RISC-V machine and avoid
equating one guest hart with the entire QEMU process.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and Linux `ps`, or an equivalent thread inspector.

## Files

- `README.md`: the manual.
- `run.sh`: captures Linux or macOS thread views for two TCG policies.
- `results/multi-threads.txt`: explicit multi-threaded TCG host-thread view.
- `results/single-threads.txt`: single-threaded TCG host-thread view.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Compare `results/multi-threads.txt` with
   `results/single-threads.txt`.
3. Record which names are vCPU, main-loop, or helpers; do not infer roles only
   from the number of lines.
4. Extend the script with `info cpus` if a runtime hart/thread mapping is
   required for the tested host.

## Expected results

Thread count and names reflect main-loop, vCPU, and helper contexts; the
single-thread TCG policy changes execution topology.

## Cleanup

The script terminates only the exact QEMU PIDs it started. Remove this
project's generated `results/` directory when finished.

## Troubleshooting

- Replace `ps -L` with the host's native thread viewer on non-Linux systems.
- A paused CPU may still leave non-vCPU helper threads visible.
