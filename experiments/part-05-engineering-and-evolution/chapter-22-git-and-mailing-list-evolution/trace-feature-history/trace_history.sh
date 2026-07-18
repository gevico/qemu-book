#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"
feature_path="${FEATURE_PATH:-hw/riscv/virt.c}"

if [[ -z "${qemu_src}" || ! -d "${qemu_src}/.git" ]]; then
    echo "QEMU_SRC must point to a full QEMU Git worktree" >&2
    exit 2
fi
if [[ "${feature_path}" == /* || "${feature_path}" == ../* || \
      "${feature_path}" == */../* || ! -e "${qemu_src}/${feature_path}" ]]; then
    echo "FEATURE_PATH must be an existing path inside QEMU_SRC" >&2
    exit 2
fi
if [[ "$(git -C "${qemu_src}" rev-list --count HEAD)" -lt 10000 ]]; then
    echo "QEMU_SRC appears shallow; fetch full history first" >&2
    exit 2
fi
mkdir -p "${results_dir}"

git -C "${qemu_src}" log --follow --date=iso-strict \
    --format='commit %H%nDate: %ad%nAuthor: %an <%ae>%nSubject: %s%nBody:%n%b%n' \
    --stat -- "${feature_path}" >"${results_dir}/history.txt"
git -C "${qemu_src}" log --follow -n 40 --format='%H %ad %s' --date=short \
    -- "${feature_path}" >"${results_dir}/timeline.txt"

echo "Recorded full-history evidence for ${feature_path}."
