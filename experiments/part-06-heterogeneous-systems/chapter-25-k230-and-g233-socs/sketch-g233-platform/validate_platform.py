#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Validate evidence discipline for an out-of-tree G233 platform plan."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


ALLOWED_STATUSES = {"verified", "inferred", "unknown", "out-of-scope"}
REQUIRED_COMPONENTS = {"reset-vector", "main-memory", "interrupt-controller", "uart"}


def validate(document: dict[str, Any], require_minimum: bool = True) -> list[str]:
    errors: list[str] = []
    if document.get("architecture") != "riscv64":
        errors.append("architecture must be riscv64")
    if document.get("source_review_anchor") != "v11.1.0-rc0":
        errors.append("source_review_anchor must be v11.1.0-rc0")

    components = document.get("components")
    if not isinstance(components, list):
        return errors + ["components must be a list"]

    names: set[str] = set()
    for index, component in enumerate(components):
        prefix = f"components[{index}]"
        if not isinstance(component, dict):
            errors.append(f"{prefix} must be an object")
            continue
        name = component.get("name")
        status = component.get("status")
        evidence = component.get("evidence")
        if not isinstance(name, str) or not name:
            errors.append(f"{prefix}.name must be a non-empty string")
        elif name in names:
            errors.append(f"duplicate component name: {name}")
        else:
            names.add(name)
        if status not in ALLOWED_STATUSES:
            errors.append(f"{prefix}.status is invalid: {status!r}")
        if status in {"verified", "inferred"} and not evidence:
            errors.append(f"{prefix} marked {status} without evidence")
        if status == "verified" and component.get("value") is None:
            errors.append(f"{prefix} marked verified without a value")

    if require_minimum:
        for missing_name in sorted(REQUIRED_COMPONENTS - names):
            errors.append(f"missing required component: {missing_name}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan", type=Path)
    parser.add_argument("--allow-partial", action="store_true")
    arguments = parser.parse_args()

    document = json.loads(arguments.plan.read_text(encoding="utf-8"))
    errors = validate(document, require_minimum=not arguments.allow_partial)
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print(f"OK: {arguments.plan}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
