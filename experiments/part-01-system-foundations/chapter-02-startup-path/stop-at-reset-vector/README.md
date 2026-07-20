# Stop at reset vector

Status: runnable with GDB and a RISC-V payload.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Inspect architectural state after machine reset but before any guest
instruction executes.

## Prerequisites

- `QEMU_SYSTEM_RISCV64`, `RISCV_GUEST_IMAGE`, and a RISC-V-capable GDB.
- `rg` for transcript assertions.
- Loopback TCP port 1234 is unused; the runner never binds a wildcard address.

## Files

- `README.md`: the manual.
- `reset-vector.gdb`: batch register, disassembly, and single-step commands.
- `run.sh`: launches and cleans up only its recorded QEMU process.
- `results/registers.txt`: optional captured register dump.

## Steps

1. Set `QEMU_SYSTEM_RISCV64`, `RISCV_GUEST_IMAGE`, and optionally `RISCV_GDB`.
2. Run `./run.sh`; it binds `127.0.0.1:1234` and writes the batch session to
   `results/registers.txt`.
3. Compare `initial-pc` with `after-step-pc` and the surrounding disassembly.
4. The exit trap detaches GDB and terminates only the recorded child process.

## Expected results

The initial PC and register state match the `virt` reset/boot path rather than
the payload's C entry point.

## Cleanup

Detach GDB, stop the recorded QEMU PID, and remove `results/`.

## Troubleshooting

- If GDB cannot select RISC-V, use a matching cross-GDB or `gdb-multiarch`.
- Change the GDB port if 1234 is already in use.
