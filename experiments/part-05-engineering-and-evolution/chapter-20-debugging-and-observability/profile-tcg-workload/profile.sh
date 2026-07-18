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
for tool in perf timeout; do
    command -v "${tool}" >/dev/null 2>&1 || {
        echo "required profiling tool not found: ${tool}" >&2
        exit 2
    }
done
mkdir -p "${results_dir}"
"${qemu}" --version >"${results_dir}/qemu-version.txt"

for run_number in 1 2 3; do
    perf record -q -F 99 -g -o "${results_dir}/perf-${run_number}.data" -- \
        timeout "${PROFILE_SECONDS:-10}" "${qemu}" \
        -machine virt -cpu rv64 -accel tcg -smp 1 -m 256M \
        -bios none -kernel "${image}" -display none -serial none -monitor none \
        2>"${results_dir}/run-${run_number}.stderr" || true
    perf report --stdio -i "${results_dir}/perf-${run_number}.data" \
        >"${results_dir}/report-${run_number}.txt"
done

echo "Captured three bounded sampling profiles; interpret variance before design."
