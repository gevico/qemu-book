# Trace IRQ and I/O exits

Status: runnable on a RISC-V KVM host, with a static Linux initramfs probe and a
host-independent trace-parser test.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` with AIA where supported.

## Purpose

Determine which device accesses and interrupt operations stay in-kernel and
which return to QEMU userspace for one controlled workload.

## Prerequisites

- RISC-V KVM host, known interrupt-controller mode, and QEMU tracing.
- A compatible RISC-V Linux `Image`, static cross compiler, `cpio`, and GNU
  `timeout`.

## Files

- `README.md`: design and tracing procedure.
- `guest/io-irq-probe.c`: console writes around a 25 ms POSIX timer signal.
- `build-initramfs.sh`: static build and minimal `rdinit` archive.
- `run-kvm.sh`: full/split irqchip KVM launch with selected trace events.
- `analyze_trace.py` and `test_analyze_trace.py`: conservative event summary.

## Steps

1. Run `./build-initramfs.sh`, then set `GUEST_KERNEL` to a compatible kernel.
2. Run `KVM_IRQCHIP_MODE=full ./run-kvm.sh`. Record host kernel, QEMU commit,
   AIA capability, and the printed exit-reason histogram.
3. If the host supports split irqchip mode, run
   `KVM_IRQCHIP_MODE=split ./run-kvm.sh`. Compare `full.trace` and `split.trace`
   without assuming that equal guest events imply equal userspace exits.
4. Correlate `probe:uart-before`, `probe:timer-fired`, `serial_write`, and
   `kvm_run_exit`. Then review `docs/specs/riscv-aia.rst`,
   `hw/intc/riscv_aplic.c`, `hw/intc/riscv_imsic.c`, and the KVM call path.
5. On a non-RISC-V development host, run
   `python3 -m unittest -v test_analyze_trace.py`; this validates the parser,
   not KVM behavior.

## Expected results

Both marker lines appear in serial output. The trace reports the exact
`kvm_run_exit` reasons and userspace `serial_write` callbacks observed in that
run. Full versus split results are evidence only when host capability, machine
options, kernel, and QEMU build are recorded together.

## Cleanup

The probe requests poweroff. Remove only this experiment's `build/` and
`results/` directories after preserving the comparison table.

## Troubleshooting

- Record whether AIA acceleration is enabled before comparing hosts.
- Absence of a userspace exit does not mean the guest event did not occur.
- A timeout often means the kernel and initramfs ABI do not match, poweroff is
  unavailable, or console is not `ttyS0`; inspect the mode-specific stderr.
