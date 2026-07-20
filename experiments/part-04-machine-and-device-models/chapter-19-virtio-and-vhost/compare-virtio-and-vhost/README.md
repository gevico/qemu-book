# Compare virtio and vhost

Status: fixed-source inspection and non-mutating backend preflight; the two-mode
runtime comparison is a guided procedure requiring a user-supplied RISC-V
guest, backend, and controlled workload.

Target release: QEMU `v11.1.0`; source-review baseline `v11.1.0-rc0`; RISC-V
`riscv64` guest.

## Purpose

Prepare and review a controlled comparison between an emulated virtio data path
and a vhost-backed path, then identify which setup, memory, notification, and
migration work remains in QEMU. The committed files do not claim to launch the
two workload runs themselves.

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
2. Write down the exact two QEMU commands before running them. They must differ
   only in the chosen backend switch and host-only plumbing; save the expanded
   commands under `results/emulated/` and `results/vhost/`.
3. Run a fixed, self-checking RISC-V guest workload first with the QEMU-emulated
   backend, then with the corresponding vhost backend only when preflight and
   host policy permit it. Require the same guest checksum or marker in both.
4. Compare correctness, QEMU thread activity, exits/notifications, and CPU use.
5. Map retained control-plane work and delegated data-plane work using the
   generated source evidence.

## Expected results

The source and preflight stages produce an evidence inventory, not a runtime
pass. A completed user-supplied comparison must show that both modes preserve
the same guest checksum or marker; only then may it conclude that vhost moved
selected data-path operations without eliminating QEMU's configuration and
lifecycle responsibilities.

## Cleanup

Shut down guests, close backend file descriptors, and remove only lab overlays
and result files.

## Troubleshooting

- A missing vhost device is a skip, not a reason to change host permissions
  broadly.
- Compare identical queue counts and feature negotiation.
