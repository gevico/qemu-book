#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run identical RISC-V guest commands under single-thread TCG and MTTCG."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import time


def main() -> None:
    qemu = pathlib.Path(os.environ.get("QEMU_SYSTEM_RISCV64", ""))
    image = pathlib.Path(os.environ.get("RISCV_GUEST_IMAGE", ""))
    runs = int(os.environ.get("RUNS", "5"))
    timeout = float(os.environ.get("RUN_TIMEOUT_SECONDS", "30"))
    marker = os.environ.get("EXPECTED_MARKER", "")
    results_dir = pathlib.Path(__file__).resolve().parent / "results"
    if not qemu.is_file() or not os.access(qemu, os.X_OK):
        raise SystemExit("QEMU_SYSTEM_RISCV64 must name an executable QEMU binary")
    if not image.is_file():
        raise SystemExit("RISCV_GUEST_IMAGE must name a guest image")
    if runs < 1:
        raise SystemExit("RUNS must be positive")
    results_dir.mkdir(exist_ok=True)

    report: dict[str, list[dict[str, object]]] = {}
    for mode in ("single", "multi"):
        report[mode] = []
        for run_number in range(1, runs + 1):
            command = [
                str(qemu), "-machine", "virt", "-cpu", "rv64", "-smp", "4",
                "-accel", f"tcg,thread={mode}", "-bios", "none",
                "-kernel", str(image), "-display", "none", "-serial", "stdio",
                "-monitor", "none", "-no-reboot",
            ]
            started = time.monotonic()
            completed = subprocess.run(
                command, capture_output=True, timeout=timeout, check=False
            )
            elapsed = time.monotonic() - started
            serial = completed.stdout
            serial_path = results_dir / f"{mode}-{run_number}.serial"
            serial_path.write_bytes(serial)
            if completed.returncode != 0:
                raise RuntimeError(f"{mode} run {run_number} exited {completed.returncode}")
            if marker and marker.encode() not in serial:
                raise RuntimeError(f"{mode} run {run_number} lacks EXPECTED_MARKER")
            report[mode].append(
                {
                    "run": run_number,
                    "seconds": elapsed,
                    "serial_sha256": hashlib.sha256(serial).hexdigest(),
                }
            )

    (results_dir / "summary.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {results_dir / 'summary.json'}")


if __name__ == "__main__":
    main()
