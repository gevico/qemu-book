#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the bare-metal probe with a bounded timeout."""

from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qemu", required=True)
    parser.add_argument("--guest", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    arguments = parser.parse_args()

    command = [
        arguments.qemu,
        "-machine",
        "virt,qb-mmio-demo=on",
        "-cpu",
        "rv64",
        "-accel",
        "tcg",
        "-smp",
        "1",
        "-m",
        "128M",
        "-bios",
        "none",
        "-kernel",
        str(arguments.guest),
        "-display",
        "none",
        "-serial",
        "none",
        "-monitor",
        "none",
        "-no-reboot",
    ]
    try:
        completed = subprocess.run(command, check=False, timeout=arguments.timeout)
    except subprocess.TimeoutExpired:
        print("FAIL: QEMU timed out before the test finisher", file=sys.stderr)
        raise SystemExit(1)
    if completed.returncode:
        print(f"FAIL: QEMU returned {completed.returncode}", file=sys.stderr)
        raise SystemExit(1)
    print("PASS bare-metal probe: register masks, pending state, and PLIC input")


if __name__ == "__main__":
    main()
