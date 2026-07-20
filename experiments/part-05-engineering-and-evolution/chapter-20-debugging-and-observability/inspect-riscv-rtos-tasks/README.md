# Inspect RISC-V RTOS tasks

Status: runnable with a matching, symbol-rich RISC-V RTOS ELF; static
validation remains runnable when the RTOS image or cross debugger is absent.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` `virt` under TCG.

## Purpose

Separate what the QEMU gdbstub knows about RISC-V harts from what an RTOS
debug helper derives from scheduler data structures. The experiment tests the
claim that `info threads` alone proves task awareness: without an RTOS-aware
extension, its entries are QEMU CPUs/harts, while task names, states, saved
stack pointers, and current-task identity must come from the exact RTOS ELF
and scheduler layout.

The command template uses FreeRTOS-style `vTaskSwitchContext` and
`pxCurrentTCB` as concrete defaults, but all execution remains on a RISC-V
guest. Zephyr or another RTOS can be used only after replacing both symbols
and the structure expressions with that build's actual debug types.

## Prerequisites

- Bash, `rg`, a SHA-256 utility, and a RISC-V-capable ELF reader.
- `QEMU_SYSTEM_RISCV64` pointing to a RISC-V-enabled QEMU system emulator.
- `RTOS_ELF` pointing to the exact, unstripped RISC-V ELF loaded into `virt`.
  It must contain scheduler and current-task symbols for the selected build.
- A RISC-V-capable GDB selected with `RISCV_GDB` or discovered as
  `riscv64-unknown-elf-gdb`, `riscv64-linux-gnu-gdb`, or `gdb-multiarch`.
- `RTOS_SCHEDULER_SYMBOL` and `RTOS_CURRENT_TASK_SYMBOL` when the image does
  not use the FreeRTOS defaults. Keep the RTOS commit/configuration with the
  run because private scheduler fields are not an ABI.
- `RTOS_BOOT_PATH=machine` for an M-mode/bare-metal ELF loaded with
  `-bios none`, or `RTOS_BOOT_PATH=opensbi` plus an explicit
  `RISCV_FIRMWARE` for an S-mode RTOS payload.
- Optional `RTOS_HARTS` (default `1`), `QEMU_MEMORY`, and `RISCV_DTB`
  overrides.
- Set `RTOS_HARTS` above one only for a verified RISC-V SMP RTOS build. Record
  its per-hart stacks, secondary-hart park/bring-up contract, and whether the
  scheduler's current-task pointer is scalar, per-hart, or an array.

## Files

- `README.md`: this manual.
- `static-check.sh`: validates the scripts, GDB template, RISC-V scope, and
  private-socket policy without executing a guest.
- `preflight.sh`: checks the RTOS ELF and configured scheduler symbols, then
  records QEMU/guest hashes, accelerator, hart count, stop layer, and blind
  spots.
- `launch.sh`: opt-in launcher that starts halted QEMU with private Unix
  gdbstub and monitor sockets and cleans up only its exact PID.
- `rtos-tasks.gdb.in`: CPU/hart inspection plus annotated FreeRTOS and Zephyr
  scheduler-structure examples.
- `results/`: generated manifests, serial output, and QEMU logs; untracked.

## Steps

1. Run `./static-check.sh`. A static pass explicitly says that live execution
   did not run.
2. Export the exact RISC-V RTOS artifacts and symbols. For a FreeRTOS-style
   M-mode image:

   ```sh
   export QEMU_SYSTEM_RISCV64=/absolute/path/qemu-system-riscv64
   export RTOS_ELF=/absolute/path/rtos.elf
   export RTOS_BOOT_PATH=machine
   export RTOS_SCHEDULER_SYMBOL=vTaskSwitchContext
   export RTOS_CURRENT_TASK_SYMBOL=pxCurrentTCB
   set -o pipefail
   ./preflight.sh | tee rtos-preflight.txt
   ```

3. Review the hashes and `preflight=ready`, set `RUN_LIVE=1`, and run
   `./launch.sh` in terminal A. It starts the guest halted and prints a private
   Unix socket.
4. In terminal B, copy `rtos-tasks.gdb.in`, replace its placeholders, and
   connect with the recorded RISC-V GDB. Run `info threads` and
   `thread apply all ...` before touching scheduler data. Record the GDB thread
   ID, hart registers, and selected hart separately.
5. Break at the configured scheduler function. At one task switch, inspect
   the current-task pointer and its saved stack pointer, then inspect a bounded
   portion of that task's stack. For an SMP RTOS, identify whether the current
   pointer is scalar, per-hart, or an array before dereferencing it.
6. If an RTOS-aware GDB extension is available, enable it only in a second
   run. Record its name, version, RTOS commit/configuration, and how its task
   list differs from the original QEMU hart list. Do not call helper-generated
   task rows native QEMU gdbstub threads.

## Expected results

The preflight records SHA-256 values for QEMU, the RTOS ELF, firmware/DTB when
present, `accelerator=tcg`, hart count, symbol names,
`stopped_layer=guest-cpu/rtos-scheduler`, and the state QEMU cannot infer.

Before task awareness is added, `info threads` follows QEMU's CPU/hart view.
At the scheduler breakpoint, the exact RTOS debug types allow the current TCB,
saved stack pointer, task name, and a bounded task stack to be inspected. A
second hart can have a different running task even when all tasks share one
address space. A helper may synthesize a task-oriented view, but its output is
derived from guest memory and must agree with the recorded scheduler layout.

Missing ELF, debugger, symbol table, configured scheduler symbols, firmware,
or hash utility produces `SKIP` with exit status `77`. The scripts never
convert static fixture checks into a live `PASS`.

## Cleanup

Press Ctrl-C in the launcher terminal. The launcher stops only its recorded
QEMU PID and removes only its private socket directory. Generated manifests
and logs remain below this project's `results/`; remove them manually after
preserving evidence.

## Troubleshooting

- If `info threads` shows two entries for `RTOS_HARTS=2`, that proves two
  debugger-visible harts, not two RTOS tasks.
- If `pxCurrentTCB` or a structure field is optimized out, rebuild the exact
  RISC-V RTOS image with usable debug information. Guessing a TCB offset from
  another release can make a plausible but false task list.
- If a saved stack pointer falls outside the task's allocated stack, verify
  the selected hart, task-switch point, stack growth direction, context-frame
  layout, and whether the task is running or saved.
- Single-stepping through the scheduler changes interrupt and tick timing.
  Use a breakpoint or trace for a race and record that the stop perturbs time.
- If an S-mode image never reaches its entry, verify the explicit OpenSBI
  firmware hash and handoff contract; do not silently retry it as M-mode.
