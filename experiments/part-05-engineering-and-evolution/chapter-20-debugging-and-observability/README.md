# Chapter 20: Debugging and Observability

- [Debug a RISC-V guest with the QEMU gdbstub](debug-riscv-gdbstub/): stop a
  minimal bare-metal guest at a symbolic store and inspect registers and
  memory.
- [Debug a RISC-V Linux kernel](debug-riscv-linux-kernel/): follow the reset,
  OpenSBI, physical kernel-entry, virtual-symbol, and early-exception
  boundaries without confusing an unstripped `vmlinux` with the boot `Image`.
- [Inspect RISC-V RTOS tasks](inspect-riscv-rtos-tasks/): separate QEMU
  gdbstub hart visibility from scheduler-aware task, current-TCB, and task
  stack inspection.
- [Debug a RISC-V Linux process with gdbserver](debug-riscv-linux-process/):
  use process, thread, and shared-library semantics through a loopback SSH
  tunnel, and contrast that layer with the QEMU gdbstub and host GDB.
- [Use QEMU tracing](use-qemu-tracing/): select and correlate trace events
  without rebuilding ad hoc print statements.
- [Profile a TCG workload](profile-tcg-workload/): connect host samples to
  guest/TB context and source paths.
