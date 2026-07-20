# Debug a RISC-V Linux process with gdbserver

Status: runnable with an existing RISC-V Linux guest, a matching user ELF,
guest `gdbserver`, and a loopback SSH tunnel; static validation and artifact
preflight remain runnable without connecting to the guest.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` Linux guest under TCG or RISC-V KVM.

## Purpose

Debug one RISC-V Linux guest process with process, thread, and shared-library
semantics, and identify the boundary between three different debuggers:

| Debugger | Stops | Understands directly | Does not reveal directly |
| --- | --- | --- | --- |
| guest `gdbserver` + RISC-V GDB | one guest process or attached PID | guest threads, mappings, user symbols, loader events, signals | firmware, other processes, kernel/device internals |
| QEMU gdbstub + RISC-V GDB | QEMU vCPU/hart execution | architectural registers and guest memory at the CPU boundary | Linux process/thread identity without OS helpers |
| host GDB attached to QEMU | the host QEMU process | QEMU C/Rust frames, host threads, device/TCG implementation | guest user symbols as native host frames |

The experiment is designed to falsify the common assumption that the QEMU
gdbstub is the natural first tool for a normal user-space crash. If the
failure remains inside one Linux process, guest `gdbserver` preserves the
semantics that the CPU-level stub would force the investigator to reconstruct.

## Prerequisites

- Bash, `rg`, a SHA-256 utility, and a RISC-V-capable ELF reader.
- A running RISC-V Linux guest reached through SSH. Its QEMU SSH host-forward
  listener must be bound to loopback, for example
  `hostfwd=tcp:127.0.0.1:10022-:22`.
- Guest `gdbserver` and the exact guest program at `GUEST_PROGRAM_PATH`.
- `RISCV_USER_ELF` pointing to the matching unstripped host-side ELF, and
  `RISCV_GUEST_IMAGE` pointing to the immutable base image or powered-off
  disposable image whose hash identifies the guest. Hash a writable disk only
  while it is quiescent; use an overlay for live writes.
- `QEMU_SYSTEM_RISCV64` pointing to the emulator used for the guest and
  `QEMU_ACCELERATOR=tcg` or `kvm` matching that run.
- A RISC-V-capable GDB selected through `RISCV_GDB` or discovered as
  `riscv64-linux-gnu-gdb`/`gdb-multiarch`.
- Optional `RISCV_SYSROOT` copied from the exact guest for shared-library
  symbols, plus `RISCV_GUEST_KERNEL` and `RISCV_GUEST_DTB` for additional
  artifact hashes.

The preferred transport is an SSH tunnel. Guest `gdbserver` binds only guest
loopback; SSH exposes only a host-loopback endpoint. This lab does not open a
QEMU gdbstub and never binds a debugger to all host interfaces.

## Files

- `README.md`: this manual.
- `static-check.sh`: validates scripts, templates, layer labels, and loopback
  policy without making a network connection.
- `preflight.sh`: validates the RISC-V user ELF and records QEMU/guest hashes,
  accelerator, stopped layer, endpoint, and invisible state.
- `connect.sh`: opt-in interactive RISC-V GDB connector that rejects non-
  loopback endpoints and records a local session manifest/log.
- `guest-gdbserver.sh.in`: guest command templates for launching or attaching
  through guest loopback.
- `process.gdb.in`: annotated process/thread/shared-library command template.
- `results/`: generated host manifests and GDB logs; untracked.

## Steps

1. Run `./static-check.sh`. It must report that live execution did not run.
2. With the guest disk quiescent, export the exact artifacts and run the
   preflight:

   ```sh
   export QEMU_SYSTEM_RISCV64=/absolute/path/qemu-system-riscv64
   export RISCV_GUEST_IMAGE=/absolute/path/riscv-linux-base.qcow2
   export RISCV_USER_ELF=/absolute/path/unstripped/riscv64/app
   export GUEST_PROGRAM_PATH=/opt/lab/app
   export QEMU_ACCELERATOR=tcg
   set -o pipefail
   ./preflight.sh | tee process-preflight.txt
   ```

3. In the guest, compare `sha256sum "$GUEST_PROGRAM_PATH"` with the
   `user_elf_sha256` record. Then adapt `guest-gdbserver.sh.in` to start or
   attach on guest loopback `127.0.0.1:2345`. Record guest `uname -a`,
   `gdbserver --version`, PID, program hash, and library build IDs.
4. From the host, create a loopback-only SSH tunnel. If SSH itself is forwarded
   on host port 10022, one example is:

   ```sh
   ssh -N -p 10022 \
       -L 127.0.0.1:1234:127.0.0.1:2345 user@127.0.0.1
   ```

5. In another host terminal, set `GDBSERVER_ENDPOINT=127.0.0.1:1234`, review
   `./preflight.sh`, then run `RUN_LIVE=1 ./connect.sh`. Use
   `process.gdb.in` to inspect `info threads`, `thread apply all bt`,
   `info sharedlibrary`, mappings, signals, and a user breakpoint.
6. Escalate only when evidence crosses a layer. A system call, page fault, or
   driver boundary may justify a separate QEMU-gdbstub run; a suspected QEMU
   implementation bug may justify host GDB. Give each transcript its own
   `stopped_layer` instead of merging their thread IDs or stacks.

## Expected results

The preflight records hashes for the QEMU executable, RISC-V user ELF, guest
image, and optional guest kernel/DTB; it also records the accelerator,
loopback endpoint, `stopped_layer=guest-linux-process`, visible process
semantics, and invisible lower/upper layers.

After `gdbserver` accepts the tunnelled connection, RISC-V GDB identifies the
inferior process and its Linux threads. With a matching sysroot, shared-library
names, symbols, and loader breakpoints correspond to the guest. QEMU vCPU
threads do not appear as these process threads, and host QEMU pthreads do not
appear in the guest backtrace.

Missing image, user ELF, debugger, QEMU binary, or hash/ELF tools produces an
explicit `SKIP` with exit status `77`. `connect.sh` requires `RUN_LIVE=1`;
neither static validation nor preflight claims a live connection succeeded.

## Cleanup

Quit or detach from GDB according to whether the inferior should terminate or
continue, stop only the guest `gdbserver` instance you started, and terminate
the exact SSH tunnel process from its terminal. `connect.sh` writes only below
this project's `results/`. It does not stop the user's QEMU guest or modify the
guest disk.

## Troubleshooting

- If GDB reports an architecture mismatch, re-check `readelf -h` and the
  program hash inside the RISC-V guest; do not use a similarly named host ELF.
- If threads have no names or backtraces stop in libc, copy the matching guest
  sysroot and debug files, then record library build IDs. A nearby distro
  sysroot can produce misleading line information.
- If the tunnel connects but `gdbserver` does not, verify both loopback ports,
  the guest PID, and whether `--once` exited after an earlier connection.
- If a bug vanishes when stopped, record the perturbation. Process GDB changes
  scheduling too; use application tracing for timing-sensitive races.
- If the investigation needs `scause`, kernel page tables, firmware, or QEMU
  device state, this experiment has reached its visibility boundary. Start a
  separately recorded kernel/gdbstub or host-debug session.
