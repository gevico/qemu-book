# Trigger TB invalidation

Status: runnable bare-metal RISC-V fixture for a TCG-enabled system emulator.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Change executable guest memory in a controlled way and verify that stale host
code is not executed afterward.

## Prerequisites

- A RISC-V cross-toolchain, TCG-enabled QEMU build, and GNU `timeout`.
- `rg`; generated build and trace files stay under ignored directories.

## Files

- `README.md`: design and execution procedure.
- `guest/start.S`: reset entry and stack setup.
- `guest/self-modifying.c`: two-instruction generated function and assertions.
- `guest/linker.ld`: RISC-V `virt` RAM layout.
- `run.sh`: guest build, TCG execution, and result check.

## Steps

1. Run `./run.sh`; override `RISCV_CC` or `QEMU_SYSTEM_RISCV64` when the tools
   are not on `PATH` under their default names. The guest run is capped at 20
   seconds by default; use `RUN_TIMEOUT_SECONDS` for a slower host.
2. Confirm that `results/serial.log` contains `12`. The generated function
   first returns one, is rewritten, executes `fence.i`, and then returns two.
3. Compare both translations in `results/tcg.log`, then locate page protection
   and invalidation paths in `accel/tcg/tb-maint.c` at the fixed source tag.
4. As a separate, deliberately non-conforming comparison, remove `fence.i` and
   record the result. Never use that run as a correctness expectation.

## Expected results

The script reports `Observed conforming self-modification: 1 -> 2`. The trace
shows execution before and after the write. Treat the log as observation and
the source walk as the evidence for the exact invalidation path; `-d exec` is
not a stable, structured invalidation API.

## Cleanup

Delete only this experiment's `build/` and `results/` directories.

## Troubleshooting

- If both calls use one constant, inspect compiler inlining and generated ELF.
- Keep writable and executable memory policy explicit on the guest platform.
- Some distributions name the compiler `riscv64-unknown-elf-gcc`; pass that
  path through `RISCV_CC`.
