# Trace main-loop events

Status: runnable when the QEMU build exposes the selected trace events.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Connect main-loop polling, timer deadlines, and event dispatch to observable
trace records.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` with tracing enabled.
- A disposable RISC-V image is optional; a paused empty machine is sufficient.

## Files

- `README.md`: the manual.
- `run.sh`: selects only available poll/run-state events and drives the monitor.
- `results/events.txt`: generated trace output.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Confirm the selected names in `results/trace-help.txt` and inspect
   `results/events.txt`.
3. The script issues monitor commands `cont`, `stop`, and `quit`; correlate
   their run-state transitions with poll records that exist in the build.
4. Locate the corresponding paths in `util/main-loop.c` and
   `system/runstate.c`.

## Expected results

The trace shows waits interrupted by timers, file-descriptor activity, or
run-state changes; event names may differ by configured backend.

## Cleanup

Quit the monitor and remove only the generated `results/` directory.

## Troubleshooting

- Never copy an event name blindly; use `-trace help` for the current build.
- If the backend needs extra options, consult `docs/devel/tracing.rst`.
