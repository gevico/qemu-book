#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"

if [[ -z "${qemu_src}" ]] || \
   ! git -C "${qemu_src}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "QEMU_SRC must point to a QEMU Git worktree" >&2
    exit 2
fi
mkdir -p "${results_dir}"

{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[qemu_init]\n'
    rg -n 'qemu_init\(' "${qemu_src}/system"
    printf '\n[machine construction]\n'
    rg -n 'qemu_create_machine|qmp_x_exit_preconfig' "${qemu_src}/system/vl.c"
    printf '\n[riscv virt registration]\n'
    rg -n 'type_init|DEFINE_MACHINE|MachineClass|virt_machine' \
        "${qemu_src}/hw/riscv/virt.c"
} >"${results_dir}/startup-map.txt"

echo "Wrote evidence locations to results/startup-map.txt."
