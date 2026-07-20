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
    printf '\n[architectural constants]\n'
    rg -n 'HSTATUS|HGATP|VSSTATUS|VSATP|HIDELEG|HEDELEG' \
        "${qemu_src}/target/riscv/cpu_bits.h"
    printf '\n[stored CPU state]\n'
    rg -n 'hstatus|hgatp|vsstatus|vsatp|hideleg|hedeleg' \
        "${qemu_src}/target/riscv/cpu.h"
    printf '\n[CSR access paths]\n'
    rg -n 'hstatus|hgatp|vsstatus|vsatp|hideleg|hedeleg' \
        "${qemu_src}/target/riscv/tcg/csr.c"
    printf '\n[migration fields]\n'
    rg -n 'vmstate_hyper|hstatus|hgatp|vsstatus|vsatp' \
        "${qemu_src}/target/riscv/machine.c"
} >"${results_dir}/h-state.txt"

echo "Wrote HS/VS storage, access, and migration evidence to results/."
