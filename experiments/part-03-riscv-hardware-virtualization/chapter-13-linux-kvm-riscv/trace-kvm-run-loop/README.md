# Trace the KVM run loop

Status: runnable only on a Linux RISC-V KVM host.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Observe a QEMU vCPU thread entering `KVM_RUN`, returning on exits, and handing
selected work back to userspace.

## Prerequisites

- A successful `probe-riscv-kvm` result and a small RISC-V guest.
- QEMU tracing, `strace`, or kernel KVM tracepoints available on the host.

## Files

- `README.md`: tracing procedure.
- `run.sh`: bounded QEMU `kvm_vcpu_ioctl` and `kvm_run_exit` trace collection.
- `results/`: local raw traces and command records.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and `RISCV_GUEST_IMAGE`, then run `./run.sh` on the
   host that passed the preceding probe.
2. Inspect `results/kvm.trace`, serial output, and the bounded process status.
3. Correlate `kvm_vcpu_ioctl` and `kvm_run_exit`; add kernel tracepoints only
   when host policy already permits them.
4. Map QEMU-side handling to `accel/kvm/kvm-all.c` and RISC-V KVM code.

## Expected results

The vCPU thread spends guest execution intervals inside `KVM_RUN`; exits return
control for userspace handling, signals, or host-kernel events.

## Cleanup

Stop tracing, shut down the guest, and remove only generated trace files.

## Troubleshooting

- Tracer permissions may require host administration; skip rather than weaken
  system-wide security settings.
- Do not assume every guest interrupt causes a userspace exit.
