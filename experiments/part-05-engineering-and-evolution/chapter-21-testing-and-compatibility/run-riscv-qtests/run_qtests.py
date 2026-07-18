#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Discover and run focused configured RISC-V qtests by their real names."""

from __future__ import annotations

import os
import pathlib
import re
import subprocess


def configured_test_names(list_output: str) -> list[str]:
    """Return names that Meson accepts back on its command line.

    Current Meson releases display each test as ``suite - project:name``.
    Older releases may print only the configured name, so accept both forms.
    """

    names: list[str] = []
    for raw_line in list_output.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        _, separator, configured_name = line.partition(" - ")
        names.append(configured_name if separator else line)
    return names


def main() -> None:
    build = pathlib.Path(os.environ.get("QEMU_BUILD", ""))
    pattern = re.compile(
        os.environ.get("TEST_PATTERN", r"riscv.*(?:csr|iommu)|(?:csr|iommu).*riscv"),
        re.IGNORECASE,
    )
    max_tests = int(os.environ.get("MAX_TESTS", "10"))
    results = pathlib.Path(__file__).resolve().parent / "results"
    if not (build / "build.ninja").is_file():
        raise SystemExit("QEMU_BUILD must point to a configured QEMU build")
    if max_tests < 1:
        raise SystemExit("MAX_TESTS must be positive")
    results.mkdir(exist_ok=True)

    listed = subprocess.run(
        ["meson", "test", "-C", str(build), "--list"],
        text=True,
        capture_output=True,
        check=True,
    )
    (results / "all-tests.txt").write_text(listed.stdout, encoding="utf-8")
    names = configured_test_names(listed.stdout)
    selected = [name for name in names if pattern.search(name)][:max_tests]
    if not selected:
        fallback = [name for name in names if "riscv" in name.lower()][:max_tests]
        selected = fallback
    (results / "selected-tests.txt").write_text(
        "\n".join(selected) + ("\n" if selected else ""), encoding="utf-8"
    )
    if not selected:
        print("SKIP: configured build lists no RISC-V test")
        return

    completed = subprocess.run(
        ["meson", "test", "-C", str(build), "--print-errorlogs", "--verbose", *selected],
        text=True,
        capture_output=True,
        check=False,
    )
    (results / "testlog.txt").write_text(
        completed.stdout + completed.stderr, encoding="utf-8"
    )
    if completed.returncode != 0:
        raise SystemExit(completed.returncode)
    print(f"passed_tests={len(selected)}")


if __name__ == "__main__":
    main()
