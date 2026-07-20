#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run identical RISC-V guest commands under single-thread TCG and MTTCG."""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import subprocess
import time


def main() -> None:
    qemu = pathlib.Path(os.environ.get("QEMU_SYSTEM_RISCV64", ""))
    image = pathlib.Path(os.environ.get("RISCV_GUEST_IMAGE", ""))
    runs = int(os.environ.get("RUNS", "5"))
    timeout = float(os.environ.get("RUN_TIMEOUT_SECONDS", "30"))
    marker = os.environ.get("EXPECTED_MARKER", "")
    result_regex = os.environ.get("RESULT_REGEX", "")
    expected_result = os.environ.get("EXPECTED_RESULT", "")
    results_dir = pathlib.Path(__file__).resolve().parent / "results"
    if not qemu.is_file() or not os.access(qemu, os.X_OK):
        raise SystemExit("QEMU_SYSTEM_RISCV64 must name an executable QEMU binary")
    if not image.is_file():
        raise SystemExit("RISCV_GUEST_IMAGE must name a guest image")
    if runs < 1:
        raise SystemExit("RUNS must be positive")
    if not marker:
        raise SystemExit("EXPECTED_MARKER must identify successful guest completion")
    if not result_regex:
        raise SystemExit("RESULT_REGEX must contain one capture group for the stable result")
    if not expected_result:
        raise SystemExit("EXPECTED_RESULT must name the known-correct captured result")
    try:
        compiled_result = re.compile(result_regex, re.MULTILINE)
    except re.error as error:
        raise SystemExit(f"invalid RESULT_REGEX: {error}") from error
    if compiled_result.groups != 1:
        raise SystemExit("RESULT_REGEX must contain exactly one capture group")
    results_dir.mkdir(exist_ok=True)

    report: dict[str, list[dict[str, object]]] = {}
    observed_results: set[str] = set()
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
            if marker.encode() not in serial:
                raise RuntimeError(f"{mode} run {run_number} lacks EXPECTED_MARKER")
            serial_text = serial.decode("utf-8", errors="replace").replace(
                "\r\n", "\n"
            )
            result_match = compiled_result.search(serial_text)
            if result_match is None:
                raise RuntimeError(f"{mode} run {run_number} lacks RESULT_REGEX match")
            stable_result = result_match.group(1)
            if stable_result != expected_result:
                raise RuntimeError(
                    f"{mode} run {run_number} result {stable_result!r} "
                    f"does not match EXPECTED_RESULT {expected_result!r}"
                )
            observed_results.add(stable_result)
            report[mode].append(
                {
                    "run": run_number,
                    "seconds": elapsed,
                    "result": stable_result,
                    "serial_sha256": hashlib.sha256(serial).hexdigest(),
                    "command": command,
                }
            )

    if observed_results != {expected_result}:
        raise RuntimeError("single-thread TCG and MTTCG results differ")

    summary = {
        "guest_image_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
        "expected_result": expected_result,
        "runs": report,
    }
    (results_dir / "summary.json").write_text(
        json.dumps(summary, indent=2) + "\n", encoding="utf-8"
    )
    print(f"wrote {results_dir / 'summary.json'}")


if __name__ == "__main__":
    main()
