#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

: "${QEMU_SRC:?Set QEMU_SRC to the QEMU source tree}"

if [[ ! -d "$QEMU_SRC/.git" ]]; then
    printf 'QEMU_SRC is not a Git worktree: %s\n' "$QEMU_SRC" >&2
    exit 1
fi

printf 'source=%s\n' "$QEMU_SRC"
printf 'commit=%s\n' "$(git -C "$QEMU_SRC" rev-parse HEAD)"
printf 'describe=%s\n' \
    "$(git -C "$QEMU_SRC" describe --tags --always --dirty)"
printf 'target_release=v11.1.0\n'
printf 'research_anchor=v11.1.0-rc0\n'
printf 'architecture=riscv64\n'
printf 'host=%s\n' "$(uname -a)"
