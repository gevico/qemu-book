#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu="${QEMU_SYSTEM_RISCV64:-}"
image="${RISCV_GUEST_IMAGE:-}"

if [[ -z "${qemu}" || ! -x "${qemu}" ]]; then
    echo "QEMU_SYSTEM_RISCV64 must name an executable QEMU binary" >&2
    exit 2
fi
if [[ -z "${image}" || ! -f "${image}" ]]; then
    echo "RISCV_GUEST_IMAGE must name a guest image" >&2
    exit 2
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "GNU timeout is required to bound a guest that does not power off" >&2
    exit 2
fi

mkdir -p "${results_dir}"
if [[ -n "${QEMU_SRC:-}" ]]; then
    "${script_dir}/../../../tools/source-report.sh" \
        >"${results_dir}/source.txt"
fi

set +e
timeout "${BOOT_TIMEOUT_SECONDS:-10}" "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -m 256M -bios none \
    -kernel "${image}" -display none -serial none -monitor none -no-reboot \
    -d cpu_reset,in_asm -D "${results_dir}/boot.log" \
    2>"${results_dir}/qemu.stderr"
status=$?
set -e

if [[ ! -s "${results_dir}/boot.log" ]]; then
    echo "QEMU produced no reset/instruction trace" >&2
    exit 1
fi
echo "qemu_status=${status}" >"${results_dir}/status.txt"
echo "Captured a bounded reset and instruction trace in results/boot.log."
