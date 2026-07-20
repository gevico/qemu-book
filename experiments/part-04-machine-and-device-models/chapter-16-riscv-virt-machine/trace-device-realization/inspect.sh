#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu_src}" ]] || \
   ! git -C "${qemu_src}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "QEMU_SRC must point to a QEMU Git worktree" >&2
    exit 2
fi
if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
mkdir -p "${results_dir}"

{
    "${script_dir}/../../../tools/source-report.sh"
    rg -n 'serial_mm_init|UART0|uart' "${qemu_src}/hw/riscv/virt.c"
    rg -n 'serial_mm_init|serial_realize|sysbus_mmio_map|sysbus_connect_irq' \
        "${qemu_src}/hw/char" "${qemu_src}/hw/core"
} >"${results_dir}/uart-source.txt"

printf 'info qom-tree\ninfo mtree -f\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -S -display none -serial none \
    -monitor stdio >"${results_dir}/uart-runtime.txt" \
    2>"${results_dir}/qemu.stderr"
rg -qi 'serial|uart' "${results_dir}/uart-runtime.txt"
echo "Recorded UART construction anchors and realized object/memory views."
