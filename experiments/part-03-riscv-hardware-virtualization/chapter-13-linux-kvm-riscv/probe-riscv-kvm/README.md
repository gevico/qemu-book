# Probe RISC-V KVM

Status: runnable only on a Linux RISC-V host with KVM enabled.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Prove that the host can create a RISC-V KVM VM and identify supported vCPU
features before attempting any KVM experiment.

## Prerequisites

- Linux on RISC-V with readable and writable `/dev/kvm`.
- `QEMU_SYSTEM_RISCV64`; `kvm-ok` is not a substitute for an actual QEMU test.

## Files

- `README.md`: probe procedure.
- `probe.sh`: host, device, accelerator, and paused-vCPU probe with explicit
  skip output.
- `results/probe.txt`: generated host and QEMU output.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./probe.sh`.
2. Inspect the recorded host architecture, `/dev/kvm` permissions, QEMU
   version, and accelerator list.
3. On a capable host the script creates a paused `-cpu host` vCPU, queries
   `info cpus`, and quits; every other host gets an explicit skip record.
4. Relate accepted properties to `target/riscv/kvm/kvm-cpu.c` and the Linux
   RISC-V KVM UAPI header.

## Expected results

On a capable host QEMU creates and pauses a KVM-backed RISC-V vCPU; other hosts
produce an explicit skip record rather than a simulated success.

## Cleanup

Quit the monitor and remove `results/`.

## Troubleshooting

- Containers may expose `/dev/kvm` without sufficient permissions.
- `-cpu host` under TCG is not evidence of RISC-V KVM availability.
