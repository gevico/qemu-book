# Compare accelerators

Status: runnable; the KVM branch is conditional on a RISC-V KVM host.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Compare the user-visible TCG and KVM contracts without treating them as two
settings of the same execution engine.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` names a built `qemu-system-riscv64`.
- KVM execution additionally requires an accessible `/dev/kvm` on RISC-V.

## Files

- `README.md`: the complete manual.
- `run.sh`: records the accelerator inventory and paused-vCPU observations.
- `results/`: generated command output.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect `results/accels.txt` and `results/tcg-monitor.txt`.
3. On a RISC-V KVM host, the script also runs the KVM branch. Otherwise it
   records the reason in `results/kvm-status.txt`.
4. Compare `accel/tcg/tcg-accel-ops.c` with `accel/kvm/kvm-accel-ops.c` in
   `QEMU_SRC`.

## Expected results

Both accelerators satisfy QEMU's accelerator interface, while only TCG owns
translation blocks and only KVM delegates vCPU execution to the kernel.

## Cleanup

Use the monitor `quit` command and remove the local `results/` directory.

## Troubleshooting

- An x86 or Arm `/dev/kvm` cannot execute a RISC-V KVM guest.
- If `rv64` is rejected, inspect `-cpu help` and record the selected CPU model.
