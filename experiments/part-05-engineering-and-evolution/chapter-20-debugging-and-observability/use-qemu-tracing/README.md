# Use QEMU tracing

Status: runnable when at least one QEMU trace backend is enabled.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Build a bounded trace that answers one lifecycle question and correlate its
events without modifying QEMU source with temporary print statements.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` and a small RISC-V guest or paused `virt` machine.
- One trace backend supported by the local build.

## Files

- `README.md`: event-selection and analysis procedure.
- `run.sh`: build-listed event selection and scripted reset stimulus.
- `results/events.txt` and `results/lifecycle.trace`: generated inventory and
  raw trace.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`; its narrow question is which
   lifecycle events surround one monitor `system_reset`.
2. Confirm every selected name in `results/events.txt`.
3. Preserve `results/lifecycle.trace` and the monitor transcript, then adapt
   the event list only after stating a different question.
4. Locate each event definition and call site; draw only causal links supported
   by timestamps and source.

## Expected results

A compact trace shows the selected lifecycle or data-path transitions and can
be explained from event call sites without unrelated high-volume noise.

## Cleanup

Stop QEMU and remove generated traces when no longer required.

## Troubleshooting

- Enable events after confirming their names in this binary.
- Timestamps establish order, not necessarily causality across threads.
