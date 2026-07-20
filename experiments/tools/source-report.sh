#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

: "${QEMU_SRC:?Set QEMU_SRC to the QEMU source tree}"

if ! git -C "$QEMU_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'QEMU_SRC is not a Git worktree: %s\n' "$QEMU_SRC" >&2
    exit 1
fi

printf 'source=%s\n' "$QEMU_SRC"
qemu_head_commit="$(git -C "$QEMU_SRC" rev-parse HEAD)"
baseline_ref='v11.1.0-rc0'
baseline_commit='unavailable'
source_matches_baseline='false'
if baseline_commit_candidate="$(git -C "$QEMU_SRC" rev-parse "${baseline_ref}^{commit}" 2>/dev/null)"; then
    baseline_commit="${baseline_commit_candidate}"
    if [[ "${qemu_head_commit}" == "${baseline_commit}" ]]; then
        source_matches_baseline='true'
    fi
fi

printf 'commit=%s\n' "${qemu_head_commit}"
printf 'describe=%s\n' \
    "$(git -C "$QEMU_SRC" describe --tags --always --dirty)"
printf 'target_release=v11.1.0\n'
printf 'expected_baseline=%s\n' "${baseline_ref}"
printf 'expected_baseline_commit=%s\n' "${baseline_commit}"
printf 'source_matches_baseline=%s\n' "${source_matches_baseline}"
printf 'architecture=riscv64\n'
printf 'host=%s\n' "$(uname -a)"
