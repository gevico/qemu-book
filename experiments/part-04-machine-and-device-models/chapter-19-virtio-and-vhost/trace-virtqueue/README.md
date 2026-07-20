# Trace a virtqueue

Status: runnable with a RISC-V Linux guest and QEMU tracing.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64`.

## Purpose

Follow one virtio request from guest descriptor publication through QEMU
notification, device processing, used-ring update, and guest completion.

## Prerequisites

- `QEMU_SYSTEM_RISCV64`, a disposable RISC-V Linux image, and one virtio
  device such as `virtio-blk-pci`.
- QEMU tracing enabled.
- `rg` and GNU `timeout` on the host.
- A guest boot action that performs one controlled request and prints a unique
  marker; export that exact text as `GUEST_REQUEST_MARKER`.

## Files

- `README.md`: trace procedure.
- `run.sh`: read-only snapshot-backed virtio-blk launch and dynamic event
  selection.
- `results/selected-events.txt`: event names actually enabled by this build.
- `results/virtqueue.trace`: generated event log.

## Steps

1. Set `QEMU_SYSTEM_RISCV64`, `GUEST_KERNEL`, `GUEST_DISK`, the correct
   `GUEST_DISK_FORMAT`, and `GUEST_REQUEST_MARKER`, then run `./run.sh`.
2. Confirm every name in `results/selected-events.txt` also appears in
   `results/trace-help.txt`; the disk is opened with `snapshot=on` so the base
   image is not modified.
3. The runner requires the marker in `results/serial.log`, at least one
   acquisition event (`virtqueue_pop` or `virtio_blk_handle_*`), and at least
   one completion-side event (`virtio_blk_req_complete`, `virtqueue_fill`, or
   `virtqueue_flush`). Preserve all three before correlating the request.
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
