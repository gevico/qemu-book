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
mkdir -p "${results_dir}"

{
    "${script_dir}/../../../tools/source-report.sh"
    printf '\n[decode pattern]\n'
    rg -n '^addi[[:space:]]' "${qemu_src}/target/riscv" -g '*.decode'
    printf '\n[translator]\n'
    rg -n -A8 'static bool trans_addi\(' \
        "${qemu_src}/target/riscv/tcg/insn_trans/trans_rvi.c.inc"
    printf '\n[decoder inclusion]\n'
    rg -n 'decode_insn32|trans_rvi.c.inc' \
        "${qemu_src}/target/riscv/tcg/translate.c"
} >"${results_dir}/decode-path.txt"

echo "Wrote the ADDI decode-to-translation evidence path."
