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
    printf '\n[AccelOpsClass]\n'
    rg -n 'struct AccelOpsClass|typedef struct AccelOpsClass' \
        "${qemu_src}/include" "${qemu_src}/accel"
    printf '\n[TCG operations]\n'
    rg -n 'AccelOpsClass|cpu_exec|create_vcpu_thread' \
        "${qemu_src}/accel/tcg/tcg-accel-ops.c"
    printf '\n[KVM operations]\n'
    rg -n 'AccelOpsClass|cpu_exec|create_vcpu_thread' \
        "${qemu_src}/accel/kvm/kvm-accel-ops.c"
    printf '\n[RISC-V backend entry points]\n'
    rg -n -m 60 'riscv|kvm_arch|translate' \
        "${qemu_src}/target/riscv/tcg" "${qemu_src}/target/riscv/kvm"
} >"${results_dir}/contract.txt"

echo "Wrote accelerator callback evidence to results/contract.txt."
