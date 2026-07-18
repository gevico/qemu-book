# Compare virtio and vhost

Status: runnable on Linux when the selected vhost backend is available.

Baseline: QEMU `v11.1.0`; source-review anchor `v11.1.0-rc0`; RISC-V
`riscv64` guest.

## Purpose

Compare an emulated virtio data path with a vhost-backed path and identify
which setup, memory, notification, and migration work remains in QEMU.

## Prerequisites

- A RISC-V Linux guest and a device/backend supporting both controlled modes.
- Required vhost kernel device permissions on the host.

## Files

- `README.md`: configuration and comparison manual.
- `inspect_and_probe.py`: non-mutating host/backend preflight manifest.
- `inspect-source.sh`: virtio control, vhost delegation, and migration anchors.
- `results/control-data-boundary.txt`: generated fixed-source evidence.
- `results/preflight.json`: generated host/backend capability manifest.
- `results/MODE/`: local source reports, traces, and guest checksums.

## Steps

1. Set `QEMU_SRC` and run `./inspect-source.sh`. Run
   `./inspect_and_probe.py --qemu /path/to/qemu-system-riscv64` and inspect the
   backend permissions without changing them.
2. Run a fixed workload with the QEMU-emulated virtio backend.
3. Repeat with the corresponding vhost backend and identical guest-visible
   configuration only when the preflight and host policy permit it.
4. Compare correctness, QEMU thread activity, exits/notifications, and CPU use.
5. Map retained control-plane work and delegated data-plane work using the
   generated source evidence.

## Expected results

Both modes preserve the virtio guest contract; vhost moves selected data-path
operations out of QEMU without eliminating QEMU's configuration and lifecycle
responsibilities.

## Cleanup

Shut down guests, close backend file descriptors, and remove only lab overlays
and result files.

## Troubleshooting

- A missing vhost device is a skip, not a reason to change host permissions
  broadly.
- Compare identical queue counts and feature negotiation.
