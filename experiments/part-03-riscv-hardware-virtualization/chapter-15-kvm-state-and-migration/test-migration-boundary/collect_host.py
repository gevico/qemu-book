#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Collect a conservative RISC-V KVM migration preflight manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import subprocess


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    qemu = args.qemu.resolve()
    if not qemu.is_file() or not os.access(qemu, os.X_OK):
        raise SystemExit("QEMU binary is missing or not executable")

    version = subprocess.run(
        [str(qemu), "--version"], text=True, capture_output=True, check=True
    ).stdout.splitlines()[0]
    accelerators = subprocess.run(
        [str(qemu), "-accel", "help"], text=True, capture_output=True, check=True
    ).stdout.splitlines()
    manifest = {
        "label": args.label,
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "qemu_version": version,
        "qemu_sha256": sha256(qemu),
        "dev_kvm_readable": os.access("/dev/kvm", os.R_OK),
        "dev_kvm_writable": os.access("/dev/kvm", os.W_OK),
        "kvm_listed": any(line.strip() == "kvm" for line in accelerators),
        "machine": "virt",
        "cpu": "host",
        "accelerator": "kvm",
        "qemu_target": "v11.1.0",
        "review_anchor": "v11.1.0-rc0",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(args.output)


if __name__ == "__main__":
    main()
