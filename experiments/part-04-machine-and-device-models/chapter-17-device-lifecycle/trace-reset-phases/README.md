# Trace reset phases

Status: runnable when the build exposes suitable reset/device trace events.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Observe reset ordering for a RISC-V CPU and one device, then distinguish object
construction defaults from reset-restored state.

## Prerequisites

- `QEMU_SYSTEM_RISCV64` with tracing and monitor support.
- A small guest is optional.

## Files

- `README.md`: runtime and source procedure.
- `run.sh`: dynamic reset-event selection and monitor-driven system reset.
- `results/reset.trace`: generated only when selected events exist.

## Steps

1. Set `QEMU_SYSTEM_RISCV64` and run `./run.sh`.
2. Inspect `results/trace-help.txt` to confirm every selected reset event exists.
3. Compare the two register views around the scripted `system_reset` and the
   ordered records in `results/reset.trace`.
4. Follow Resettable phases and device callbacks in source to explain order.
   The supplied script uses `-machine virt`, whose UART is a 16550-compatible
   `serial-mm` device. To inspect `sifive_uart_reset_enter()` and
   `sifive_uart_reset_hold()`, run a separate `sifive_u` session; those
   callbacks are not part of the `virt` object graph.

## Expected results

Reset executes an ordered lifecycle across the object graph and restores
device-defined state without reconstructing every object.

## Cleanup

Quit QEMU and remove generated traces.

## Troubleshooting

- If no suitable trace event exists, use a debug build or source-only path and
  label the runtime branch skipped.
- Do not infer callback order from registration order alone.
- Always record the Machine type before setting a device callback breakpoint;
  a valid breakpoint in the source tree may be unreachable in that Machine.
