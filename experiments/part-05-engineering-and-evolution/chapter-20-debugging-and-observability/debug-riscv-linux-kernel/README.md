# Debug a RISC-V Linux kernel

Status: runnable with matching RISC-V Linux, firmware, GDB, and QEMU
artifacts; static validation remains runnable when live artifacts are absent.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` `virt`, normally under single-threaded TCG.

## Purpose

Locate a RISC-V Linux failure at the firmware-to-kernel handoff, physical
kernel entry, virtual kernel symbols, or an early exception. The experiment
tests the claim that a matching unstripped `vmlinux`, bootable `Image`, fixed
addresses, and explicit boot path are all needed before a symbolic breakpoint
is trustworthy.

It deliberately distinguishes two supported paths:

- `opensbi`: TCG starts an explicit OpenSBI image, which enters Linux in
  S-mode. The physical kernel-entry breakpoint observes the handoff and its
  `a0` hart ID and `a1` DTB pointer.
- `kvm-direct`: QEMU's RISC-V KVM path starts the kernel without emulating an
  M-mode OpenSBI stage. It requires a RISC-V KVM host. `-bios none` under TCG
  is not treated as an interchangeable Linux boot path.

## Prerequisites

- Bash, `rg`, `file`, a SHA-256 utility, and an ELF reader for static and
  artifact checks.
- `QEMU_SYSTEM_RISCV64` pointing to a RISC-V-enabled QEMU system emulator.
- `VMLINUX` pointing to the exact, unstripped RISC-V `vmlinux` used to build
  `RISCV_KERNEL_IMAGE`, which points to `arch/riscv/boot/Image`.
- For `RISCV_BOOT_PATH=opensbi`, an explicit `RISCV_FIRMWARE` binary; optional
  `RISCV_OPENSBI_ELF` adds firmware symbols. Requiring an explicit file makes
  the firmware hash recordable instead of hiding it behind `-bios default`.
- A RISC-V-capable GDB selected with `RISCV_GDB` or found as
  `riscv64-linux-gnu-gdb`/`gdb-multiarch`.
- Optional `RISCV_INITRD`, `RISCV_DTB`, `RISCV_KERNEL_CMDLINE`,
  `KERNEL_LOAD_ADDR`, and `QEMU_MEMORY` overrides.
- For `RISCV_BOOT_PATH=kvm-direct`, a RISC-V host with usable `/dev/kvm` and
  `QEMU_ACCELERATOR=kvm`.

Build the kernel with debug information and a symbol table. The controlled
command line includes `nokaslr`; retain the matching `.config`. Do not infer
that an arbitrary `Image` belongs to a nearby `vmlinux` merely because both
boot.

## Files

- `README.md`: this manual.
- `static-check.sh`: checks the committed scripts, safety properties, and GDB
  template without claiming a guest ran.
- `preflight.sh`: validates live inputs and prints QEMU/guest hashes, boot
  path, accelerator, stopped layer, and visibility limits.
- `launch.sh`: interactive opt-in launcher with bounded exact-PID cleanup and
  private Unix gdbstub/monitor sockets; it records a manifest and never opens
  a TCP debugger port.
- `kernel.gdb.in`: annotated command template for the physical entry,
  virtual-symbol transition, and RISC-V exception CSRs.
- `results/`: generated manifests, serial logs, and QEMU logs; untracked.

## Steps

1. Run `./static-check.sh`. `static_check=passed` validates only committed
   material; `live_execution=not_run` is intentional.
2. Export the exact artifacts, then run `./preflight.sh` and save its output.
   For the normal path:

   ```sh
   export QEMU_SYSTEM_RISCV64=/absolute/path/qemu-system-riscv64
   export VMLINUX=/absolute/path/linux/vmlinux
   export RISCV_KERNEL_IMAGE=/absolute/path/linux/arch/riscv/boot/Image
   export RISCV_FIRMWARE=/absolute/path/fw_jump.bin
   export RISCV_BOOT_PATH=opensbi
   set -o pipefail
   ./preflight.sh | tee kernel-preflight.txt
   ```

3. Confirm that `preflight=ready`, that every hash names the intended build,
   and that the kernel command line contains `nokaslr`. Set `RUN_LIVE=1` and
   start `./launch.sh` in terminal A. It halts QEMU at reset and prints the
   private gdbstub socket path.
4. In terminal B, copy `kernel.gdb.in`, replace its four placeholders, and
   start the recorded RISC-V GDB. First break on the physical kernel load
   address. Record `pc`, `a0`, `a1`, `mstatus`/`sstatus` when exposed, and the
   boot path.
5. After Linux establishes its virtual mapping, use the matching `vmlinux`
   symbols for `start_kernel` and `handle_exception`. At an exception stop,
   record `scause`, `sepc`, `stval`, `sstatus`, and `satp`; do not read a CSR
   value from a different hart.
6. Repeat only after changing one boundary. A comparison between `opensbi`
   and `kvm-direct` must retain separate manifests because the missing
   firmware stage is part of the result, not noise.

## Expected results

The preflight prints artifact SHA-256 values, QEMU version and binary hash,
accelerator, boot path, `stopped_layer=guest-cpu/kernel-boundary`, and an
explicit list of state that remains invisible. The launcher records the same
context before starting QEMU.

On the OpenSBI path, the physical-entry breakpoint is reached only after the
firmware handoff; `a0` identifies the boot hart and `a1` points to the DTB.
With `nokaslr` and a matching `vmlinux`, later virtual-symbol breakpoints are
repeatable. The KVM-direct path has no emulated OpenSBI call stack. Exact CSR
availability depends on the QEMU/GDB target description and must be recorded
as observed rather than filled in from expectation.

No script prints a live `PASS`. Missing QEMU, GDB, firmware, kernel artifacts,
or RISC-V KVM support produces `SKIP` with exit status `77` before launch.

## Cleanup

Press Ctrl-C in the launcher terminal. `launch.sh` sends a bounded signal only
to the exact QEMU PID it created and removes only its private socket directory.
It retains the run directory for review. Remove this project's `results/`
entries manually after preserving any needed manifest and transcript.

## Troubleshooting

- If a symbolic early breakpoint is missed, stop using the linked virtual
  `_start` address as though it were the physical load address. Break first at
  `KERNEL_LOAD_ADDR`, then switch to normal `vmlinux` symbols after paging is
  established.
- If `a0`/`a1` or the privilege mode is wrong, inspect the OpenSBI next-stage
  configuration, Image load address, and DTB address before debugging Linux C
  code.
- If `start_kernel` moves between boots, verify `nokaslr`, the exact Image and
  `vmlinux` hashes, and any relocation performed by an intermediate loader.
- If GDB lacks named RISC-V CSRs, use `maintenance print xml-tdesc` and record
  the absence; do not invent register numbers from another QEMU build.
- If KVM preflight skips, keep that branch skipped. A TCG run does not prove
  RISC-V KVM direct-boot or single-step behavior.
