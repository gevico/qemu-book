#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify the lab artifacts and, optionally, an exact QEMU baseline tree."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys


LAB_DIR = Path(__file__).resolve().parent
MANIFEST_PATH = LAB_DIR / "integration-checks.json"


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_git(source: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(source), *arguments],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def check_reset_phase_partition(patch_text: str) -> None:
    enter_marker = "+static void qb_mmio_demo_reset_enter"
    hold_marker = "+static void qb_mmio_demo_reset_hold"
    next_marker = "+static int qb_mmio_demo_post_load"
    try:
        enter_start = patch_text.index(enter_marker)
        hold_start = patch_text.index(hold_marker, enter_start)
        next_start = patch_text.index(next_marker, hold_start)
    except ValueError:
        fail("patch does not expose contiguous reset enter/hold functions")

    enter_body = patch_text[enter_start:hold_start]
    hold_body = patch_text[hold_start:next_start]
    cross_object_calls = ("qb_mmio_demo_update_irq", "qemu_set_irq", "qemu_irq_lower")
    if any(call in enter_body for call in cross_object_calls):
        fail("reset enter mutates the cross-object IRQ path")
    if "qb_mmio_demo_update_irq(s);" not in hold_body:
        fail("reset hold does not update the external IRQ line")
    if any(field_name in hold_body for field_name in ("s->control", "s->data", "s->pending")):
        fail("reset hold unexpectedly changes device-local fields")
    print("PASS reset-phase-partition: local enter, cross-object hold")


def check_committed_artifacts(manifest: dict[str, object]) -> Path:
    patch_path = LAB_DIR / str(manifest["patch"])
    if not patch_path.is_file():
        fail(f"missing patch template: {patch_path}")

    patch_text = patch_path.read_text(encoding="utf-8")
    if "teaching" not in patch_text.lower() or "not an upstream" not in patch_text.lower():
        fail("patch must state that the model is teaching-only and not upstream ABI")

    patch_layers = manifest["patch_layers"]
    assert isinstance(patch_layers, dict)
    for layer, markers in patch_layers.items():
        assert isinstance(markers, list)
        missing = [marker for marker in markers if marker not in patch_text]
        if missing:
            fail(f"patch layer {layer} is missing markers: {', '.join(missing)}")
        print(f"PASS patch-layer {layer}: {len(markers)} markers")

    check_reset_phase_partition(patch_text)

    contract_markers = manifest["contract_markers"]
    assert isinstance(contract_markers, dict)
    for relative_name, markers in contract_markers.items():
        artifact_path = LAB_DIR / relative_name
        if not artifact_path.is_file():
            fail(f"missing contract artifact: {relative_name}")
        artifact_text = artifact_path.read_text(encoding="utf-8")
        assert isinstance(markers, list)
        missing = [marker for marker in markers if marker not in artifact_text]
        if missing:
            fail(f"{relative_name} is missing contract markers: {', '.join(missing)}")
        print(f"PASS contract-alignment {relative_name}: {len(markers)} markers")

    guest_files = [
        LAB_DIR / "guest" / "start.S",
        LAB_DIR / "guest" / "probe.c",
        LAB_DIR / "guest" / "linker.ld",
    ]
    for guest_file in guest_files:
        if not guest_file.is_file():
            fail(f"missing bare-metal fixture: {guest_file}")
    print("PASS bare-metal fixture: start, probe, and linker script")
    return patch_path


def check_qemu_tree(manifest: dict[str, object], patch_path: Path) -> None:
    source_value = os.environ.get("QEMU_SRC")
    if not source_value:
        print("SKIP qemu-tree: QEMU_SRC is not set")
        return

    source = Path(source_value).expanduser().resolve()
    if not (source / ".git").exists():
        fail(f"QEMU_SRC is not a Git worktree: {source}")

    revision = run_git(source, "rev-parse", "HEAD")
    if revision.returncode:
        fail(revision.stderr.strip() or "could not read QEMU revision")
    actual_commit = revision.stdout.strip()
    expected_commit = str(manifest["baseline_commit"])
    if actual_commit != expected_commit:
        print(
            "SKIP qemu-tree: patch is pinned to "
            f"{expected_commit}, QEMU_SRC is {actual_commit}"
        )
        return

    anchors = manifest["source_anchors"]
    assert isinstance(anchors, dict)
    for relative_name, markers in anchors.items():
        source_path = source / relative_name
        if not source_path.is_file():
            fail(f"baseline path is missing: {relative_name}")
        source_text = source_path.read_text(encoding="utf-8")
        assert isinstance(markers, list)
        missing = [marker for marker in markers if marker not in source_text]
        if missing:
            fail(f"{relative_name} is missing API anchors: {', '.join(missing)}")
        print(f"PASS source-anchor {relative_name}: {len(markers)} markers")

    apply_check = run_git(
        source,
        "apply",
        "--check",
        "--cached",
        "--whitespace=error-all",
        str(patch_path),
    )
    if apply_check.returncode:
        fail(apply_check.stderr.strip() or "git apply --check failed")
    print(f"PASS git-apply-check: {expected_commit}")


def main() -> None:
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    patch_path = check_committed_artifacts(manifest)
    check_qemu_tree(manifest, patch_path)


if __name__ == "__main__":
    main()
