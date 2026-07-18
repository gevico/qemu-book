#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Summarize only events that the QEMU trace backend actually emitted."""

from __future__ import annotations

import argparse
import collections
import pathlib
import re

EXIT_REASON = re.compile(r"kvm_run_exit.*reason\s+(\d+)")


def summarize(lines: list[str]) -> dict[str, object]:
    reasons: collections.Counter[str] = collections.Counter()
    serial_writes = 0
    for line in lines:
        match = EXIT_REASON.search(line)
        if match:
            reasons[match.group(1)] += 1
        if "serial_write" in line:
            serial_writes += 1
    return {
        "kvm_run_exits": sum(reasons.values()),
        "exit_reasons": dict(sorted(reasons.items())),
        "serial_writes": serial_writes,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=pathlib.Path)
    args = parser.parse_args()
    result = summarize(args.trace.read_text(encoding="utf-8").splitlines())
    print(f"kvm_run_exits={result['kvm_run_exits']}")
    print(f"exit_reasons={result['exit_reasons']}")
    print(f"serial_writes={result['serial_writes']}")


if __name__ == "__main__":
    main()
