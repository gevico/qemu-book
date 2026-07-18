#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
results_dir="${script_dir}/results"
qemu_src="${QEMU_SRC:-}"

if [[ -z "${qemu_src}" || ! -d "${qemu_src}/.git" ]]; then
    echo "QEMU_SRC must point to a QEMU Git worktree" >&2
    exit 2
fi
uapi="${qemu_src}/linux-headers/asm-riscv/kvm.h"
kvm_cpu="${qemu_src}/target/riscv/kvm/kvm-cpu.c"
for source_file in "${uapi}" "${kvm_cpu}"; do
    [[ -f "${source_file}" ]] || {
        echo "missing fixed-tag source: ${source_file}" >&2
        exit 1
    }
done
mkdir -p "${results_dir}"

{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[UAPI register groups]\n'
    rg -n 'KVM_REG_RISCV_(CORE|CSR|TIMER|FP_[DF]|VECTOR|ISA_EXT)' "${uapi}"
    printf '\n[QEMU get/set calls]\n'
    rg -n 'KVM_(GET|SET)_ONE_REG|kvm_get_one_reg|kvm_set_one_reg' "${kvm_cpu}"
    printf '\n[lifecycle entry points]\n'
    rg -n 'kvm_arch_(get|put|reset)_registers|kvm_riscv_(get|put)' "${kvm_cpu}"
} >"${results_dir}/one-reg-table.txt"

echo "Wrote capability groups and synchronization entry points to results/."
