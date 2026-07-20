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

"${qemu}" -accel help >"${results_dir}/accels.txt"
printf 'info cpus\nquit\n' | "${qemu}" \
    -machine virt -cpu rv64 -accel tcg -smp 2 -S \
    -display none -monitor stdio -serial none \
    >"${results_dir}/tcg-monitor.txt" 2>"${results_dir}/tcg.stderr"

if [[ "$(uname -s)" == Linux && "$(uname -m)" == riscv64 && \
   -r /dev/kvm && -w /dev/kvm ]] && \
   rg -q '^kvm$' "${results_dir}/accels.txt"; then
    printf 'info cpus\nquit\n' | "${qemu}" \
        -machine virt -cpu host -accel kvm -smp 2 -S \
        -display none -monitor stdio -serial none \
        >"${results_dir}/kvm-monitor.txt" 2>"${results_dir}/kvm.stderr"
    echo "kvm_status=executed" >"${results_dir}/kvm-status.txt"
else
    echo "kvm_status=skipped os=$(uname -s) host=$(uname -m) dev_kvm=$([[ -r /dev/kvm && -w /dev/kvm ]] && echo read-write || echo unavailable)" \
        >"${results_dir}/kvm-status.txt"
    echo "SKIP: the KVM comparison requires Linux/riscv64 and read-write /dev/kvm" >&2
    exit 77
fi

echo "Recorded accelerator inventory and paused-vCPU observations in results/."
