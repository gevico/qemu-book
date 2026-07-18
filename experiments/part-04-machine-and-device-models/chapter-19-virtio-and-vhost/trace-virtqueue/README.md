# Trace a virtqueue

Status: runnable with a RISC-V Linux guest and QEMU tracing.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Follow one virtio request from guest descriptor publication through QEMU
notification, device processing, used-ring update, and guest completion.

## Prerequisites

- `QEMU_SYSTEM_RISCV64`, a disposable RISC-V Linux image, and one virtio
  device such as `virtio-blk-pci`.
- QEMU tracing enabled.

## Files

- `README.md`: trace procedure.
- `run.sh`: read-only snapshot-backed virtio-blk launch and dynamic event
  selection.
- `results/virtqueue.trace`: generated event log.

## Steps

1. Set `QEMU_SYSTEM_RISCV64`, `GUEST_KERNEL`, `GUEST_DISK`, and the correct
   `GUEST_DISK_FORMAT`, then run `./run.sh`.
2. Confirm every requested name in `results/trace-help.txt`; the disk is opened
   with `snapshot=on` so the base image is not modified.
3. Use a guest image whose boot performs one known small request, and record
   that result from `results/serial.log`.
4. Correlate descriptor, notify, processing, used update, and interrupt events
   with `hw/virtio/` source.

## Expected results

The request has distinct ownership transitions; notification and interrupt
events need not occur once per descriptor because batching is allowed.

## Cleanup

Shut down the guest and remove its overlay and generated trace.

## Troubleshooting

- Use a single request before testing queues or batching.
- Preserve raw indices before converting them into a diagram.
