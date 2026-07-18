#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"
qemu="${QEMU_SYSTEM_RISCV64:-}"

if [[ -z "${qemu_src}" || ! -d "${qemu_src}/.git" ]]; then
    echo "QEMU_SRC must point to a QEMU Git worktree" >&2
    exit 2
fi
mkdir -p "${results_dir}"
{
    "${script_dir}/../../../tools/source-report.sh"
    rg -n 'kvm_set_user_memory|KVM_SET_USER_MEMORY_REGION|kvm_set_phys_mem' \
        "${qemu_src}/accel/kvm/kvm-all.c"
    rg -n '^kvm_set_user_memory\(' "${qemu_src}/accel/kvm/trace-events"
} >"${results_dir}/slot-source.txt"

if [[ -n "${qemu}" && -x "${qemu}" && "$(uname -s)" == Linux && \
      "$(uname -m)" == riscv64 && -r /dev/kvm ]]; then
    printf 'info mtree -f\nquit\n' | "${qemu}" \
        -machine virt -accel kvm -cpu host -S -display none -serial none \
        -monitor stdio -trace enable=kvm_set_user_memory \
        -trace file="${results_dir}/slots.trace" \
        >"${results_dir}/mtree.txt" 2>"${results_dir}/qemu.stderr"
else
    echo "runtime_status=skipped" >"${results_dir}/runtime-status.txt"
fi
echo "Recorded slot lifecycle source evidence and optional runtime ranges."
