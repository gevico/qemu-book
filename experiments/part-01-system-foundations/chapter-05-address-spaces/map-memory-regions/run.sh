#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
mkdir -p "${results_dir}"

printf 'info mtree -f\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio >"${results_dir}/mtree.txt" \
    2>"${results_dir}/qemu.stderr"
rg -q '^ Root memory region: system' "${results_dir}/mtree.txt"
echo "Captured the flattened RISC-V virt memory topology."
