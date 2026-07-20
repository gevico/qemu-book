# Debug a RISC-V guest with the QEMU gdbstub

Status: runnable with a RISC-V cross compiler, GDB, and system emulator;
source validation remains runnable when the cross tools are absent.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` `virt` under TCG.

## Purpose

Stop a symbolic bare-metal RISC-V store with the QEMU gdbstub, inspect guest
registers and memory, and distinguish this guest-side observation from a host
debugger attached to the QEMU process.

## Prerequisites

- Bash, `rg`, and standard POSIX process tools for `./static-check.sh`.
- `riscv64-unknown-elf-gcc` or `riscv64-linux-gnu-gcc` for the live guest.
- `riscv64-unknown-elf-gdb`, `riscv64-linux-gnu-gdb`, or `gdb-multiarch` 9.0+
  with Unix-socket remote support.
- `QEMU_SYSTEM_RISCV64` pointing to a RISC-V-enabled QEMU binary.
- Optional `RISCV_CC` and `RISCV_GDB` override the detected tools.

## Files

- `README.md`: this manual.
- `guest/start.S`: deterministic counter loop with a symbolic store.
- `guest/linker.ld`: RISC-V `virt` RAM link address and stack.
- `static-check.sh`: fixture, command, and shell validation without cross tools.
- `verify-transcript.sh`: asserts the deterministic counter transition from a
  live GDB transcript; static checks exercise both accepting and rejecting
  parser fixtures.
- `build.sh`: optional cross build with compiler metadata.
- `run.sh`: bounded QEMU/GDB run using a private Unix socket and exact PID.
- `build/` and `results/`: generated ELF, map, metadata, and transcripts.

## Steps

1. Run `./static-check.sh`. It validates the fixture and scripts without
   claiming that a guest executed.
2. Run `./build.sh`. When no supported compiler is installed, the script
   reports `SKIP` after the static check and leaves the live stage undone.
3. Export `QEMU_SYSTEM_RISCV64` and, when necessary, `RISCV_GDB`; run
   `./run.sh`.
4. Inspect the newest directory under `results/`. In `gdb.txt`, compare the
   counter before and after the `stepi` that executes `store_counter`.
5. Repeat with a breakpoint at `_start` or `loop`, changing only one debugger
   action. Record that this experiment uses TCG before comparing it with KVM.

## Expected results

The static stage prints `static_check=passed`. With all live dependencies,
GDB stops at `store_counter`, displays RISC-V `pc`, `s0`, and `t0`, emits
stable `COUNTER_BEFORE=0`, `S0_AT_STORE=1`, and `COUNTER_AFTER=1` markers, and
executes exactly one store. `verify-transcript.sh` rejects the run unless the
counter changes from zero to the value in `s0`. The transcript and QEMU
version are saved in a unique results directory.

## Cleanup

`run.sh` terminates only the exact QEMU PID it started and removes only its
temporary Unix-socket directory. Remove this project's generated `build/` and
`results/` directories manually when their evidence is no longer needed.

## Troubleshooting

- If GDB cannot connect to the Unix socket, require GDB 9.0+ or set
  `RISCV_GDB` to a RISC-V-capable build; do not expose an unauthenticated TCP
  gdbstub as a workaround.
- If the breakpoint is never reached, confirm the ELF entry/link address,
  `-bios none`, `-kernel`, and QEMU stderr before changing the guest.
- A static pass is not runtime evidence. A TCG pass also does not establish
  KVM breakpoint, CSR, or single-step support.
