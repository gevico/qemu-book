#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../tools/lab-common.sh
source "${project_dir}/../../../tools/lab-common.sh"

lab_require_command rg
lab_require_command git
lab_require_directory QEMU_SRC
if [[ ! -d "${QEMU_SRC}/.git" ]]; then
    lab_die "QEMU_SRC is not a Git worktree: ${QEMU_SRC}"
fi
results_dir="$(lab_results_directory "${project_dir}")"
inventory_file="${results_dir}/k230-inventory.md"
missing_paths=0

required_paths=(
    "hw/riscv/k230.c"
    "include/hw/riscv/k230.h"
    "hw/watchdog/k230_wdt.c"
    "tests/qtest/k230-wdt-test.c"
    "tests/functional/riscv64/test_k230.py"
    "docs/system/riscv/k230.rst"
)

{
    printf '# K230 implementation inventory\n\n'
    printf "Source commit: \`%s\`\n\n" "$(git -C "${QEMU_SRC}" rev-parse HEAD)"
    printf '## Required upstream paths\n\n'
    for relative_path in "${required_paths[@]}"; do
        if [[ -f "${QEMU_SRC}/${relative_path}" ]]; then
            printf -- "- present: \`%s\`\n" "${relative_path}"
        else
            printf -- "- missing: \`%s\`\n" "${relative_path}"
            missing_paths=$((missing_paths + 1))
        fi
    done

    printf '\n## Machine and device symbols\n\n```text\n'
    rg -n 'TYPE_RISCV_K230_MACHINE|k230_memmap|k230_machine_init|K230_WDT' \
        "${QEMU_SRC}/hw/riscv/k230.c" \
        "${QEMU_SRC}/include/hw/riscv/k230.h" \
        "${QEMU_SRC}/hw/watchdog/k230_wdt.c" || true
    printf '```\n'
} >"${inventory_file}"

if (( missing_paths > 0 )); then
    lab_die "selected source tree is missing ${missing_paths} required K230 paths"
fi

qemu_binary="${QEMU_SYSTEM_RISCV64:-${QEMU_BUILD:-}/qemu-system-riscv64}"
if [[ -x "${qemu_binary}" ]]; then
    "${qemu_binary}" -machine help >"${results_dir}/machine-help.txt"
    "${qemu_binary}" -machine k230,help >"${results_dir}/k230-properties.txt"
else
    printf 'SKIP runtime introspection: qemu-system-riscv64 is unavailable\n' \
        >"${results_dir}/runtime-skip.txt"
fi

printf 'Wrote %s\n' "${inventory_file}"
