#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Compare preflight facts without certifying migration compatibility."""

from __future__ import annotations

import argparse
import json
import pathlib

CRITICAL = (
    "architecture",
    "qemu_sha256",
    "machine",
    "cpu",
    "accelerator",
    "qemu_target",
)


def compare(source: dict[str, object], destination: dict[str, object]) -> list[str]:
    mismatches = [
        key for key in CRITICAL if source.get(key) != destination.get(key)
    ]
    for side, manifest in (("source", source), ("destination", destination)):
        if not all(
            manifest.get(key) is True
            for key in ("dev_kvm_readable", "dev_kvm_writable", "kvm_listed")
        ):
            mismatches.append(f"{side}_kvm_unavailable")
    return mismatches


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    source = json.loads(args.source.read_text(encoding="utf-8"))
    destination = json.loads(args.destination.read_text(encoding="utf-8"))
    mismatches = compare(source, destination)
    print(f"preflight_mismatches={mismatches}")
    if mismatches:
        raise SystemExit(1)
    print("preflight_match=true")
    print("A matching preflight is necessary evidence, not migration proof.")


if __name__ == "__main__":
    main()
