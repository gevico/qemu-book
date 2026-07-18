#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Summarize QEMU RISC-V IOMMU trace events without inventing semantics."""

from __future__ import annotations

import argparse
import collections
import pathlib
import re

DMA = re.compile(
    r"riscv_iommu_dma.*translate\s+([0-9a-fA-F:.]+)\s+#(\d+)\s+"
    r"(read|write)\s+0x([0-9a-fA-F]+)\s+->\s+0x([0-9a-fA-F]+)"
)
FAULT = re.compile(
    r"riscv_iommu_flt.*fault\s+([0-9a-fA-F:.]+)\s+reason:\s+"
    r"0x([0-9a-fA-F]+)\s+iova:\s+0x([0-9a-fA-F]+)"
)


def summarize(lines: list[str]) -> dict[str, object]:
    directions: collections.Counter[str] = collections.Counter()
    devices: collections.Counter[str] = collections.Counter()
    faults: collections.Counter[str] = collections.Counter()

    for line in lines:
        dma = DMA.search(line)
        if dma:
            devices[dma.group(1)] += 1
            directions[dma.group(3)] += 1
        fault = FAULT.search(line)
        if fault:
            devices[fault.group(1)] += 1
            faults[fault.group(2)] += 1

    return {
        "translations": sum(directions.values()),
        "directions": dict(sorted(directions.items())),
        "faults": sum(faults.values()),
        "fault_reasons": dict(sorted(faults.items())),
        "devices": dict(sorted(devices.items())),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=pathlib.Path)
    parser.add_argument("--require-translation", action="store_true")
    parser.add_argument("--require-fault", action="store_true")
    args = parser.parse_args()

    result = summarize(args.trace.read_text(encoding="utf-8").splitlines())
    for key, value in result.items():
        print(f"{key}={value}")

    if args.require_translation and result["translations"] == 0:
        raise SystemExit("no RISC-V IOMMU translation event was observed")
    if args.require_fault and result["faults"] == 0:
        raise SystemExit("no RISC-V IOMMU fault event was observed")


if __name__ == "__main__":
    main()
