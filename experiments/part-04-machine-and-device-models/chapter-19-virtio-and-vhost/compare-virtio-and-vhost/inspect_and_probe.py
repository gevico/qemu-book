#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Record vhost preconditions without changing host permissions or devices."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import subprocess


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("results/preflight.json"))
    args = parser.parse_args()
    qemu = args.qemu.resolve()
    if not qemu.is_file() or not os.access(qemu, os.X_OK):
        raise SystemExit("QEMU binary is missing or not executable")

    devices = subprocess.run(
        [str(qemu), "-device", "help"], text=True, capture_output=True, check=True
    ).stdout
    report = {
        "host_system": platform.system(),
        "host_architecture": platform.machine(),
        "vhost_net_exists": pathlib.Path("/dev/vhost-net").exists(),
        "vhost_net_readable": os.access("/dev/vhost-net", os.R_OK),
        "vhost_net_writable": os.access("/dev/vhost-net", os.W_OK),
        "virtio_net_pci_listed": "virtio-net-pci" in devices,
        "qemu_version": subprocess.run(
            [str(qemu), "--version"], text=True, capture_output=True, check=True
        ).stdout.splitlines()[0],
        "guest_architecture": "riscv64",
        "qemu_target": "v11.1.0",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
