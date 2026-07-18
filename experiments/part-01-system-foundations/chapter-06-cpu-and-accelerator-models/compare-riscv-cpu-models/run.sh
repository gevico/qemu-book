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
"${qemu}" -machine virt -cpu help >"${results_dir}/cpu-models.txt"

for cpu_model in rv64 max; do
    if rg -q "^[[:space:]]*${cpu_model}([[:space:]]|$)" \
            "${results_dir}/cpu-models.txt"; then
        printf 'info registers\nquit\n' | "${qemu}" \
            -machine virt -cpu "${cpu_model}" -accel tcg -S \
            -display none -serial none -monitor stdio \
            >"${results_dir}/${cpu_model}-registers.txt" \
            2>"${results_dir}/${cpu_model}.stderr"
    fi
done

if [[ "$(uname -m)" == riscv64 && -r /dev/kvm ]]; then
    echo "host_model=available_for_separate_kvm_run" \
        >"${results_dir}/host-model.txt"
else
    echo "host_model=skipped" >"${results_dir}/host-model.txt"
fi
echo "Recorded the model inventory and available paused-model registers."
